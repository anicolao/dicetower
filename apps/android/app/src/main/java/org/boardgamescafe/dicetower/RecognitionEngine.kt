package org.boardgamescafe.dicetower

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Base64
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

fun monotonicSeconds()=SystemClock.elapsedRealtimeNanos()/1e9

data class Timing(val phase: String="active",val inferenceMs: Double=0.0,val emaInferenceMs: Double=0.0,
                  val processingMs: Double=0.0,val intervalMs: Double=50.0,val inferenceCount: Int=0,val agreementCount: Int=0)
data class RecognitionUi(val faces: List<Face> = emptyList(),val timing: Timing=Timing(),val message: String="Preparing recognition…",val aspect: Float=3f/4f)

class RecognitionEngine(context: Context,private val onRoll: (JSONObject)->Unit,private val onMetric: (JSONObject)->Unit) {
    private val executor=Executors.newSingleThreadScheduledExecutor()
    private val guard=Any()
    private val cycle=RecognitionCycle()
    private val scene=SceneMonitor()
    private val sessionId=UUID.randomUUID().toString()
    private var rollId=UUID.randomUUID().toString()
    private var generation=0
    private var busy=false
    private var scheduled=false
    private var phase="active"
    private var latest: Frame?=null
    private var lastUsed=Double.NEGATIVE_INFINITY
    private var region=Region()
    private var detector: OnnxDetector?=null
    private val app=context.applicationContext
    private val _ui=MutableStateFlow(RecognitionUi())
    val ui=_ui.asStateFlow()
    private data class Frame(val image: Bitmap,val still: Boolean,val time: Double,val capturedAt: Long,val region: Region)

    private fun timing()=Timing(phase,cycle.inferenceMs,cycle.emaInferenceMs,cycle.processingMs,cycle.intervalMs,cycle.inferenceCount,cycle.agreementCount)
    private fun metric(eventId: String=""): JSONObject = JSONObject().apply {
        put("schemaVersion",1);put("metricId",UUID.randomUUID().toString());put("sessionId",sessionId)
        put("recordedAt",System.currentTimeMillis());put("phase",phase)
        put("inferenceMs",cycle.inferenceMs);put("emaInferenceMs",cycle.emaInferenceMs);put("processingMs",cycle.processingMs)
        put("intervalMs",cycle.intervalMs);put("inferenceCount",cycle.inferenceCount);put("agreementCount",cycle.agreementCount)
        put("settleMs",200);put("eventId",eventId)
    }
    fun reset(paused: Boolean=false) {
        val sample=synchronized(guard) {
            generation++;cycle.reset();scene.reset();latest=null;scheduled=false;lastUsed=Double.NEGATIVE_INFINITY
            phase=if(paused)"paused" else "active";rollId=UUID.randomUUID().toString()
            _ui.value=_ui.value.copy(faces=emptyList(),timing=timing(),message=if(paused)"Camera paused" else "Waiting for dice to settle…")
            metric()
        }
        onMetric(sample)
    }
    fun setRegion(value: Region) { synchronized(guard){region=value};reset() }
    fun observeMotion(pixels: ByteArray,time: Double) {
        val sample=synchronized(guard) {
            if(phase=="paused")return
            val newRoll=scene.observe(pixels,time)
            if(newRoll || (scene.invalidated && phase=="active")) {
                generation++;cycle.reset();latest=null;scheduled=false;lastUsed=Double.NEGATIVE_INFINITY
                if(newRoll){phase="active";rollId=UUID.randomUUID().toString()}
                _ui.value=_ui.value.copy(faces=emptyList(),timing=timing(),message=if(newRoll)"Movement detected" else "Waiting for dice to settle…")
                metric()
            } else null
        }
        sample?.let(onMetric)
    }
    fun needsImage()=synchronized(guard){phase=="active"}
    fun submit(bitmap: Bitmap,time: Double) {
        synchronized(guard) {
            if(phase!="active")return
            latest=Frame(bitmap,scene.still,time,System.currentTimeMillis(),region)
        }
        schedule()
    }
    private fun schedule() {
        synchronized(guard) {
            val f=latest
            if(phase!="active" || busy || scheduled || f==null || f.time<=lastUsed)return
            scheduled=true;val epoch=generation
            val delay=(maxOf(0.0,cycle.nextStart-monotonicSeconds())*1e9).toLong()
            executor.schedule(task@{
                val frame=synchronized(guard) {
                    if(epoch!=generation)return@task
                    scheduled=false
                    val current=latest
                    if(phase!="active" || busy || current==null || current.time<=lastUsed)return@task
                    busy=true;lastUsed=current.time;cycle.started(monotonicSeconds());current
                }
                infer(frame,epoch)
            },delay,TimeUnit.NANOSECONDS)
        }
    }
    private fun infer(frame: Frame,epoch: Int) {
        try {
            val model=detector?:OnnxDetector(app).also { detector=it }
            val analysis=model.analyze(frame.image,frame.region)
            val accepted=synchronized(guard) {
                val valid=epoch==generation
                val result=cycle.complete(analysis.faces,frame.still,analysis.inferenceMs,analysis.processingMs,monotonicSeconds(),valid)
                if(result)phase="quiescent"
                result
            }
            var event: JSONObject?=null
            if(accepted) {
                val scale=minOf(1.0,384.0/frame.image.width,512.0/frame.image.height)
                val thumbnail=Bitmap.createScaledBitmap(frame.image,maxOf(1,(frame.image.width*scale).toInt()),maxOf(1,(frame.image.height*scale).toInt()),true)
                val bytes=ByteArrayOutputStream().also { check(thumbnail.compress(Bitmap.CompressFormat.JPEG,60,it)) }.toByteArray()
                check(bytes.size<74000) { "Thumbnail too large" }
                val dice=JSONArray()
                analysis.faces.forEach { f -> dice.put(JSONObject().apply {
                    put("value",f.value);put("confidence",f.confidence);put("box",JSONObject().apply { put("x",f.box.x);put("y",f.box.y);put("width",f.box.width);put("height",f.box.height) })
                }) }
                event=JSONObject().apply {
                    put("schemaVersion",1);put("eventId",UUID.randomUUID().toString());put("rollId",rollId);put("kind","roll")
                    put("capturedAt",frame.capturedAt);put("modelSHA256",model.modelSHA256);put("dice",dice)
                    put("count",analysis.faces.size);put("total",analysis.faces.sumOf { it.value });put("experimental",true)
                    put("thumbnail","data:image/jpeg;base64,"+Base64.encodeToString(bytes,Base64.NO_WRAP))
                }
            }
            synchronized(guard) {
                if(epoch!=generation) { onMetric(metric());return }
                _ui.value=RecognitionUi(analysis.faces,timing(),if(accepted)"Quiescent · check the highlighted faces · watching for motion" else "Recognizing · waiting for two agreeing still frames…",frame.image.width.toFloat()/frame.image.height)
                onMetric(metric(event?.getString("eventId")?:""))
                event?.let(onRoll)
            }
        } catch(error: Exception) {
            synchronized(guard) {
                if(epoch==generation) {
                    phase="error";cycle.reset()
                    _ui.value=_ui.value.copy(timing=timing(),message="Recognition unavailable. Reopen the camera or reinstall the complete app.")
                    onMetric(metric())
                }
            }
        } finally {
            synchronized(guard){busy=false}
            schedule()
        }
    }
    fun close() { reset(true);executor.execute { detector?.close();detector=null };executor.shutdown() }
}
