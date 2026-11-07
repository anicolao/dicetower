package org.boardgamescafe.dicetower

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

/** Explicit opt-in only; CI/unit tests never contact the live Firebase project. */
@RunWith(AndroidJUnit4::class)
class LiveFirebaseTest {
    @Test fun anonymousAndroidPublisherUsesExistingStreamsAndConditionalRetries()=runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("liveFirebase")=="true")
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        val backend=FirebaseBackend(context);val owner=backend.owner()
        val publishingScope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
        val publisher=CloudPublisher(context,publishingScope,backend)
        assertTrue(publisher.configure("QA Android emulator"))
        assertEquals(owner,publisher.ui.value.towerId)
        File(context.noBackupFilesDir,"qa-tower-id.txt").writeText(owner)
        val bitmap=instrumentation.context.assets.open("golden.png").use { BitmapFactory.decodeStream(it) }!!
        OnnxDetector(context).use { detector ->
            val analysis=detector.analyze(bitmap,Region(0.0,0.0,0.0,0.0))
            assertEquals(listOf(2,3,4,5,6),analysis.faces.map { it.value }.sorted())
            val image=ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG,60,it) }.toByteArray()
            val eventId=UUID.randomUUID().toString();val metricId=UUID.randomUUID().toString()
            val faces=JSONArray()
            analysis.faces.forEach { f->faces.put(JSONObject().put("value",f.value).put("confidence",f.confidence).put("box",JSONObject().put("x",f.box.x).put("y",f.box.y).put("width",f.box.width).put("height",f.box.height))) }
            val event=JSONObject().put("schemaVersion",1).put("eventId",eventId).put("rollId",UUID.randomUUID().toString()).put("kind","roll")
                .put("capturedAt",System.currentTimeMillis()).put("modelSHA256",detector.modelSHA256).put("dice",faces).put("count",5).put("total",20)
                .put("thumbnail","data:image/jpeg;base64,"+Base64.encodeToString(image,Base64.NO_WRAP)).put("experimental",true)
            val metric=JSONObject().put("schemaVersion",1).put("metricId",metricId).put("sessionId","android-qa").put("recordedAt",System.currentTimeMillis()).put("phase","quiescent")
                .put("inferenceMs",analysis.inferenceMs).put("emaInferenceMs",analysis.inferenceMs).put("processingMs",analysis.processingMs)
                .put("intervalMs",maxOf(50.0,kotlin.math.ceil(analysis.inferenceMs/50)*50)).put("inferenceCount",2).put("agreementCount",2).put("settleMs",200).put("eventId",eventId)
            publisher.enqueue("rolls",event);publisher.enqueue("metrics",metric)
            withTimeout(20000) { while(runCatching { backend.call("metrics/$owner/$metricId").body?.getInt("agreementCount")==2 }.getOrDefault(false).not())delay(100) }
            publisher.keepLocal();publishingScope.cancel()
            val outbox=DiskOutbox(File(context.noBackupFilesDir,"qa-network-outbox"))
            outbox.put("rolls",owner,eventId,event);outbox.put("metrics",owner,metricId,metric)
            UploadDrain(backend,outbox).flush(owner){true};assertEquals(0,outbox.count())
            val first=backend.call("rolls/$owner/$eventId").body!!;assertEquals(20,first.getInt("total"))
            outbox.put("rolls",owner,eventId,event)
            UploadDrain(backend,outbox).flush(owner){true};assertEquals(0,outbox.count())
            assertEquals(first.getLong("receivedAt"),backend.call("rolls/$owner/$eventId").body!!.getLong("receivedAt"))
            backend.call("metrics/$owner","PATCH",JSONObject().put(metricId,metric))
            assertEquals(2,backend.call("metrics/$owner/$metricId").body!!.getInt("agreementCount"))
        }
    }
}
