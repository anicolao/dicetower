package org.boardgamescafe.dicetower

import android.graphics.Bitmap
import android.graphics.Matrix
import android.util.Rational
import android.view.Surface
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import java.util.concurrent.Executors
import kotlin.math.*

/** Rotation is explicit; both use cases use the same portrait viewport/crop. */
@Composable fun CameraFeed(engine: RecognitionEngine,region: Region,modifier: Modifier=Modifier,light: CameraLight?=null,onError: (String)->Unit) {
    val context=LocalContext.current;val lifecycle=LocalLifecycleOwner.current
    val executor=remember { Executors.newSingleThreadExecutor() }
    val preview=remember { PreviewView(context).apply { implementationMode=PreviewView.ImplementationMode.COMPATIBLE;scaleType=PreviewView.ScaleType.FIT_CENTER } }
    val currentRegion by rememberUpdatedState(region)
    DisposableEffect(lifecycle,engine,light) {
        var disposed=false
        var provider: ProcessCameraProvider?=null
        val future=ProcessCameraProvider.getInstance(context)
        future.addListener({
            if(!disposed)try {
                val cameraProvider=future.get();provider=cameraProvider
                val resolution=ResolutionSelector.Builder().setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY).build()
                val display=Preview.Builder().setTargetRotation(Surface.ROTATION_0).setResolutionSelector(resolution).build().also { it.surfaceProvider=preview.surfaceProvider }
                val analysis=ImageAnalysis.Builder().setTargetRotation(Surface.ROTATION_0).setResolutionSelector(resolution).setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                var lastMotion=Double.NEGATIVE_INFINITY
                analysis.setAnalyzer(executor) { image ->
                    try {
                        val time=monotonicSeconds()
                        if(time-lastMotion>=.045) {
                            lastMotion=time
                            engine.observeMotion(luma(image,currentRegion),time)
                        }
                        if(engine.needsImage())engine.submit(uprightBitmap(image),time)
                    } catch(error: Exception){onError("Camera frame unavailable. Reopen the camera.")}
                    finally {image.close()}
                }
                val group=UseCaseGroup.Builder().setViewPort(ViewPort.Builder(Rational(3,4),Surface.ROTATION_0).setScaleType(ViewPort.FIT).build()).addUseCase(display).addUseCase(analysis).build()
                val camera=cameraProvider.bindToLifecycle(lifecycle,CameraSelector.DEFAULT_BACK_CAMERA,group)
                light?.attach(camera,lifecycle,ContextCompat.getMainExecutor(context))
                onError("")
            }catch(error: Exception){onError("Rear camera unavailable. Check camera permission and reopen the app.")}
        },ContextCompat.getMainExecutor(context))
        onDispose { disposed=true;light?.detach();provider?.unbindAll();executor.shutdown() }
    }
    AndroidView(factory={preview},modifier=modifier)
}

private fun uprightBitmap(image: ImageProxy): Bitmap {
    val original=image.toBitmap();val crop=image.cropRect
    val clipped=Bitmap.createBitmap(original,crop.left,crop.top,crop.width(),crop.height())
    if(image.imageInfo.rotationDegrees==0)return clipped
    return Bitmap.createBitmap(clipped,0,0,clipped.width,clipped.height,Matrix().apply { postRotate(image.imageInfo.rotationDegrees.toFloat()) },false)
}
private fun luma(image: ImageProxy,region: Region): ByteArray {
    val crop=image.cropRect;val rotated=image.imageInfo.rotationDegrees
    val width=if(rotated%180==0)crop.width() else crop.height();val height=if(rotated%180==0)crop.height() else crop.width()
    val plane=image.planes[0];val buffer=plane.buffer;val start=buffer.position()
    val pixels=ByteArray(96*128)
    for(y in 0 until 128)for(x in 0 until 96) {
        val ux=((region.left+(x+.5)/96*(1-region.left-region.right))*width).toInt().coerceIn(0,width-1)
        val uy=((region.top+(y+.5)/128*(1-region.top-region.bottom))*height).toInt().coerceIn(0,height-1)
        val (rx,ry)=sensorPoint(ux,uy,crop.width(),crop.height(),rotated)
        val sx=rx+crop.left;val sy=ry+crop.top
        var total=0
        for(dy in 0..1)for(dx in 0..1) {
            val xx=min(sx+dx,crop.right-1);val yy=min(sy+dy,crop.bottom-1)
            total+=buffer.get(start+yy*plane.rowStride+xx*plane.pixelStride).toInt() and 255
        }
        pixels[y*96+x]=(total/4).toByte()
    }
    return pixels
}
