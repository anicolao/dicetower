package org.boardgamescafe.dicetower

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class UploadDrainTest {
    @get:Rule val folder=TemporaryFolder()
    private class Backend: CloudBackend {
        var uid="owner";var failed=false;var lostAck=false
        val calls=mutableListOf<Triple<String,String,Boolean>>()
        val events=mutableMapOf<String,JSONObject>()
        override suspend fun owner()=uid
        override suspend fun call(path: String,method: String,body: JSONObject?,createOnly: Boolean): Reply {
            calls.add(Triple(path,method,createOnly))
            if(failed)throw CloudFailure(0)
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
        outbox.put("rolls","owner","e1",JSONObject().put("eventId","e1"))
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
        outbox.put("rolls","old","e1",JSONObject().put("eventId","e1"))
        try {UploadDrain(backend,outbox).flush("owner"){true};fail()}catch(_:IllegalStateException){}
        assertEquals(1,outbox.count());assertTrue(backend.calls.isEmpty())
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
        outbox.put("rolls","owner","e1",JSONObject().put("eventId","e1"))
        UploadDrain(backend,outbox).flush("owner"){false}
        assertEquals(1,outbox.count());assertTrue(backend.calls.isEmpty())
    }
}
