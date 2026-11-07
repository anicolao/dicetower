package org.boardgamescafe.dicetower

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

class TowerViewModel(application: Application): AndroidViewModel(application) {
    private val preferences=application.getSharedPreferences("rig",0)
    private val _region=MutableStateFlow(Region(preferences.getFloat("left",(10.0/900).toFloat()).toDouble(),preferences.getFloat("top",.1f).toDouble(),preferences.getFloat("right",(150.0/900).toFloat()).toDouble(),preferences.getFloat("bottom",.1f).toDouble()))
    val region=_region.asStateFlow()
    val cloud=CloudPublisher(application,viewModelScope)
    val engine=RecognitionEngine(application,{ cloud.enqueue("rolls",it) },{ cloud.enqueue("metrics",it) })
    @Volatile private var foreground=false
    init {
        engine.setRegion(_region.value)
        viewModelScope.launch { while(true){delay(15000);if(foreground)cloud.retry()} }
    }
    fun resumed(){foreground=true;engine.reset();cloud.retry()}
    fun paused(){foreground=false;engine.reset(true)}
    fun setRegion(value: Region) {
        _region.value=value
        preferences.edit().putFloat("left",value.left.toFloat()).putFloat("right",value.right.toFloat()).putFloat("top",value.top.toFloat()).putFloat("bottom",value.bottom.toFloat()).apply()
        engine.setRegion(value)
    }
    fun connect(name: String,onSuccess: ()->Unit) { viewModelScope.launch { if(cloud.configure(name)){engine.reset(clearReportedHistory=true);onSuccess()} } }
    override fun onCleared(){engine.close();super.onCleared()}
}
