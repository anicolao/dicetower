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
class CloudFailure(val code: Int,val rejected: Boolean=false): Exception("Firebase request ${if(rejected)"rejected saved data" else "failed"} ($code)")

class FirebaseBackend(context: Context): CloudBackend {
    private val config=JSONObject(context.assets.open("firebase-config.json").bufferedReader().use { it.readText() })
    private val app=FirebaseApp.getApps(context).firstOrNull()?:FirebaseApp.initializeApp(context,FirebaseOptions.Builder()
        .setApplicationId(config.getString("appId")).setApiKey(config.getString("apiKey"))
        .setProjectId(config.getString("projectId")).setDatabaseUrl(config.getString("databaseURL")).build())
    private val auth=FirebaseAuth.getInstance(app)
    private suspend fun user()=auth.currentUser?:auth.signInAnonymously().await().user?:throw CloudFailure(401)
    override suspend fun owner()=user().uid
    override suspend fun call(path: String,method: String,body: JSONObject?,createOnly: Boolean): Reply {
        return request(path,method,body,createOnly,false)
    }
    private suspend fun request(path: String,method: String,body: JSONObject?,createOnly: Boolean,refreshed: Boolean): Reply {
        val token=user().getIdToken(refreshed).await().token?:throw CloudFailure(401)
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
                if(code==401 && !refreshed){connection.disconnect();return@withContext request(path,method,body,createOnly,true)}
                val rejected=code==401 && runCatching { UploadResponsePolicy.isPermanentRejection(code,JSONObject(data).optString("error"),refreshed) }.getOrDefault(false)
                if(code !in 200..299 && !(createOnly && code==412))throw CloudFailure(code,rejected)
                Reply(code,if(data.trim().startsWith("{"))JSONObject(data) else null)
            } catch(error: CloudFailure){throw error}
            catch(error: Exception){throw CloudFailure(0)}
            finally {connection.disconnect()}
        }
    }
}

/** Normalize finite confidence, but reject invalid geometry with a field-level reason. */
fun normalizedRoll(original: JSONObject): JSONObject {
    val roll=JSONObject(original.toString());val dice=roll.optJSONArray("dice")?:org.json.JSONArray()
    require(roll.getInt("count")==dice.length() && dice.length()<=30) { "Invalid roll count" }
    var total=0
    for(i in 0 until dice.length()) {
        val face=dice.getJSONObject(i);val value=face.getInt("value");require(value in 1..6){"Invalid dice[$i].value"};total+=value
        val confidence=face.getDouble("confidence");require(confidence.isFinite()){"Invalid dice[$i].confidence (non-finite)"}
        face.put("confidence",confidence.coerceIn(0.0,1.0))
        val b=face.getJSONObject("box");val x=b.getDouble("x");val y=b.getDouble("y");val w=b.getDouble("width");val h=b.getDouble("height")
        require(listOf(x,y,w,h).all { it.isFinite() } && x in 0.0..1.0 && y in 0.0..1.0 && w>0 && h>0 && w<=1 && h<=1 && x+w<=1.000001 && y+h<=1.000001){"Invalid dice[$i].box"}
    }
    require(roll.getInt("total")==total){"Invalid roll total"}
    return roll
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
    fun recoverConfidenceOvershoots(owner: String,onRecovered: (JSONObject)->Unit) {
        for(folder in held().filter { it.parentFile.name=="rolls" }) {
            val item=runCatching { read(File(folder,"payload.json")) }.getOrNull()?:continue
            if(item.tower!=owner)continue
            val dice=item.payload.optJSONArray("dice")?:continue
            val scores=(0 until dice.length()).map { dice.getJSONObject(it).getDouble("confidence") }
            if(!scores.any { it>1 } || !scores.all { it.isFinite() && it in 0.0..1.00001 })continue
            val repaired=runCatching { normalizedRoll(item.payload) }.getOrNull()?:continue
            val id=repaired.getString("eventId");if(folder.name!="$id.json" || File(root,"rolls/$id.json").exists())continue
            val archive=File(root,"Recovered/rolls/${folder.name}")
            if(!archive.exists())check(folder.copyRecursively(archive,overwrite=false)){"Could not preserve original held record"}
            put("rolls",owner,id,repaired)
            check(folder.deleteRecursively()){ "Could not complete recovery" }
            onRecovered(repaired)
        }
    }
    fun count()=listOf("rolls","metrics").sumOf { File(root,it).listFiles()?.count { f->f.extension=="json" }?:0 }
}

