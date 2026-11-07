package org.boardgamescafe.dicetower

import android.graphics.BitmapFactory
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class ModelSmokeTest {
    @Test fun exportedModelMatchesHeldOutGoldenAndRecordsEmulatorBenchmark() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val assets=instrumentation.context.assets
        assumeTrue("Local-only held-out fixture was not supplied",assets.list("")!!.contains("golden.png"))
        val expected=JSONObject(assets.open("golden.json").bufferedReader().use { it.readText() }).getJSONArray("values")
        val values=(0 until expected.length()).map { expected.getInt(it) }.sorted()
        val bitmap=assets.open("golden.png").use { BitmapFactory.decodeStream(it) }!!
        OnnxDetector(context).use { detector ->
            repeat(2){detector.analyze(bitmap,Region(0.0,0.0,0.0,0.0))}
            val measurements=(0 until 10).map { detector.analyze(bitmap,Region(0.0,0.0,0.0,0.0)) }
            measurements.forEach { assertEquals(values,it.faces.map { f->f.value }.sorted());assertTrue(it.inferenceMs>0);assertTrue(it.processingMs>=it.inferenceMs) }
            val ms=measurements.map { it.inferenceMs }.sorted()
            val report=JSONObject().put("device",Build.MODEL).put("sdk",Build.VERSION.SDK_INT).put("modelSHA256",detector.modelSHA256)
                .put("images",10).put("values",JSONArray(values)).put("meanInferenceMs",ms.average()).put("p50InferenceMs",ms[ms.size/2])
                .put("maxInferenceMs",ms.last()).put("meanFrameMs",measurements.map { it.processingMs }.average())
            File(context.noBackupFilesDir,"android-benchmark.json").writeText(report.toString(2))
        }
    }
}
