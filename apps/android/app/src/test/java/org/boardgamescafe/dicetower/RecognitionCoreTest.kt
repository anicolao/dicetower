package org.boardgamescafe.dicetower

import org.junit.Assert.*
import org.junit.Test

class RecognitionCoreTest {
    private fun face(n: Int,x: Double=.2)=Face(n,.9,Box(x,.2,.1,.1))
    @Test fun twoStillFramesThenIdleUntilReset() {
        val c=RecognitionCycle();c.started(0.0)
        assertFalse(c.complete(listOf(face(4)),true,12.0,20.0,.02));assertEquals(1,c.agreementCount)
        c.started(.05);assertTrue(c.complete(listOf(face(4)),true,12.0,20.0,.07));assertTrue(c.quiescent)
        c.reset();assertFalse(c.quiescent);assertEquals(2,c.inferenceCount)
    }
    @Test fun movingFramesDoNotAgreeAndMismatchStartsAgain() {
        val c=RecognitionCycle();c.started(0.0)
        assertFalse(c.complete(listOf(face(3)),false,10.0,20.0,.02));assertEquals(0,c.agreementCount)
        c.started(.05);assertFalse(c.complete(listOf(face(3)),true,10.0,20.0,.07))
        c.started(.1);assertFalse(c.complete(listOf(face(4)),true,10.0,20.0,.12));assertEquals(1,c.agreementCount)
        c.started(.15);assertFalse(c.complete(listOf(face(4)),true,10.0,20.0,.17,false));assertEquals(0,c.agreementCount)
    }
    @Test fun emaCadenceAndOverrunMatchIOS() {
        val c=RecognitionCycle();c.started(0.0);c.complete(emptyList(),false,51.0,70.0,.07)
        assertEquals(51.0,c.emaInferenceMs,1e-6);assertEquals(100.0,c.intervalMs,0.0)
        c.started(.1);c.complete(emptyList(),false,21.0,30.0,.13)
        assertEquals(45.0,c.emaInferenceMs,1e-6);assertEquals(50.0,c.intervalMs,0.0);assertEquals(.15,c.nextStart,1e-6)
        c.started(.15);c.complete(emptyList(),false,20.0,125.0,.275);assertEquals(.3,c.nextStart,1e-6)
    }
    @Test fun detectionOrderDoesNotChangeAgreement() {
        assertTrue(RecognitionCycle.matches(listOf(face(3),face(4,.7)),listOf(face(4,.7),face(3))))
        assertFalse(RecognitionCycle.matches(listOf(face(3)),listOf(face(3,.3))))
    }
    @Test fun settlementIs200msAndOneDisturbanceDoesNotRearm() {
        val scene=SceneMonitor();val quiet=ByteArray(96*128){30}
        for(t in listOf(0.0,.05,.1,.15,.199)){assertFalse(scene.observe(quiet,t));assertFalse(scene.still)}
        assertFalse(scene.observe(quiet,.2));assertTrue(scene.still)
        assertFalse(scene.observe(motionFrame(12),.25));assertFalse(scene.still);assertTrue(scene.invalidated)
    }
    @Test fun cameraGapRestartsTheWindowAndSmallMotionIsNotDiluted() {
        val scene=SceneMonitor();val quiet=ByteArray(96*128){30}
        scene.observe(quiet,0.0);scene.observe(quiet,.1);scene.observe(quiet,.2)
        assertFalse(scene.observe(quiet,2.0));assertFalse(scene.still);assertTrue(scene.invalidated)
        val moved=quiet.copyOf();for(y in 12..19)for(x in 12..19)moved[y*96+x]=220.toByte()
        assertTrue(SceneMonitor.difference(moved,quiet)>.012)
    }
    private fun motionFrame(patch: Int?=null,value: Byte=30,patchValue: Byte=220.toByte())=ByteArray(96*128){value}.also { pixels ->
        if(patch!=null)for(y in 24 until 36)for(x in patch until patch+12)pixels[y*96+x]=patchValue
    }
    private fun settledScene()=SceneMonitor().also { scene -> for(i in 0..4)scene.observe(motionFrame(),i*.05) }
    @Test fun isolatedSpikesAndBrightnessDriftNeverAccumulateIntoANewRoll() {
        val scene=settledScene()
        for(i in 5..100)assertFalse(scene.observe(motionFrame(if(i%10==0)12 else null),i*.05))
        for(i in 101..150)assertFalse(scene.observe(motionFrame(value=if(i%2==0)40 else 90),i*.05))
        for(i in 151..250)assertFalse(scene.observe(motionFrame(value=(i-100).toByte()),i*.05))
    }
    @Test fun sustainedSpatialMovementRearmsOnceAndCanRearmAgainAfterSettlement() {
        val scene=settledScene();var rolls=0
        for(i in 0..7){val moved=scene.observe(motionFrame(12+(i%5)*12),.25+i*.05);if(i==0)assertFalse(moved);if(moved)rolls++}
        assertEquals(1,rolls)
        for(i in 0..5)assertFalse(scene.observe(motionFrame(),.65+i*.05))
        assertTrue(scene.still)
        for(i in 0..5)if(scene.observe(motionFrame(12+i*12),1.0+i*.05))rolls++
        assertEquals(2,rolls)
    }
    @Test fun fastRollAlreadyStoppedAtSecondObservationStillRearms() {
        val scene=settledScene()
        assertFalse(scene.observe(motionFrame(24),.25))
        assertTrue(scene.observe(motionFrame(24),.30))
        for(i in 7..30)assertFalse(scene.observe(motionFrame(24),i*.05))
        assertTrue(scene.still)
    }
    @Test fun quietFrameDuringRollDoesNotEraseChangedSceneEvidence() {
        val scene=settledScene()
        assertFalse(scene.observe(motionFrame(12),.25))
        assertTrue(scene.observe(motionFrame(12),.30))
        assertFalse(scene.observe(motionFrame(36),.35))
    }
    @Test fun referenceAndSettlingAnchorDifferenceCannotRepeatedlyRearm() {
        val scene=SceneMonitor()
        for(i in 0..4)scene.observe(motionFrame(12,patchValue=(30+minOf(i,3)).toByte()),i*.05)
        assertFalse(scene.observe(motionFrame(12,patchValue=26),.25))
        assertFalse(scene.observe(motionFrame(12,patchValue=23),.30))
        assertTrue(scene.observe(motionFrame(12,patchValue=23),.35))
        for(i in 8..40)assertFalse(scene.observe(motionFrame(12,patchValue=23),i*.05))
    }
    @Test fun cameraGapBreaksConsecutiveMovementEvidence() {
        val scene=settledScene()
        assertFalse(scene.observe(motionFrame(12),.25))
        assertFalse(scene.observe(motionFrame(24),2.0));assertTrue(scene.invalidated)
        assertFalse(scene.observe(motionFrame(36),2.05))
        for(i in 1..10)assertFalse(scene.observe(motionFrame(),2.05+i*.05))
    }
    @Test fun rotationSamplingUsesTheUprightCropCoordinates() {
        assertEquals(1 to 2,sensorPoint(1,2,4,3,0))
        assertEquals(0 to 2,sensorPoint(0,0,4,3,90))
        assertEquals(3 to 0,sensorPoint(2,3,4,3,90))
        assertEquals(3 to 2,sensorPoint(0,0,4,3,180))
        assertEquals(3 to 0,sensorPoint(0,0,4,3,270))
    }
    @Test fun geometryMapsFullCropAndRejectsPadding() {
        val g=Geometry(900,1200,Region())
        assertEquals(10,g.x);assertEquals(120,g.y);assertEquals(740,g.cropWidth);assertEquals(960,g.cropHeight)
        val b=g.cameraBox((g.padX+g.resizedWidth/2.0)/416,.5,g.resizedWidth/416.0,1.0)!!
        assertEquals(10.0/900,b.x,1e-6);assertEquals(.1,b.y,1e-6);assertEquals(.8,b.height,1e-6)
        assertNull(g.cameraBox(.01,.5,.01,.1))
    }
    @Test fun preprocessingPreservesRgbAndPadsBlack() {
        val g=Geometry(300,400,Region(0.0,0.0,0.0,0.0));val input=ModelPixels.prepare(IntArray(300*400){0xff804020.toInt()},g)
        assertEquals(0f,input[0],0f)
        val i=208*416+208
        assertEquals(128/255f,input[i],1e-6f);assertEquals(64/255f,input[416*416+i],1e-6f);assertEquals(32/255f,input[2*416*416+i],1e-6f)
    }
    @Test fun classAgnosticNmsAndConfidenceAreJointScores() {
        val g=Geometry(416,416,Region(0.0,0.0,0.0,0.0))
        val boxes=floatArrayOf(.5f,.5f,.2f,.2f,.51f,.51f,.2f,.2f,.8f,.8f,.1f,.1f)
        val scores=FloatArray(18);scores[2]=.99f;scores[6+4]=.98f;scores[12+5]=.74f
        val result=DetectorMath.decode(boxes,scores,g)
        assertEquals(listOf(3),result.map { it.value })
        assertEquals(.4,result[0].box.x,1e-6)
    }
}
