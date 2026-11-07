package org.boardgamescafe.dicetower

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.auth.FirebaseAuth
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.tasks.await
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.nio.file.Files
import java.nio.file.StandardCopyOption

interface CloudBackend {
    suspend fun owner(): String
    suspend fun call(path: String,method: String="GET",body: JSONObject?=null,createOnly: Boolean=false): Reply
}
data class Reply(val code: Int,val body: JSONObject?)
class CloudFailure(val code: Int): Exception("Firebase request failed ($code)")

class FirebaseBackend(context: Context): CloudBackend {
    private val config=JSONObject(context.assets.open("firebase-config.json").bufferedReader().use { it.readText() })
    private val app=FirebaseApp.getApps(context).firstOrNull()?:FirebaseApp.initializeApp(context,FirebaseOptions.Builder()
        .setApplicationId(config.getString("appId")).setApiKey(config.getString("apiKey"))
        .setProjectId(config.getString("projectId")).setDatabaseUrl(config.getString("databaseURL")).build())
    private val auth=FirebaseAuth.getInstance(app)
    private suspend fun user()=auth.currentUser?:auth.signInAnonymously().await().user?:throw CloudFailure(401)
    override suspend fun owner()=user().uid
    override suspend fun call(path: String,method: String,body: JSONObject?,createOnly: Boolean): Reply {
        val token=user().getIdToken(false).await().token?:throw CloudFailure(401)
        return withContext(Dispatchers.IO) {
            val url=URI(config.getString("databaseURL")+"/"+path+".json?auth="+URLEncoder.encode(token,"UTF-8")).toURL()
            val connection=url.openConnection() as HttpURLConnection
            try {
                connection.requestMethod=method;connection.connectTimeout=20000;connection.readTimeout=20000
                connection.setRequestProperty("Content-Type","application/json")
                if(createOnly)connection.setRequestProperty("if-match","null_etag")
                if(body!=null){connection.doOutput=true;connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }}
                val code=connection.responseCode
                val data=(if(code in 200..299)connection.inputStream else connection.errorStream)?.bufferedReader()?.use { it.readText() }?:"null"
                if(code !in 200..299 && !(createOnly && code==412))throw CloudFailure(code)
                Reply(code,if(data.trim().startsWith("{"))JSONObject(data) else null)
            } catch(error: CloudFailure){throw error}
            catch(error: Exception){throw CloudFailure(0)}
            finally {connection.disconnect()}
        }
    }
}