/** Transport policy is independent of Android and tested against lost ACKs/identity changes. */
class UploadDrain(private val backend: CloudBackend,private val outbox: DiskOutbox,private val onDelivery: (JSONObject,String,String)->Unit={ _,_,_ -> }) {
    private fun permanent(error: Exception)=error !is CancellationException && (error is org.json.JSONException || error is java.io.IOException || error is IllegalStateException || error is IllegalArgumentException || (error is CloudFailure && (error.rejected || UploadResponsePolicy.isPermanentRejection(error.code,"",false))))
    private fun hold(file: File,kind: String,error: Exception){
        val roll=if(kind=="rolls")runCatching { outbox.read(file).payload }.getOrNull() else null
        outbox.hold(file,kind,"${if(kind=="rolls")"Roll" else "Metric"} ${file.nameWithoutExtension.take(8)}: ${error.message?:error.javaClass.simpleName}")
        if(roll!=null)onDelivery(roll,"rejected",error.message?:error.javaClass.simpleName)
    }
    private suspend fun flushRolls(owner: String,enabled: ()->Boolean) {
        for(file in outbox.files("rolls")) {
            if(!enabled())return
            try {
                val item=outbox.read(file)
                check(item.tower==owner) { "Queued data belongs to another tower" }
                val wire=normalizedRoll(item.payload).put("receivedAt",JSONObject().put(".sv","timestamp"))
                val reply=backend.call("rolls/$owner/${item.payload.getString("eventId")}","PUT",wire,true)
                if(reply.code==412)check(reply.body?.optString("eventId")==item.payload.getString("eventId")) { "Conditional write did not acknowledge this event" }
                check(item.file.delete()) { "Could not acknowledge saved roll" }
                onDelivery(item.payload,"delivered","Server acknowledged this event")
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
        outbox.recoverConfidenceOvershoots(owner){onDelivery(it,"queued","Recovered confidence overflow; original retained on phone")}
        var rollError: Exception?=null
        try {flushRolls(owner,enabled)}catch(error: Exception){rollError=error}
        try {flushMetrics(owner,enabled)}catch(error: Exception){throw rollError?:error}
        rollError?.let { throw it }
    }

}

data class CloudUi(val name: String="",val towerId: String="",val sharing: Boolean=false,val queued: Int=0,val status: String="Roll sharing is off",val onboarding: Boolean=true,val busy: Boolean=false,val held: Int=0,val issue: String="",val delivery: String="No roll sent this session")
class CloudPublisher(context: Context,private val scope: CoroutineScope,private val backend: CloudBackend=FirebaseBackend(context)) {
    private val prefs=context.getSharedPreferences("tower",Context.MODE_PRIVATE)
    private val outbox=DiskOutbox(File(context.noBackupFilesDir,"cloud-outbox"))
    private val drain=UploadDrain(backend,outbox){ roll,state,detail -> recordDelivery(roll,state,detail) }
    var onDeliveryFailure: ((String)->Unit)?=null
    @Volatile private var deliveryFields: JSONObject?=null
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
    private fun recordDelivery(roll: JSONObject,state: String,detail: String) {
        val id=roll.getString("eventId");val dice=roll.optJSONArray("dice");val values=if(dice==null)"" else (0 until dice.length()).joinToString(","){dice.getJSONObject(it).getInt("value").toString()}
        val fields=JSONObject().put("deliveryEventId",id).put("deliveryState",state).put("deliveryValues",values).put("deliveryDetail",detail.take(180)).put("deliveryAt",System.currentTimeMillis())
        deliveryFields=fields
        _ui.value=_ui.value.copy(delivery="${state.replaceFirstChar { it.uppercase() }} · ${values.ifEmpty { "empty tray" }} · ${id.take(8)} · ${detail.take(180)}")
        if(state=="rejected" || state=="queueFailed")onDeliveryFailure?.invoke(id)
        if(sharing)latestMetric?.let { old ->
            val sample=JSONObject(old.toString()).put("metricId",java.util.UUID.randomUUID().toString()).put("recordedAt",System.currentTimeMillis())
                .put("eventId","").put("duplicateDiscarded",false).put("duplicateOfEventId","")
                .put("uploadHeldCount",outbox.heldCount()).put("uploadIssue",outbox.heldIssue())
            fields.keys().forEach { key -> sample.put(key,fields.get(key)) }
            runCatching { outbox.put("metrics",_ui.value.towerId,sample.getString("metricId"),sample);wake.trySend(Unit) }
                .onFailure { _ui.value=_ui.value.copy(status="Could not save delivery diagnostics: ${it.message}") }
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

        scope.launch(Dispatchers.IO) {
            try {
                val saved=if(kind=="rolls")normalizedRoll(payload) else JSONObject(payload.toString())
                if(kind=="metrics") {
                    latestMetric=JSONObject(saved.toString());saved.put("uploadHeldCount",outbox.heldCount()).put("uploadIssue",outbox.heldIssue())
                    deliveryFields?.let { fields -> fields.keys().forEach { key -> saved.put(key,fields.get(key)) } }
                }
                outbox.put(kind,owner,saved.getString(if(kind=="rolls")"eventId" else "metricId"),saved)
                if(kind=="rolls")recordDelivery(saved,"queued","Saved on phone; awaiting server acknowledgement")
                _ui.value=_ui.value.copy(queued=outbox.count());wake.trySend(Unit)
            } catch(error: Exception){
                if(kind=="rolls")recordDelivery(payload,"queueFailed",error.message?:"Could not save upload queue")
                _ui.value=_ui.value.copy(status="Could not save upload queue: ${error.message}")
            }
        }
    }
    fun retryHeld(){scope.launch(Dispatchers.IO){runCatching { outbox.retryHeld();retry() }.onFailure { _ui.value=_ui.value.copy(status="Could not retry held uploads") }}}
    fun retry(){if(sharing)wake.trySend(Unit)}
}
