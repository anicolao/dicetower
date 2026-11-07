package org.boardgamescafe.dicetower

import android.graphics.BitmapFactory
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
    @Test fun stableFramesReportOnceThenMotionRearmsWithTheSameDiceValues()=runBlocking {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val bitmap=instrumentation.context.assets.open("golden.png").use { BitmapFactory.decodeStream(it) }!!
        val reports=CopyOnWriteArrayList<JSONObject>();val samples=CopyOnWriteArrayList<JSONObject>()
        val engine=RecognitionEngine(instrumentation.targetContext,{reports.add(it)},{samples.add(it)})
        try {
            engine.setRegion(Region(0.0,0.0,0.0,0.0))
            suspend fun feedUntilReport(gray: Byte,target: Int) {
                withTimeout(15000) {
                    while(reports.size<target) {
                        val time=monotonicSeconds();engine.observeMotion(ByteArray(96*128){gray},time);engine.submit(bitmap,time);delay(50)
                    }
                }
            }
            feedUntilReport(30,1)
            assertEquals("quiescent",engine.ui.value.timing.phase);assertEquals(2,engine.ui.value.timing.agreementCount)
            val count=engine.ui.value.timing.inferenceCount;val sampleCount=samples.size
            repeat(10){val time=monotonicSeconds();engine.observeMotion(ByteArray(96*128){30},time);engine.submit(bitmap,time);delay(50)}
            assertEquals(count,engine.ui.value.timing.inferenceCount);assertEquals(sampleCount,samples.size);assertEquals(1,reports.size)
            // A transient spatial spike, exposure flicker, and a camera gap must
            // leave the published scene idle, with no new inference or event.
            val spike=ByteArray(96*128){30}.also { p -> for(y in 24..35)for(x in 12..23)p[y*96+x]=220.toByte() }
            engine.observeMotion(spike,monotonicSeconds());delay(50)
            repeat(10){i -> engine.observeMotion(ByteArray(96*128){if(i%2==0)40 else 90},monotonicSeconds());delay(50)}
            engine.observeMotion(ByteArray(96*128){30},monotonicSeconds()+2)
            assertEquals(count,engine.ui.value.timing.inferenceCount);assertEquals(1,reports.size)
            delay(50)
            engine.observeMotion(ByteArray(96*128){30},monotonicSeconds())
            repeat(2){
                // A quick change followed by an already-stopped scene must rearm.
                val moving=ByteArray(96*128){30}.also { p -> for(y in 24..35)for(x in 24..35)p[y*96+x]=220.toByte() }
                val time=monotonicSeconds();engine.observeMotion(moving,time);engine.submit(bitmap,time);delay(50)
            }
            feedUntilReport(30,2)
            assertNotEquals(reports[0].getString("rollId"),reports[1].getString("rollId"))
            assertEquals(20,reports[0].getInt("total"));assertEquals(20,reports[1].getInt("total"))
            assertTrue(engine.ui.value.timing.inferenceCount>count)
        } finally {engine.close()}
    }
}
