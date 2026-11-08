package org.boardgamescafe.dicetower

import androidx.camera.core.Camera
import androidx.camera.core.CameraState
import androidx.camera.core.TorchState
import androidx.compose.runtime.*
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.Observer
import java.util.concurrent.Executor

/** A light belongs to this camera binding; no saved preference can relight it. */
class CameraLight {
    var available by mutableStateOf(false); private set
    var on by mutableStateOf(false); private set
    var busy by mutableStateOf(false); private set
    var message by mutableStateOf("Light unavailable on this camera"); private set
    private var camera: Camera?=null
    private var owner: LifecycleOwner?=null
    private var executor: Executor?=null
    private var request=0
    private var torchObserver: Observer<Int>?=null
    private var stateObserver: Observer<CameraState>?=null
    private val lifecycleObserver=LifecycleEventObserver { _,event -> if(event==Lifecycle.Event.ON_PAUSE)set(false) }

    fun attach(value: Camera,lifecycle: LifecycleOwner,main: Executor) {
        detach();camera=value;owner=lifecycle;executor=main
        lifecycle.lifecycle.addObserver(lifecycleObserver)
        torchObserver=Observer<Int> { if(camera===value)on=it==TorchState.ON }.also { value.cameraInfo.torchState.observe(lifecycle,it) }
        stateObserver=Observer<CameraState> { state ->
            if(camera===value) {
                val wasAvailable=available
                available=value.cameraInfo.hasFlashUnit() && state.type==CameraState.Type.OPEN
                if(wasAvailable && !available)set(false)
                if(!available)message="Light unavailable on this camera"
                else if(!busy)message="Continuous light for the tray"
            }
        }.also { value.cameraInfo.cameraState.observe(lifecycle,it) }
        // Clear any previous camera control state; enabling always requires a tap.
        if(value.cameraInfo.hasFlashUnit())set(false)
    }
    fun set(enabled: Boolean) {
        val value=camera?:return
        if(!value.cameraInfo.hasFlashUnit() || (enabled && !available))return
        val ticket=++request;busy=true
        val future=value.cameraControl.enableTorch(enabled)
        future.addListener({
            if(camera===value && ticket==request) {
                busy=false
                message=try { future.get();"Continuous light for the tray" }
                catch(_: Exception){"Could not change the light. Try again with the camera open."}
            }
        },executor!!)
    }
    fun detach() {
        request++
        camera?.let { value ->
            if(value.cameraInfo.hasFlashUnit())value.cameraControl.enableTorch(false)
            torchObserver?.let { value.cameraInfo.torchState.removeObserver(it) }
            stateObserver?.let { value.cameraInfo.cameraState.removeObserver(it) }
        }
        owner?.lifecycle?.removeObserver(lifecycleObserver)
        camera=null;owner=null;executor=null;torchObserver=null;stateObserver=null
        available=false;on=false;busy=false;message="Light unavailable on this camera"
    }
}
