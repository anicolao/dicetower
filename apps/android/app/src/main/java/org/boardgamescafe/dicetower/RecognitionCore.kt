package org.boardgamescafe.dicetower

import kotlin.math.*

data class Region(val left: Double = 10.0/900, val top: Double = .1, val right: Double = 150.0/900, val bottom: Double = .1)
data class Box(val x: Double, val y: Double, val width: Double, val height: Double) {
    val cx get() = x + width/2
    val cy get() = y + height/2
}
data class Face(val value: Int, val confidence: Double, val box: Box)

/** Same measured-EMA/two-still-frame policy as iOS. Monotonic seconds. */
class RecognitionCycle {
    var inferenceMs = 0.0; private set
    var emaInferenceMs = 0.0; private set
    var processingMs = 0.0; private set
    var intervalMs = 50.0; private set
    var inferenceCount = 0; private set
    var agreementCount = 0; private set
    var quiescent = false; private set
    var nextStart = Double.NEGATIVE_INFINITY; private set
    private var startedAt = 0.0
    private var previous: List<Face>? = null
    fun reset() { previous = null; agreementCount = 0; quiescent = false; nextStart = Double.NEGATIVE_INFINITY }
    fun started(time: Double) { startedAt = time }
    fun complete(faces: List<Face>, still: Boolean, modelMs: Double, frameMs: Double, time: Double, valid: Boolean = true): Boolean {
        inferenceMs = max(0.0, modelMs); processingMs = max(0.0, frameMs)
        emaInferenceMs = if (inferenceCount == 0) inferenceMs else .2*inferenceMs + .8*emaInferenceMs
        inferenceCount++
        intervalMs = max(50.0, ceil((emaInferenceMs-1e-9)/50)*50)
        nextStart = max(startedAt + intervalMs/1000, ceil((time-1e-9)/.05)*.05)
        if (!valid || !still) { previous = null; agreementCount = 0; return false }
        agreementCount = if (previous?.let { matches(faces,it) } == true) agreementCount+1 else 1
        previous = faces
        if (agreementCount >= 2) { agreementCount = 2; quiescent = true; return true }
        return false
    }
    companion object {
        fun matches(a: List<Face>, b: List<Face>): Boolean {
            if (a.size != b.size) return false
            val remaining = b.toMutableList()
            for (face in a) {
                val i=remaining.indexOfFirst { it.value==face.value && abs(it.box.cx-face.box.cx)<.025 && abs(it.box.cy-face.box.cy)<.025 }
                if(i<0)return false
                remaining.removeAt(i)
            }
            return true
        }
    }
}

class SceneMonitor(private val threshold: Double = .012) {
    var still = false; private set
    private var previous: ByteArray? = null
    private var anchor: ByteArray? = null
    private var since = 0.0
    private var last = Double.NEGATIVE_INFINITY
    private var samples = 0
    fun reset() { still=false; previous=null; anchor=null; last=Double.NEGATIVE_INFINITY; samples=0 }
    /** True means invalidate the current recognition cycle after motion/gap. */
    fun observe(frame: ByteArray, time: Double): Boolean {
        require(frame.size==96*128)
        val prior=previous
        val gap=last.isFinite() && (time<=last || time-last>.6)
        val moved=prior!=null && (difference(frame,prior) > threshold || difference(frame,anchor?:prior)>threshold)
        val rearm=gap || (still && moved)
        if(prior==null || gap || moved) { still=false; since=time; anchor=frame; samples=1 }
        else { samples++; if(time-since>=.2 && samples>=3)still=true }
        previous=frame; last=time
        return rearm
    }
    companion object {
        fun difference(a: ByteArray,b: ByteArray): Double {
            var sum=0.0;var localMax=0.0
            for(y in 0 until 128 step 12)for(x in 0 until 96 step 12) {
                var local=0.0;var count=0
                for(yy in y until min(y+12,128))for(xx in x until min(x+12,96)) {
                    local+=abs((a[yy*96+xx].toInt() and 255)-(b[yy*96+xx].toInt() and 255));count++
                }
                sum+=local;localMax=max(localMax,local/count/255)
            }
            return max(sum/a.size/255,localMax/3)
        }
    }
}

class Geometry(val width: Int,val height: Int,region: Region) {
    val x=(width*region.left).roundToInt()
    val y=(height*region.top).roundToInt()
    val cropWidth=max(1,(width*(1-region.right)).roundToInt()-x)
    val cropHeight=max(1,(height*(1-region.bottom)).roundToInt()-y)
    private val fit=416.0/max(cropWidth,cropHeight)
    val resizedWidth=(cropWidth*fit).roundToInt()
    val resizedHeight=(cropHeight*fit).roundToInt()
    val padX=(416-resizedWidth)/2
    val padY=(416-resizedHeight)/2
    fun cameraBox(cx: Double,cy: Double,w: Double,h: Double): Box? {
        val sx=resizedWidth.toDouble()/cropWidth;val sy=resizedHeight.toDouble()/cropHeight
        val centerX=(cx*416-padX)/sx+x;val centerY=(cy*416-padY)/sy+y
        if(centerX<x || centerX>=x+cropWidth || centerY<y || centerY>=y+cropHeight)return null
        val left=max(x.toDouble(),centerX-w*416/sx/2);val top=max(y.toDouble(),centerY-h*416/sy/2)
        val right=min((x+cropWidth).toDouble(),centerX+w*416/sx/2);val bottom=min((y+cropHeight).toDouble(),centerY+h*416/sy/2)
        if(right<=left || bottom<=top)return null
        return Box(left/width,top/height,(right-left)/width,(bottom-top)/height)
    }
}