/** Atomic files precede network writes; no auth token is part of this directory. */
class DiskOutbox(private val root: File) {
    data class Item(val file: File,val tower: String,val payload: JSONObject)
    fun put(kind: String,tower: String,id: String,payload: JSONObject) {
        require(kind in listOf("rolls","metrics") && id.matches(Regex("[A-Za-z0-9-]{1,64}")))
        val folder=File(root,kind).apply { mkdirs() }
        val temporary=File(folder,"$id.tmp")
        temporary.outputStream().use { stream -> stream.write(JSONObject().put("tower",tower).put("payload",payload).toString().toByteArray());stream.fd.sync() }
        Files.move(temporary.toPath(),File(folder,"$id.json").toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
    }
    fun files(kind: String)=File(root,kind).listFiles()?.filter { it.extension=="json" }?.sortedBy { it.name }?:emptyList()
    fun read(file: File): Item {
        val value=JSONObject(file.readText());return Item(file,value.getString("tower"),value.getJSONObject("payload"))
    }
    fun hold(file: File,kind: String,reason: String) {
        val folder=File(root,"Held/$kind/${file.name}").apply { mkdirs() }
        val metadata=File(folder,"reason.tmp")
        metadata.writeText(JSONObject().put("name",file.name).put("kind",kind).put("reason",reason.take(200)).put("heldAt",System.currentTimeMillis()).toString())
        Files.move(metadata.toPath(),File(folder,"reason.json").toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
        Files.move(file.toPath(),File(folder,"payload.json").toPath(),StandardCopyOption.ATOMIC_MOVE)
    }
    private fun held()=listOf("rolls","metrics").flatMap { File(root,"Held/$it").listFiles()?.toList()?:emptyList() }.filter { File(it,"payload.json").isFile }
    fun heldCount()=held().size
    fun heldIssue()=held().maxByOrNull { File(it,"reason.json").lastModified() }?.let { runCatching { JSONObject(File(it,"reason.json").readText()).getString("reason") }.getOrDefault("Held upload details unavailable") }?:""
    fun retryHeld() {
        for(folder in held()) {
            val metadata=JSONObject(File(folder,"reason.json").readText());val kind=metadata.getString("kind");val name=metadata.getString("name")
            require(kind in listOf("rolls","metrics") && File(name).name==name)
            val target=File(root,kind).apply { mkdirs() }
            Files.move(File(folder,"payload.json").toPath(),File(target,name).toPath(),StandardCopyOption.ATOMIC_MOVE)
            check(File(folder,"reason.json").delete());check(folder.delete())
        }
    }
    fun count()=listOf("rolls","metrics").sumOf { File(root,it).listFiles()?.count { f->f.extension=="json" }?:0 }
}

/** Transport policy is independent of Android and tested against lost ACKs/identity changes. */
class UploadDrain(private val backend: CloudBackend,private val outbox: DiskOutbox) {
    private fun permanent(error: Exception)=error !is CancellationException && (error is org.json.JSONException || error is java.io.IOException || error is IllegalStateException || (error is CloudFailure && error.code in listOf(400,403,413,422)))
    private fun hold(file: File,kind: String,error: Exception){outbox.hold(file,kind,"${if(kind=="rolls")"Roll" else "Metric"} ${file.nameWithoutExtension.take(8)}: ${error.message?:error.javaClass.simpleName}")}
    private suspend fun flushRolls(owner: String,enabled: ()->Boolean) {
        for(file in outbox.files("rolls")) {
            if(!enabled())return
            try {
                val item=outbox.read(file)
                check(item.tower==owner) { "Queued data belongs to another tower" }
                val wire=JSONObject(item.payload.toString()).put("receivedAt",JSONObject().put(".sv","timestamp"))
                val reply=backend.call("rolls/$owner/${item.payload.getString("eventId")}","PUT",wire,true)
                if(reply.code==412)check(reply.body?.optString("eventId")==item.payload.getString("eventId")) { "Conditional write did not acknowledge this event" }
                check(item.file.delete()) { "Could not acknowledge saved roll" }
            } catch(error: Exception){if(!permanent(error))throw error;hold(file,"rolls",error)}
        }
    }
    private suspend fun flushMetrics(owner: String,enabled: ()->Boolean) {
        if(!enabled())return
        val items=mutableListOf<DiskOutbox.Item>()
        for(file in outbox.files("metrics").take(100)) {
            try {val item=outbox.read(file);check(item.tower==owner){"Queued metrics belong to another tower"};items.add(item)}
            catch(error: Exception){if(!permanent(error))throw error;hold(file,"metrics",error)}
        }
        if(items.isEmpty())return
        sendMetricBatch(owner,items,enabled)
    }
    private suspend fun sendMetricBatch(owner: String,items: List<DiskOutbox.Item>,enabled: ()->Boolean) {
        if(!enabled() || items.isEmpty())return
        val batch=JSONObject();for(item in items)batch.put(item.payload.getString("metricId"),item.payload)
        try {backend.call("metrics/$owner","PATCH",batch)}
        catch(error: Exception) {
            if(!permanent(error))throw error
            if(items.size==1)hold(items[0].file,"metrics",error)
            else {
                val middle=items.size/2
                sendMetricBatch(owner,items.take(middle),enabled)
                sendMetricBatch(owner,items.drop(middle),enabled)
            }
            return
        }
        items.forEach { check(it.file.delete()) { "Could not acknowledge metrics" } }
    }
    suspend fun flush(owner: String,enabled: ()->Boolean) {
        check(backend.owner()==owner) { "Tower identity changed; queued data was preserved" }
        var rollError: Exception?=null
        try {flushRolls(owner,enabled)}catch(error: Exception){rollError=error}
        try {flushMetrics(owner,enabled)}catch(error: Exception){throw rollError?:error}
        rollError?.let { throw it }
    }

}

data class CloudUi(val name: String="",val towerId: String="",val sharing: Boolean=false,val queued: Int=0,val status: String="Roll sharing is off",val onboarding: Boolean=true,val busy: Boolean=false,val held: Int=0,val issue: String="")
class CloudPublisher(context: Context,private val scope: CoroutineScope,private val backend: CloudBackend=FirebaseBackend(context)) {
    private val prefs=context.getSharedPreferences("tower",Context.MODE_PRIVATE)
    private val outbox=DiskOutbox(File(context.noBackupFilesDir,"cloud-outbox"))
    private val drain=UploadDrain(backend,outbox)
    private val wake=Channel<Unit>(Channel.CONFLATED)
    @Volatile private var sharing=prefs.getBoolean("sharing",false)
    private var heartbeat=0L
    @Volatile private var latestMetric: JSONObject?=null
    private val _ui=MutableStateFlow(CloudUi(prefs.getString("name","")?:"",prefs.getString("towerId","")?:"",sharing,onboarding=!prefs.getBoolean("onboarded",false)))
    val ui=_ui.asStateFlow()
    init {
        scope.launch(Dispatchers.IO) {
            for(signal in wake) {
                try {
                    if(!sharing)continue
                    val owner=_ui.value.towerId
                    if(System.currentTimeMillis()-heartbeat>60000) {
                        check(backend.owner()==owner)
                        backend.call("towers/$owner","PATCH",JSONObject().put("updatedAt",JSONObject().put(".sv","timestamp")).put("sharing",true))
                        heartbeat=System.currentTimeMillis()
                    }
                    do { try {drain.flush(owner){sharing}} finally {refreshHeld(owner)} } while(sharing && outbox.count()>0)
                    if(sharing)_ui.value=_ui.value.copy(queued=0,held=outbox.heldCount(),issue=outbox.heldIssue(),status=if(outbox.heldCount()>0)"${outbox.heldCount()} held · ${outbox.heldIssue()} · other uploads continue" else "Live · ${_ui.value.name}")
                } catch(error: Exception) {
                    _ui.value=_ui.value.copy(queued=outbox.count(),held=outbox.heldCount(),issue=outbox.heldIssue(),status=if(sharing)"${outbox.count()} queued, ${outbox.heldCount()} held · ${error.message}" else "Roll sharing is off")
                }
            }
        }
    }
    private fun refreshHeld(owner: String) {
        val count=outbox.heldCount();val issue=outbox.heldIssue()
        val changed=count!=_ui.value.held || issue!=_ui.value.issue
        _ui.value=_ui.value.copy(held=count,issue=issue)
        if(changed && sharing)latestMetric?.let { old ->
            val metric=JSONObject(old.toString()).put("metricId",java.util.UUID.randomUUID().toString()).put("recordedAt",System.currentTimeMillis())
                .put("eventId","").put("duplicateDiscarded",false).put("duplicateOfEventId","").put("uploadHeldCount",count).put("uploadIssue",issue)
            outbox.put("metrics",owner,metric.getString("metricId"),metric)
        }
    }
    suspend fun configure(name: String): Boolean {
        val trimmed=name.trim()
        if(trimmed.isEmpty() || trimmed.length>60)return false
        _ui.value=_ui.value.copy(busy=true,status="Connecting…")
        return try {
            val owner=backend.owner();val existing=backend.call("towers/$owner").body
            backend.call("towers/$owner","PUT",JSONObject().put("name",trimmed).put("schemaVersion",1).put("sharing",true)
                .put("createdAt",existing?.opt("createdAt")?:JSONObject().put(".sv","timestamp")).put("updatedAt",JSONObject().put(".sv","timestamp")))
            prefs.edit().putString("name",trimmed).putString("towerId",owner).putBoolean("sharing",true).putBoolean("onboarded",true).apply()
            sharing=true;_ui.value=CloudUi(trimmed,owner,true,outbox.count(),"Live · $trimmed",false,false);wake.trySend(Unit);true
        } catch(error: Exception){_ui.value=_ui.value.copy(busy=false,status="Could not connect. Your local recognition still works.");false}
    }
    fun keepLocal() {
        sharing=false;prefs.edit().putBoolean("sharing",false).putBoolean("onboarded",true).apply()
        _ui.value=_ui.value.copy(sharing=false,onboarding=false,status="Roll sharing is off")
        val owner=_ui.value.towerId
        if(owner.isNotEmpty())scope.launch(Dispatchers.IO){runCatching { backend.call("towers/$owner","PATCH",JSONObject().put("sharing",false).put("updatedAt",JSONObject().put(".sv","timestamp"))) }}
    }
    fun enqueue(kind: String,payload: JSONObject) {
        if(!sharing)return
        val owner=_ui.value.towerId
        if(kind=="rolls" && payload.optInt("count")>30){_ui.value=_ui.value.copy(status="Reading too large to share");return}
        scope.launch(Dispatchers.IO) {
            try { if(kind=="metrics"){latestMetric=JSONObject(payload.toString());payload.put("uploadHeldCount",outbox.heldCount()).put("uploadIssue",outbox.heldIssue())}
                outbox.put(kind,owner,payload.getString(if(kind=="rolls")"eventId" else "metricId"),payload);_ui.value=_ui.value.copy(queued=outbox.count());wake.trySend(Unit) }
            catch(error: Exception){_ui.value=_ui.value.copy(status="Could not save upload queue. Check device storage.")}
        }
    }
    fun retryHeld(){scope.launch(Dispatchers.IO){runCatching { outbox.retryHeld();retry() }.onFailure { _ui.value=_ui.value.copy(status="Could not retry held uploads") }}}
    fun retry(){if(sharing)wake.trySend(Unit)}
}
