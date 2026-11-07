package org.boardgamescafe.dicetower

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.setContent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import java.util.Locale

private val ink=Color(0xFF123335)
private val mint=Color(0xFF54D8B1)
class MainActivity: ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContent { MaterialTheme(colorScheme=lightColorScheme(primary=ink,secondary=mint,background=Color(0xFFF6F5EF),surface=Color(0xFFF6F5EF))) { TowerScreen() } }
    }
}

@Composable private fun TowerScreen(model: TowerViewModel=viewModel()) {
    val context=LocalContext.current
    val state by model.engine.ui.collectAsStateWithLifecycle()
    val cloud by model.cloud.ui.collectAsStateWithLifecycle()
    val region by model.region.collectAsStateWithLifecycle()
    var permission by remember { mutableStateOf(ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED) }
    var asked by remember { mutableStateOf(false) }
    var cameraError by remember { mutableStateOf<String?>(null) }
    var showSharing by remember { mutableStateOf(false) }
    var showRegion by remember { mutableStateOf(false) }
    val launcher=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { permission=it;if(it)model.resumed() }
    val lifecycle=LocalLifecycleOwner.current
    DisposableEffect(lifecycle) {
        val observer=LifecycleEventObserver { _,event ->
            if(event==Lifecycle.Event.ON_RESUME) {
                permission=ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED
                if(permission)model.resumed()
            }
            if(event==Lifecycle.Event.ON_PAUSE)model.paused()
        }
        lifecycle.lifecycle.addObserver(observer)
        if(permission && lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))model.resumed()
        onDispose { lifecycle.lifecycle.removeObserver(observer);model.paused() }
    }
    val message=if(state.timing.phase=="quiescent")"${state.faces.size} dice · Total ${state.faces.sumOf { it.value }}" else "Reading dice…"
    Scaffold(containerColor=Color(0xFFF6F5EF)) { padding ->
        Column(Modifier.padding(padding).padding(horizontal=18.dp).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(14.dp)) {
            Spacer(Modifier.height(8.dp))
            Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                Text("DiceTower",style=MaterialTheme.typography.headlineSmall,color=ink,modifier=Modifier.weight(1f))
                TextButton(onClick={showRegion=true}){Text("Tray area")}
            }
            Text(message,style=MaterialTheme.typography.headlineSmall,color=ink)
            Text(cameraError?:state.message,fontSize=12.sp,color=ink)
            MetricsPanel(state.timing)
            Text(cloud.delivery,fontSize=12.sp,color=ink)
            Box(Modifier.fillMaxWidth().aspectRatio(3f/4f).background(Color.Black)) {
                if(permission)CameraFeed(model.engine,region,Modifier.fillMaxSize()){cameraError=it.takeIf { message -> message.isNotEmpty() }}
                else Column(Modifier.align(Alignment.Center).padding(20.dp),horizontalAlignment=Alignment.CenterHorizontally) {
                    Text("Allow the rear camera to recognize dice.",color=Color.White)
                    Button(onClick={if(!asked){asked=true;launcher.launch(Manifest.permission.CAMERA)}else context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:${context.packageName}")))}) { Text(if(asked)"Open camera settings" else "Allow camera") }
                }
                DiceOverlay(state,region,Modifier.fillMaxSize())
            }
            OutlinedButton(onClick={showSharing=true},modifier=Modifier.fillMaxWidth()) { Text("${cloud.status}${if(cloud.queued>0)" · ${cloud.queued} queued" else ""}") }
            Text("Experimental: check every highlighted face, especially touching dice. Recognition runs on this phone; published thumbnails and predictions are visible to observers.",fontSize=12.sp,color=ink)
            if(cloud.towerId.isNotEmpty())TextButton(onClick={context.startActivity(Intent(Intent.ACTION_VIEW,Uri.parse("https://anicolao.github.io/dicetower/?tower=${cloud.towerId}")))}) {Text("Open this tower’s observer ↗")}
            Text("Android prototype · local photo collection and ZIP export will follow.",fontSize=11.sp,color=ink)
            Spacer(Modifier.height(20.dp))
        }
    }
    if(showSharing || cloud.onboarding) {
        var name by remember { mutableStateOf(cloud.name) }
        AlertDialog(onDismissRequest={if(!cloud.onboarding)showSharing=false},title={Text("Name your DiceTower")},text={Column(verticalArrangement=Arrangement.spacedBy(12.dp)) {
            Text("Choose this tower at anicolao.github.io/dicetower. Each tower has its own roll and timing streams.")
            OutlinedTextField(name,{if(it.length<=60)name=it},label={Text("Tower name")},singleLine=true)
            Text("Sharing publishes your tower name, small camera thumbnails, experimental dice results and timing metrics to anonymous observers. Stopping sharing leaves existing history visible.",fontSize=12.sp)
            Text(cloud.status,fontSize=12.sp)
            if(cloud.held>0)TextButton(onClick={model.cloud.retryHeld()}){Text("Retry held uploads (${cloud.held})")}
        }},confirmButton={TextButton(enabled=!cloud.busy && name.trim().isNotEmpty(),onClick={model.connect(name){showSharing=false}}){Text(if(cloud.busy)"Connecting…" else "Start sharing")}},dismissButton={TextButton(enabled=!cloud.busy,onClick={model.cloud.keepLocal();showSharing=false}){Text(if(cloud.sharing)"Stop sharing" else "Keep local")}})
    }
    if(showRegion)AlertDialog(onDismissRequest={showRegion=false},title={Text("Tray area")},text={Column {
        Text("Keep every die inside the highlighted area. It controls motion and model input.",fontSize=12.sp)
        listOf("Left" to region.left,"Right" to region.right,"Top" to region.top,"Bottom" to region.bottom).forEach { (label,value) ->
            Text("$label ${(value*100).toInt()}%",fontSize=12.sp)
            Slider(value.toFloat(),{ v->model.setRegion(when(label){"Left"->region.copy(left=v.toDouble());"Right"->region.copy(right=v.toDouble());"Top"->region.copy(top=v.toDouble());else->region.copy(bottom=v.toDouble())}) },valueRange=0f..0.45f,steps=44)
        }
    }},confirmButton={TextButton(onClick={showRegion=false}){Text("Done")}},dismissButton={TextButton(onClick={model.setRegion(Region())}){Text("Reset")}})
}