object DetectorMath {
    private data class Proposal(val value: Int,val score: Double,val cx: Double,val cy: Double,val w: Double,val h: Double)
    fun decode(boxes: FloatArray,scores: FloatArray,geometry: Geometry): List<Face> {
        require(boxes.size%4==0 && scores.size==boxes.size/4*6)
        val proposals=ArrayList<Proposal>()
        for(i in boxes.indices step 4) {
            val row=i/4;var label=0
            for(k in 1..5)if(scores[row*6+k]>scores[row*6+label])label=k
            val score=scores[row*6+label].toDouble()
            if(!score.isFinite() || score<.75)continue
            val c=Proposal(label+1,score,boxes[i].toDouble(),boxes[i+1].toDouble(),boxes[i+2].toDouble(),boxes[i+3].toDouble())
            if(listOf(c.cx,c.cy,c.w,c.h).all { it.isFinite() } && c.w>0 && c.h>0)proposals.add(c)
        }
        val kept=ArrayList<Proposal>()
        for(p in proposals.sortedByDescending { it.score }) {
            if(kept.none { iou(Box(p.cx-p.w/2,p.cy-p.h/2,p.w,p.h),Box(it.cx-it.w/2,it.cy-it.h/2,it.w,it.h))>.30 })kept.add(p)
        }
        return kept.mapNotNull { p -> geometry.cameraBox(p.cx,p.cy,p.w,p.h)?.let { Face(p.value,p.score,it) } }.sortedBy { it.box.cx }
    }
    fun iou(a: Box,b: Box): Double {
        val area=max(0.0,min(a.x+a.width,b.x+b.width)-max(a.x,b.x))*max(0.0,min(a.y+a.height,b.y+b.height)-max(a.y,b.y))
        val union=a.width*a.height+b.width*b.height-area
        return if(union>0)area/union else 0.0
    }
}

/** Separable Lanczos3 resampling in sRGB byte space, integer letterbox dimensions. */
object ModelPixels {
    private data class Taps(val indexes: IntArray,val weights: DoubleArray)
    private fun kernel(x: Double): Double = if(abs(x)<1e-9)1.0 else if(abs(x)>=3)0.0 else sin(PI*x)*sin(PI*x/3)/(PI*PI*x*x/3)
    private fun table(source: Int,target: Int): List<Taps> {
        val scale=source.toDouble()/target;val filter=max(1.0,scale);val support=3*filter
        return (0 until target).map { out ->
            val center=(out+.5)*scale
            val first=max(0,ceil(center-support-.5).toInt());val end=min(source-1,floor(center+support-.5).toInt())
            val indexes=(first..end).toList().toIntArray();val weights=DoubleArray(indexes.size) { kernel((indexes[it]+.5-center)/filter) }
            val total=weights.sum();for(i in weights.indices)weights[i]/=total
            Taps(indexes,weights)
        }
    }
    fun prepare(pixels: IntArray,g: Geometry): FloatArray {
        require(pixels.size==g.width*g.height)
        val horizontal=IntArray(g.resizedWidth*g.cropHeight)
        val tx=table(g.cropWidth,g.resizedWidth);val ty=table(g.cropHeight,g.resizedHeight)
        for(y in 0 until g.cropHeight)for(x in 0 until g.resizedWidth) {
            val taps=tx[x];var r=0.0;var green=0.0;var b=0.0
            for(i in taps.indexes.indices) {
                val p=pixels[(y+g.y)*g.width+g.x+taps.indexes[i]];val w=taps.weights[i]
                r+=((p ushr 16) and 255)*w;green+=((p ushr 8) and 255)*w;b+=(p and 255)*w
            }
            horizontal[y*g.resizedWidth+x]=(r.roundToInt().coerceIn(0,255) shl 16) or (green.roundToInt().coerceIn(0,255) shl 8) or b.roundToInt().coerceIn(0,255)
        }
        val result=FloatArray(3*416*416)
        for(y in 0 until g.resizedHeight)for(x in 0 until g.resizedWidth) {
            val taps=ty[y];var r=0.0;var green=0.0;var b=0.0
            for(i in taps.indexes.indices) {
                val p=horizontal[taps.indexes[i]*g.resizedWidth+x];val w=taps.weights[i]
                r+=((p ushr 16) and 255)*w;green+=((p ushr 8) and 255)*w;b+=(p and 255)*w
            }
            val offset=(y+g.padY)*416+x+g.padX
            result[offset]=r.roundToInt().coerceIn(0,255)/255f
            result[416*416+offset]=green.roundToInt().coerceIn(0,255)/255f
            result[2*416*416+offset]=b.roundToInt().coerceIn(0,255)/255f
        }
        return result
    }
}

/** Inverse of the clockwise sensor rotation; coordinates are inside cropRect. */
fun sensorPoint(x: Int,y: Int,width: Int,height: Int,rotation: Int): Pair<Int,Int> = when(rotation) {
    90 -> y to height-1-x
    180 -> width-1-x to height-1-y
    270 -> width-1-y to x
    else -> x to y
}
