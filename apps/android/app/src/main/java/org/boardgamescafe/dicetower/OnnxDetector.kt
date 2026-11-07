package org.boardgamescafe.dicetower

import ai.onnxruntime.*
import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.nio.FloatBuffer
import java.security.MessageDigest

data class Analysis(val faces: List<Face>,val inferenceMs: Double,val processingMs: Double)

class OnnxDetector(context: Context): AutoCloseable {
    private val environment=OrtEnvironment.getEnvironment()
    private val session: OrtSession
    val modelSHA256: String
    init {
        val info=JSONObject(context.assets.open("model-info.json").bufferedReader().use { it.readText() })
        check(info.getString("sourceModelSHA256")=="416678e1d7e4e7f7b867e1513fce072744a49c6feca3cdfb90b12417be8091b9") { "Unexpected model lineage" }
        modelSHA256=info.getString("onnxSHA256")
        val file=File(context.noBackupFilesDir,"detector-${modelSHA256.take(16)}.onnx")
        fun sha(f: File): String {
            val digest=MessageDigest.getInstance("SHA-256")
            f.inputStream().use { input -> val buffer=ByteArray(65536);var n=input.read(buffer);while(n>=0){digest.update(buffer,0,n);n=input.read(buffer)} }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
        if(!file.exists() || sha(file)!=modelSHA256) {
            val temporary=File(file.path+".tmp")
            context.assets.open("DiceTowerD6.onnx").use { input -> temporary.outputStream().use { input.copyTo(it) } }
            check(sha(temporary)==modelSHA256) { "Model checksum mismatch" }
            check(temporary.renameTo(file)) { "Could not install model" }
        }
        OrtSession.SessionOptions().use { options ->
            options.setIntraOpNumThreads(minOf(4,Runtime.getRuntime().availableProcessors()))
            options.setInterOpNumThreads(1)
            options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            session=environment.createSession(file.path,options)
        }
    }
    fun analyze(bitmap: Bitmap,region: Region): Analysis {
        val start=SystemClock.elapsedRealtimeNanos()
        val geometry=Geometry(bitmap.width,bitmap.height,region)
        val pixels=IntArray(bitmap.width*bitmap.height)
        bitmap.getPixels(pixels,0,bitmap.width,0,0,bitmap.width,bitmap.height)
        val input=ModelPixels.prepare(pixels,geometry)
        OnnxTensor.createTensor(environment,FloatBuffer.wrap(input),longArrayOf(1,3,416,416)).use { tensor ->
            val modelStart=SystemClock.elapsedRealtimeNanos()
            session.run(mapOf("image" to tensor)).use { outputs ->
                val inferenceMs=(SystemClock.elapsedRealtimeNanos()-modelStart)/1e6
                val boxes=(outputs.get("boxes").get() as OnnxTensor).floatBuffer.let { b -> FloatArray(b.remaining()).also { b.get(it) } }
                val scores=(outputs.get("scores").get() as OnnxTensor).floatBuffer.let { b -> FloatArray(b.remaining()).also { b.get(it) } }
                val faces=DetectorMath.decode(boxes,scores,geometry)
                return Analysis(faces,inferenceMs,(SystemClock.elapsedRealtimeNanos()-start)/1e6)
            }
        }
    }
    override fun close() { session.close() }
}
