package org.boardgamescafe.dicetower

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(AndroidJUnit4::class)
class EngineCycleDeviceTest {
    @Test fun sensitiveRearmingDiscardsDuplicatesButReportsMovedDice()=runBlocking {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val bitmap=instrumentation.context.assets.open("golden.png").use { BitmapFactory.decodeStream(it) }!!
        val reports=CopyOnWriteArrayList<JSONObject>();val samples=CopyOnWriteArrayList<JSONObject>()
        val engine=RecognitionEngine(instrumentation.targetContext,{reports.add(it)},{samples.add(it)})
        try {
            engine.setRegion(Region(0.0,0.0,0.0,0.0))
            suspend fun feedUntil(image: Bitmap=bitmap,gray: Byte=30,condition: ()->Boolean) {
                withTimeout(15000) { while(!condition()) {
                    val time=monotonicSeconds();engine.observeMotion(ByteArray(96*128){gray},time);engine.submit(image,time);delay(50)
                } }
            }
            feedUntil { reports.size==1 }
            val first=reports[0].getString("eventId")
            val count=engine.ui.value.timing.inferenceCount
            repeat(6){val time=monotonicSeconds();engine.observeMotion(ByteArray(96*128){30},time);engine.submit(bitmap,time);delay(50)}
            assertEquals(count,engine.ui.value.timing.inferenceCount)
            // One changed frame immediately wakes ML; the unchanged conclusion is
            // discarded only after two agreeing still inferences, with telemetry.
            engine.observeMotion(ByteArray(96*128){220.toByte()},monotonicSeconds())
            assertEquals("active",engine.ui.value.timing.phase)
            feedUntil { engine.ui.value.timing.duplicateCount==1 }
            assertEquals(1,reports.size)
            val duplicate=samples.last { it.optBoolean("duplicateDiscarded") }
            assertEquals(first,duplicate.getString("duplicateOfEventId"));assertEquals("",duplicate.getString("eventId"))
            assertEquals(1,duplicate.getInt("duplicateCount"));assertEquals("quiescent",duplicate.getString("phase"))
            engine.observeMotion(ByteArray(96*128){30},monotonicSeconds()+2)
            feedUntil { engine.ui.value.timing.duplicateCount==2 }
            assertEquals(1,reports.size)
            // Same dice values at visibly new positions must still produce a roll.
            val shifted=Bitmap.createBitmap(bitmap.width,bitmap.height,Bitmap.Config.ARGB_8888)
            Canvas(shifted).apply { drawColor(Color.BLACK);drawBitmap(bitmap,12f,0f,null) }
            engine.observeMotion(ByteArray(96*128){220.toByte()},monotonicSeconds())
            feedUntil(shifted) { reports.size==2 }
            assertNotEquals(reports[0].getString("rollId"),reports[1].getString("rollId"))
            assertEquals(20,reports[0].getInt("total"));assertEquals(20,reports[1].getInt("total"))
            engine.reset(clearReportedHistory=true)
            feedUntil(shifted) { reports.size==3 }
            assertEquals(2,engine.ui.value.timing.duplicateCount)
        } finally {engine.close()}
    }
}
