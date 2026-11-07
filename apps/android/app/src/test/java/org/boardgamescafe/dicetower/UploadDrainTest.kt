package org.boardgamescafe.dicetower

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class UploadDrainTest {
    private fun roll(id: String)=JSONObject().put("eventId",id).put("count",0).put("total",0)
    private fun overflow(id: String)=JSONObject("""{"eventId":"$id","count":1,"total":4,"dice":[{"value":4,"confidence":1.0000001192092896,"box":{"x":0.2,"y":0.2,"width":0.1,"height":0.1}}]}""")
    @Test fun confidenceRepairKeepsOriginalBytesAndDeliversOriginalId()=runBlocking {
        val root=folder.newFolder();val outbox=DiskOutbox(root);val backend=Backend()
        val original=overflow("held");outbox.put("rolls","owner","held",original)
        val bytes=outbox.files("rolls").single().readBytes()
        outbox.hold(outbox.files("rolls").single(),"rolls","Firebase rejected saved data (401)")
        val states=mutableListOf<String>()
        UploadDrain(backend,outbox){ _,state,_ -> states.add(state) }.flush("owner"){true}
        assertEquals(listOf("queued","delivered"),states)
        assertEquals(0,outbox.heldCount());assertEquals(0,outbox.count())
        assertEquals(1.0,backend.events.getValue("rolls/owner/held").getJSONArray("dice").getJSONObject(0).getDouble("confidence"),0.0)
        assertArrayEquals(bytes,java.io.File(root,"Recovered/rolls/held.json/payload.json").readBytes())
    }
    @Test fun rejectionClearsOnlyItsOwnPendingDuplicateBaseline()=runBlocking {
        val outbox=DiskOutbox(folder.newFolder());val backend=Backend();val filter=ReportedRollFilter()
        val faces=listOf(Face(4,.9,Box(.2,.2,.1,.1)))
        filter.record(faces,"bad");backend.rejected.add("bad");outbox.put("rolls","owner","bad",roll("bad"))
        UploadDrain(backend,outbox){ payload,state,_ -> if(state=="rejected")filter.failed(payload.getString("eventId")) }.flush("owner"){true}
        assertNull(filter.duplicateEventId(faces))
        filter.record(faces,"new");assertFalse(filter.failed("bad"));assertEquals("new",filter.duplicateEventId(faces))
    }
    @Test fun invalidGeometryReportsFieldAndNonOwnerRecoveryStaysHeld()=runBlocking {
        val invalid=overflow("held");invalid.getJSONArray("dice").getJSONObject(0).getJSONObject("box").put("x",-1)
        try { normalizedRoll(invalid);fail() } catch(error: IllegalArgumentException){assertTrue(error.message!!.contains("dice[0].box"))}
        val root=folder.newFolder();val outbox=DiskOutbox(root);outbox.put("rolls","other","held",overflow("held"))
        outbox.hold(outbox.files("rolls").single(),"rolls","rejected")
        outbox.recoverConfidenceOvershoots("owner"){fail()};assertEquals(1,outbox.heldCount())
    }
    @Test fun rules401NeedsAuthRefreshButExpiredTokensStayRetryable() {
        assertFalse(UploadResponsePolicy.isPermanentRejection(401,"Permission denied",false))
        assertTrue(UploadResponsePolicy.isPermanentRejection(401,"Permission denied",true))
        assertFalse(UploadResponsePolicy.isPermanentRejection(401,"Auth token is expired",true))
        assertFalse(UploadResponsePolicy.isPermanentRejection(503,"Unavailable",true))
    }
    @get:Rule val folder=TemporaryFolder()
    private class Backend: CloudBackend {
        var uid="owner";var failed=false;var lostAck=false
        var rejectionCode=403
        val rejected=mutableSetOf<String>()
        val calls=mutableListOf<Triple<String,String,Boolean>>()
        val events=mutableMapOf<String,JSONObject>()
        override suspend fun owner()=uid
        override suspend fun call(path: String,method: String,body: JSONObject?,createOnly: Boolean): Reply {
            calls.add(Triple(path,method,createOnly))
            if(failed)throw CloudFailure(0)
            if((createOnly && path.substringAfterLast('/') in rejected) || (method=="PATCH" && body!=null && body.keys().asSequence().any { it in rejected }))throw CloudFailure(rejectionCode,rejected=rejectionCode==401)
            if(createOnly) {
                val old=events[path];if(old!=null)return Reply(412,old)
                events[path]=body!!
                if(lostAck){lostAck=false;throw CloudFailure(0)}
            }
            return Reply(200,body)
        }
    }
    @Test fun rollSurvivesFailedConnectionAndLostAckWithoutAnotherEvent()=runBlocking {
        val root=folder.newFolder();val outbox=DiskOutbox(root);val backend=Backend()
        outbox.put("rolls","owner","e1",roll("e1"))
        backend.failed=true
        try {UploadDrain(backend,outbox).flush("owner"){true};fail()}catch(_:CloudFailure){}
        assertEquals(1,DiskOutbox(root).count())
        backend.failed=false;backend.lostAck=true
        try {UploadDrain(backend,outbox).flush("owner"){true};fail()}catch(_:CloudFailure){}
        assertEquals(1,outbox.count())
        UploadDrain(backend,outbox).flush("owner"){true}
        assertEquals(0,outbox.count());assertEquals(1,backend.events.size)
        assertTrue(backend.calls.last().third)
    }
    @Test fun identityChangesNeverMoveQueuedDataToAnotherTower()=runBlocking {
        val outbox=DiskOutbox(folder.newFolder());val backend=Backend()
        outbox.put("rolls","old","e1",roll("e1"))
        UploadDrain(backend,outbox).flush("owner"){true}
        assertEquals(0,outbox.count());assertEquals(1,outbox.heldCount());assertTrue(backend.calls.isEmpty())
        outbox.retryHeld();assertEquals(1,outbox.count())
    }
    @Test fun metricsBatchIsSeparateAndFailureKeepsEveryFile()=runBlocking {
        val outbox=DiskOutbox(folder.newFolder());val backend=Backend()
        repeat(3){outbox.put("metrics","owner","m$it",JSONObject().put("metricId","m$it"))}
        backend.failed=true
        try {UploadDrain(backend,outbox).flush("owner"){true};fail()}catch(_:CloudFailure){}
        assertEquals(3,outbox.count());backend.failed=false
        UploadDrain(backend,outbox).flush("owner"){true}
        assertEquals(0,outbox.count());assertEquals("metrics/owner",backend.calls.last().first);assertEquals("PATCH",backend.calls.last().second)
    }
    @Test fun stoppedSharingLeavesQueueIntact()=runBlocking {
        val outbox=DiskOutbox(folder.newFolder());val backend=Backend()
        outbox.put("rolls","owner","e1",roll("e1"))
        UploadDrain(backend,outbox).flush("owner"){false}
        assertEquals(1,outbox.count());assertTrue(backend.calls.isEmpty())
    }
    @Test fun badMiddleFilesDoNotBlockLaterRollsOrMetricsAndCanBeRestored()=runBlocking {
        val root=folder.newFolder();val outbox=DiskOutbox(root);val backend=Backend()
        for(id in listOf("0-first","C-rejected","F-last"))outbox.put("rolls","owner",id,roll(id))
        java.io.File(root,"rolls/B-unreadable.json").writeText("not JSON")
        outbox.put("metrics","owner","metric",JSONObject().put("metricId","metric"))
        backend.rejected.add("C-rejected")
        UploadDrain(backend,outbox).flush("owner"){true}
        assertEquals(setOf("rolls/owner/0-first","rolls/owner/F-last"),backend.events.keys)
        assertTrue(backend.calls.any { it.first=="metrics/owner" });assertEquals(0,outbox.count());assertEquals(2,outbox.heldCount())
        outbox.retryHeld();assertEquals(2,outbox.count());assertEquals(0,outbox.heldCount())
        assertEquals("not JSON",java.io.File(root,"rolls/B-unreadable.json").readText())
    }
    @Test fun oneRejectedMetricIsIsolatedFromItsBatch()=runBlocking {
        val outbox=DiskOutbox(folder.newFolder());val backend=Backend()
        for(id in listOf("a","bad","z"))outbox.put("metrics","owner",id,JSONObject().put("metricId",id))
        backend.rejected.add("bad")
        UploadDrain(backend,outbox).flush("owner"){true}
        assertEquals(0,outbox.count());assertEquals(1,outbox.heldCount());assertTrue(outbox.heldIssue().contains("403"))
        assertEquals(5,backend.calls.size)
    }
    @Test fun refreshedPermissionDenied401DoesNotBlockFollowingRolls()=runBlocking {
        val outbox=DiskOutbox(folder.newFolder());val backend=Backend();backend.rejectionCode=401;backend.rejected.add("bad")
        for(id in listOf("0-first","bad","z-last"))outbox.put("rolls","owner",id,roll(id))
        UploadDrain(backend,outbox).flush("owner"){true}
        assertEquals(setOf("rolls/owner/0-first","rolls/owner/z-last"),backend.events.keys)
        assertEquals(1,outbox.heldCount());assertTrue(outbox.heldIssue().contains("401"))
    }
    @Test fun transientRollFailureDoesNotPreventMetricsAttempt()=runBlocking {
        val outbox=DiskOutbox(folder.newFolder());val backend=Backend();backend.failed=true
        outbox.put("rolls","owner","r",roll("r"));outbox.put("metrics","owner","m",JSONObject().put("metricId","m"))
        try {UploadDrain(backend,outbox).flush("owner"){true};fail()}catch(_:CloudFailure){}
        assertTrue(backend.calls.any { it.first=="metrics/owner" });assertEquals(2,outbox.count());assertEquals(0,outbox.heldCount())
    }
}