@Composable private fun MetricsPanel(t: Timing) {
    fun ms(v: Double)=if(t.inferenceCount==0)"—" else String.format(Locale.US,"%.1f ms",v)
    Card(colors=CardDefaults.cardColors(containerColor=mint.copy(alpha=.17f)),modifier=Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
            Text(if(t.phase=="quiescent")"Watching for motion · ML idle" else "Recognition · ${t.phase}",fontSize=12.sp,color=ink)
            Text("Inference ${ms(t.inferenceMs)} · EMA ${ms(t.emaInferenceMs)}",fontSize=12.sp,color=ink)
            Text("Frame ${ms(t.processingMs)} · Target ${t.intervalMs.toInt()} ms",fontSize=12.sp,color=ink)
            Text("${t.inferenceCount} inferences · ${t.agreementCount}/2 agree · 200 ms settlement",fontSize=12.sp,color=ink)
            Text("${t.duplicateCount} duplicates discarded this session${if(t.duplicateDiscarded)" · last reading discarded" else ""}",fontSize=12.sp,color=ink)
        }
    }
}
@Composable private fun DiceOverlay(state: RecognitionUi,region: Region,modifier: Modifier) {
    Canvas(modifier) {
        val width=minOf(size.width,size.height*state.aspect);val height=width/state.aspect
        val ox=(size.width-width)/2;val oy=(size.height-height)/2
        drawRect(mint,Offset(ox+(region.left*width).toFloat(),oy+(region.top*height).toFloat()),Size(((1-region.left-region.right)*width).toFloat(),((1-region.top-region.bottom)*height).toFloat()),style=Stroke(2.dp.toPx()))
        val color=if(state.timing.phase=="quiescent")mint else Color.Yellow
        val paint=android.graphics.Paint().apply {textSize=16.dp.toPx();isAntiAlias=true;this.color=android.graphics.Color.BLACK;typeface=android.graphics.Typeface.DEFAULT_BOLD}
        for(face in state.faces) {
            val x=ox+(face.box.x*width).toFloat();val y=oy+(face.box.y*height).toFloat()
            drawRect(color,Offset(x,y),Size((face.box.width*width).toFloat(),(face.box.height*height).toFloat()),style=Stroke(2.dp.toPx()))
            val labelY=maxOf(22.dp.toPx(),y)
            drawRect(color,Offset(x,labelY-22.dp.toPx()),Size(22.dp.toPx(),22.dp.toPx()))
            drawContext.canvas.nativeCanvas.drawText(face.value.toString(),x+6.dp.toPx(),labelY-5.dp.toPx(),paint)
        }
    }
}
