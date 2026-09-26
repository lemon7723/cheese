package com.pocketkitty.pocket_kitty

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import android.util.Log
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.tensorflow.lite.Interpreter
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 宠了么 / 口袋毛孩 · Android 原生桥接（v1.3.0 · u2net 主模型 + u2netp 兜底）
 *
 * 抠图引擎：TensorFlow Lite + 全量 U2-Net（u2net.tflite，84MB，320×320 输入，7 路侧输出 d1~d7）
 *   + 兜底 u2netp.tflite（4.4MB）。主模型边缘质量最好；若华为低端机加载/推理 OOM，
 *   自动回退 u2netp，App 永不硬崩。完全离线，无任何 Google 服务依赖。
 *
 * 【v1.3.0 关键设计】
 * 1. 主模型恢复 84MB 全量 U2-Net：原"84MB OOM"根因是全分辨率 Bitmap（4000×3000≈48MB），
 *    已在 v1.2.0 用 512px 解码上限 + 推理后立即 recycle 根除，故恢复使用以提质。
 * 2. u2netp（4.4MB）作 OOM 自动兜底：两者均 320×320 输入、标准 CPU TFLite，回退零成本。
 * 3. 解码最长边强制压缩到 512px；推理结束立即 recycle Bitmap，内存快速释放。
 * 4. 保留 d1~d7 多通道切换逻辑（不同侧输出用于调整边缘细节）。
 * 5. 异常时在界面暴露具体 e.message（模型加载失败 / 内存溢出 / 无主体），便于排查。
 * 6. 不引入任何 play-services；AndroidManifest 无网络权限；纯离线。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "pet_segmentation/segment"

        /** 构建标识：首页底部可见，报错自动带上 */
        private const val BUILD_TAG = "v1.5.0"

        /** 主模型：全量 U2-Net（84MB，边缘质量最好），320×320 输入，7 路侧输出 d1~d7。
         *  原"84MB 在华为 OOM"根因是全分辨率 Bitmap（已用 512px 上限根除），故恢复使用。 */
        private const val PRIMARY_MODEL = "u2net.tflite"
        /** 兜底模型：u2netp（4.4MB）。主模型加载/推理 OOM 时自动回退，App 永不硬崩。 */
        private const val FALLBACK_MODEL = "u2netp.tflite"
        private const val MODEL_INPUT = 320

        /** 解码上限：强制压缩最长边到 512px（OOM 红线，绝不放大） */
        private const val DECODE_MAX_DIM = 512

        /** 最长边超过该值启用 2×2 贴片（512 下不会触发，保留作安全余量） */
        private const val TILE_THRESHOLD = 900

        /** 归一化百分位（杀灰雾的关键） */
        private const val PERCENTILE_LO = 0.02f
        private const val PERCENTILE_HI = 0.98f

        /** U2-Net 标准预处理：ImageNet mean/std 归一化 */
        private val MEAN = floatArrayOf(0.485f, 0.456f, 0.406f)
        private val STD = floatArrayOf(0.229f, 0.224f, 0.225f)
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var interpreter: Interpreter? = null

    /** 日志标签（logcat 过滤用：ChongLeMe） */
    private val TAG = "ChongLeMe"

    /** 当前实际生效的模型名（null = 尚未加载）。用于确定 84MB 主模型是否可用 */
    private var activeModelName: String? = null

    /** 兜底原因说明（仅在回退到 u2netp 时非空，区分是 OOM 还是其它加载失败） */
    private var fallbackNote: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "buildVersion" -> result.success(BUILD_TAG)
                    "modelInfo" -> {
                        // 报告当前实际生效的模型，用于确认 84MB 主模型在真机是否可用
                        val label = when (activeModelName) {
                            PRIMARY_MODEL -> "u2net 高清(84MB)"
                            FALLBACK_MODEL -> "u2netp 兜底(4.4MB)"
                            else -> "未加载"
                        }
                        result.success(
                            mapOf(
                                "buildTag" to BUILD_TAG,
                                "activeModel" to label,
                                "fallbackNote" to (fallbackNote ?: "")
                            )
                        )
                    }
                    "removeBackground" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("BAD_ARGS", "缺少图片路径", null)
                        } else {
                            val maskSource = (call.argument<Int>("maskSource") ?: 0)
                                .coerceIn(0, 6)
                            runSegmentation(path, maskSource, result)
                        }
                    }
                    "clickSound" -> {
                        try {
                            val tg = ToneGenerator(AudioManager.STREAM_MUSIC, 80)
                            tg.startTone(ToneGenerator.TONE_PROP_BEEP, 150)
                            mainHandler.postDelayed({ tg.release() }, 400)
                            result.success(null)
                        } catch (_: Exception) {
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun runSegmentation(path: String, maskSource: Int, result: MethodChannel.Result) {
        // src 声明在 try 之外，保证 catch 中一定可回收，避免异常路径 Bitmap 泄漏 / 编译错误
        var src: Bitmap? = null
        executor.execute {
            try {
                val segmenter = obtainInterpreter()
                val bmp = decodeScaled(path, DECODE_MAX_DIM)
                src = bmp

                // ---------- 贴片网格 ----------
                val grid = if (max(bmp.width, bmp.height) > TILE_THRESHOLD) 2 else 1
                val tileW0 = (bmp.width + grid - 1) / grid
                val tileH0 = (bmp.height + grid - 1) / grid
                // 重叠带：贴片尺寸的 12.5%，保证接缝处有渐变融合的空间
                val pad = max(8, (min(tileW0, tileH0) * 0.125f).roundToInt())

                val w = bmp.width
                val h = bmp.height
                val acc = FloatArray(w * h)
                val wgt = FloatArray(w * h)

                // 一次分配输出缓冲（7 路形状固定，贴片间复用）
                val outputs = HashMap<Int, Any>()
                val buffers = Array(segmenter.outputTensorCount) { idx ->
                    val count = segmenter.getOutputTensor(idx).shape()
                        .fold(1) { acc, d -> acc * maxOf(d, 1) }
                    ByteBuffer.allocateDirect(count * 4)
                        .order(ByteOrder.nativeOrder())
                        .also { outputs[idx] = it }
                }
                val outIdx = maskSource.coerceIn(0, segmenter.outputTensorCount - 1)

                // ---------- 逐贴片推理 + 加权融合 ----------
                for (j in 0 until grid) {
                    for (i in 0 until grid) {
                        val x0 = max(0, i * tileW0 - pad)
                        val y0 = max(0, j * tileH0 - pad)
                        val x1 = min(w, (i + 1) * tileW0 + pad)
                        val y1 = min(h, (j + 1) * tileH0 + pad)
                        val tw = x1 - x0
                        val th = y1 - y0

                        val tile = Bitmap.createBitmap(bmp, x0, y0, tw, th)
                        val mask320 = infer(segmenter, tile, outputs, outIdx)
                        val tileAlpha = upscaleMask(mask320, tw, th)

                        // 接缝羽化权重：重叠带内余弦渐变，图像边缘权重恒为 1
                        for (ty in 0 until th) {
                            val wy = edgeRamp(ty, th, pad, y0 == 0, y1 == h)
                            val rowA = (y0 + ty) * w
                            val rowT = ty * tw
                            for (tx in 0 until tw) {
                                val wx = edgeRamp(tx, tw, pad, x0 == 0, x1 == w)
                                val weight = wx * wy
                                if (weight <= 0f) continue
                                val gi = rowA + x0 + tx
                                acc[gi] += tileAlpha[rowT + tx] * weight
                                wgt[gi] += weight
                            }
                        }
                        tile.recycle()
                    }
                }

                // ---------- 后处理：百分位归一 → S 曲线 → 羽化 ----------
                val alpha8 = FloatArray(w * h)
                var filled = 0
                for (i in alpha8.indices) {
                    alpha8[i] = if (wgt[i] > 0f) acc[i] / wgt[i] else 0f
                    if (alpha8[i] > 127f) filled++
                }
                if (filled < w * h * 0.01f) {
                    throw IllegalStateException("没有识别到明确的主体，试试更清晰、宠物占比更大的照片")
                }

                robustNormalize(alpha8)
                sCurve(alpha8)
                boxBlur3(alpha8, w, h, radius = 2)

                // ---------- 合成透明 PNG ----------
                val pixels = IntArray(w * h)
                bmp.getPixels(pixels, 0, w, 0, 0, w, h)
                val out = IntArray(w * h)
                for (i in pixels.indices) {
                    val a = alpha8[i].roundToInt().coerceIn(0, 255)
                    val p = pixels[i]
                    out[i] = if (a == 0) 0
                    else Color.argb(a, Color.red(p), Color.green(p), Color.blue(p))
                }
                // 推理产物已用完，立刻释放原图 Bitmap（OOM 红线）
                bmp.recycle()
                src = null

                val resultBmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                resultBmp.setPixels(out, 0, w, 0, 0, w, h)

                val dir = getExternalFilesDir(null) ?: filesDir
                val file = File(dir, "cutout_${System.currentTimeMillis()}.png")
                FileOutputStream(file).use { fos ->
                    resultBmp.compress(Bitmap.CompressFormat.PNG, 100, fos)
                }
                resultBmp.recycle()

                mainHandler.post { result.success(file.absolutePath) }
            } catch (e: Throwable) {
                // 异常路径：回收 Bitmap，并向 Flutter 暴露可读的中文错误原因
                try { src?.recycle() } catch (_: Exception) { }
                src = null
                val msg = when {
                    e is OutOfMemoryError ||
                        e.message?.contains("memory", true) == true ->
                        "内存溢出：图片太大或设备内存不足，请换一张更小的照片重试"
                    e.message?.contains("模型", true) == true ||
                        e.message?.contains("APK", true) == true ->
                        "模型加载失败：u2net.tflite / u2netp.tflite 未打进安装包，请重新打包"
                    else -> "[${BUILD_TAG}] ${e.message ?: "抠图失败"}"
                }
                mainHandler.post { result.error("SEGMENT_FAIL", msg, null) }
            }
        }
    }

    /** 单次推理：bitmap → 320² 输入 → 指定侧输出读出 320² 显著性 FloatArray */
    private fun infer(
        segmenter: Interpreter,
        bitmap: Bitmap,
        outputs: HashMap<Int, Any>,
        outIdx: Int
    ): FloatArray {
        val input = buildInput(bitmap)
        segmenter.runForMultipleInputsOutputs(arrayOf(input), outputs)
        val buf = outputs[outIdx] as ByteBuffer
        buf.rewind()
        val mask = FloatArray(MODEL_INPUT * MODEL_INPUT)
        for (i in mask.indices) mask[i] = buf.float
        buf.rewind()
        return mask
    }

    /** 320² 显著性 → tw×th 灰度 Bitmap 的红色通道（0-255）。
     *  先 min-max 归一化，兼容模型输出 [0,1] 与未过 sigmoid 的 logits 两种情形。
     *  平坦贴片回退中性灰 128，避免大块纯色区被误擦成透明空洞。 */
    private fun upscaleMask(mask: FloatArray, tw: Int, th: Int): IntArray {
        var mn = Float.MAX_VALUE
        var mx = -Float.MAX_VALUE
        for (v in mask) {
            if (v < mn) mn = v
            if (v > mx) mx = v
        }
        val flat = (mx - mn) <= 1e-6f
        val small = Bitmap.createBitmap(MODEL_INPUT, MODEL_INPUT, Bitmap.Config.ARGB_8888)
        val sp = IntArray(MODEL_INPUT * MODEL_INPUT) { i ->
            val v = if (flat) 128
            else (((mask[i] - mn) / (mx - mn)) * 255f).toInt().coerceIn(0, 255)
            Color.rgb(v, v, v)
        }
        small.setPixels(sp, 0, MODEL_INPUT, 0, 0, MODEL_INPUT, MODEL_INPUT)
        val big = Bitmap.createScaledBitmap(small, tw, th, true)
        val bp = IntArray(tw * th)
        big.getPixels(bp, 0, tw, 0, 0, tw, th)
        big.recycle()
        small.recycle()
        // 返回红色通道标量（0-255）：融合循环 / robustNormalize / sCurve / boxBlur
        // 都把 tileAlpha[i] 当 0-255 灰度累加；bp 是打包 ARGB，其高位 0xFF 在有符号
        // int 下恒为负，若直接返回会让 acc 恒负、filled=0、必抛"没有识别到明确的主体"。
        return IntArray(tw * th) { Color.red(bp[it]) }
    }

    /**
     * 距贴片边的羽化权重：落在重叠带内做余弦渐变（0→1），
     * 贴片边紧贴图像边界的那一侧权重恒为 1（没有邻居需要融合）
     */
    private fun edgeRamp(pos: Int, len: Int, band: Int, edgeStart: Boolean, edgeEnd: Boolean): Float {
        val fromStart = if (edgeStart) 1f
        else if (pos >= band) 1f
        else {
            val t = pos.toFloat() / band
            (1 - cos(t * Math.PI)).toFloat() * 0.5f
        }
        val fromEnd = if (edgeEnd) 1f
        else if (pos < len - band) 1f
        else {
            val t = (len - 1 - pos).toFloat() / band
            (1 - cos(t * Math.PI)).toFloat() * 0.5f
        }
        return min(fromStart, fromEnd)
    }

    /**
     * 百分位归一化：只拉伸 2%~98% 分位之间的动态范围，
     * 背景的微弱响应直接归零——地砖灰雾和阴影放大效应的主要来源
     */
    private fun robustNormalize(data: FloatArray) {
        val hist = IntArray(256)
        for (v in data) hist[v.roundToInt().coerceIn(0, 255)]++
        val total = data.size
        val loTarget = (total * PERCENTILE_LO).roundToInt()
        val hiTarget = (total * PERCENTILE_HI).roundToInt()
        var cum = 0
        var lo = 0
        var hi = 255
        for (v in 0..255) {
            cum += hist[v]
            if (cum >= loTarget) { lo = v; break }
        }
        cum = 0
        for (v in 0..255) {
            cum += hist[v]
            if (cum >= hiTarget) { hi = v; break }
        }
        if (hi - lo < 8) { lo = 0; hi = 255 }
        val range = (hi - lo).toFloat()
        for (i in data.indices) {
            val t = ((data[i] - lo) / range).coerceIn(0f, 1f)
            data[i] = t * 255f
        }
    }

    /** S 曲线（smoothstep）：主体核心推向不透明，边缘保留半透明过渡 */
    private fun sCurve(data: FloatArray) {
        for (i in data.indices) {
            val t = data[i] / 255f
            data[i] = t * t * (3f - 2f * t) * 255f
        }
    }

    /** 三次半径 2 的可分离盒模糊 ≈ 高斯羽化，软化锯齿边缘 */
    private fun boxBlur3(data: FloatArray, w: Int, h: Int, radius: Int) {
        val tmp = FloatArray(data.size)
        repeat(3) {
            // 水平
            for (y in 0 until h) {
                val row = y * w
                var sum = 0f
                var count = 0
                for (x in -radius..radius) {
                    val xi = x.coerceIn(0, w - 1)
                    sum += data[row + xi]; count++
                }
                for (x in 0 until w) {
                    tmp[row + x] = sum / count
                    val outX = (x - radius).coerceIn(0, w - 1)
                    val inX = (x + radius + 1).coerceIn(0, w - 1)
                    sum += data[row + inX] - data[row + outX]
                }
            }
            // 垂直
            for (x in 0 until w) {
                var sum = 0f
                var count = 0
                for (y in -radius..radius) {
                    val yi = y.coerceIn(0, h - 1)
                    sum += tmp[yi * w + x]; count++
                }
                for (y in 0 until h) {
                    data[y * w + x] = sum / count
                    val outY = (y - radius).coerceIn(0, h - 1)
                    val inY = (y + radius + 1).coerceIn(0, h - 1)
                    sum += tmp[inY * w + x] - tmp[outY * w + x]
                }
            }
        }
    }

    /** 懒加载模型：先试主模型 u2net（84MB），OOM/失败则自动回退 u2netp（4.4MB）。
     *  两者均为 320×320 标准 CPU TFLite，回退零成本，App 永不因模型加载而硬崩。 */
    private fun obtainInterpreter(): Interpreter {
        synchronized(this) {
            interpreter?.let { return it }
            val segmenter = createSegmenter()
            interpreter = segmenter
            return segmenter
        }
    }

    /** 依次尝试 [主模型 u2net 84MB → 兜底 u2netp 4.4MB]，并记录实际生效模型与回退原因。
     *  任一成功即返回；全部失败抛可读错误。每次加载都打明确日志，便于真机确认 84MB 是否 OOM。 */
    private fun createSegmenter(): Interpreter {
        // —— 第一步：主模型 u2net（84MB，边缘质量最好）——
        try {
            val buffer = loadModelBuffer(PRIMARY_MODEL)
            val seg = Interpreter(buffer, Interpreter.Options().setNumThreads(4))
            try {
                val inShape = seg.getInputTensor(0).shape()
                if (inShape.any { it <= 0 }) {
                    seg.resizeInput(0, intArrayOf(1, MODEL_INPUT, MODEL_INPUT, 3))
                }
                seg.allocateTensors()
            } catch (e: Throwable) {
                seg.close()
                throw e
            }
            activeModelName = PRIMARY_MODEL
            fallbackNote = null
            Log.i(TAG, "[$BUILD_TAG] 主模型 u2net(84MB) 加载成功，使用高清模型")
            return seg
        } catch (e: Throwable) {
            val oom = isMemoryError(e)
            Log.w(
                TAG,
                "[$BUILD_TAG] 主模型 u2net(84MB) 加载/分配失败（${e.javaClass.simpleName}: ${e.message}），" +
                    "是否内存不足=$oom，将回退 u2netp 兜底"
            )

            // —— 第二步：兜底模型 u2netp（4.4MB）——
            try {
                val buffer = loadModelBuffer(FALLBACK_MODEL)
                val seg = Interpreter(buffer, Interpreter.Options().setNumThreads(4))
                try {
                    val inShape = seg.getInputTensor(0).shape()
                    if (inShape.any { it <= 0 }) {
                        seg.resizeInput(0, intArrayOf(1, MODEL_INPUT, MODEL_INPUT, 3))
                    }
                    seg.allocateTensors()
                } catch (e2: Throwable) {
                    seg.close()
                    throw e2
                }
                activeModelName = FALLBACK_MODEL
                fallbackNote = if (oom) "（主模型内存不足自动降级）" else "（主模型加载失败自动降级）"
                Log.w(TAG, "[$BUILD_TAG] 已回退到兜底模型 u2netp(4.4MB)${fallbackNote}")
                return seg
            } catch (e2: Throwable) {
                Log.e(TAG, "[$BUILD_TAG] 兜底模型 u2netp 也加载失败：${e2.message}")
            }
        }
        throw IllegalStateException(
            "模型加载失败：u2net.tflite 与 u2netp.tflite 均无法加载" +
                "。确认打包流程已把两个模型都下载到 android/app/src/main/assets/ 再重新构建。"
        )
    }

    /** 判断异常链里是否含内存不足（OutOfMemoryError / allocate 失败 / 含 oom/memory 字样的消息） */
    private fun isMemoryError(t: Throwable?): Boolean {
        var e = t
        while (e != null) {
            if (e is OutOfMemoryError) return true
            val m = e.message?.lowercase() ?: ""
            if (m.contains("oom") || m.contains("out of memory") ||
                m.contains("failed to allocate") || m.contains("memory")
            ) return true
            e = e.cause
        }
        return false
    }

    /** 从原生 AssetManager 读取指定模型；依次尝试 assets 根目录 / 两种 Flutter 资源历史写法 */
    private fun loadModelBuffer(assetName: String): ByteBuffer {
        val paths = listOf(
            assetName,
            "flutter_assets/$assetName",
            "flutter_assets/assets/models/$assetName"
        )
        var lastErr: Throwable? = null
        for (p in paths) {
            try {
                val bytes = assets.open(p).use { it.readBytes() }
                val buffer = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder())
                buffer.put(bytes)
                buffer.rewind()
                return buffer
            } catch (e: Throwable) { lastErr = e }
        }
        throw IllegalStateException(
            "找不到模型文件 $assetName（尝试路径：$paths，末次错误：${lastErr?.message}）"
        )
    }

    /** 原图 → 320×320 → 归一化 FloatBuffer */
    private fun buildInput(bitmap: Bitmap): ByteBuffer {
        val scaled = Bitmap.createScaledBitmap(bitmap, MODEL_INPUT, MODEL_INPUT, true)
        val pixels = IntArray(MODEL_INPUT * MODEL_INPUT)
        scaled.getPixels(pixels, 0, MODEL_INPUT, 0, 0, MODEL_INPUT, MODEL_INPUT)
        scaled.recycle()

        val buffer = ByteBuffer
            .allocateDirect(MODEL_INPUT * MODEL_INPUT * 3 * 4)
            .order(ByteOrder.nativeOrder())

        fun norm(channel: Int, ch: Int): Float =
            (channel / 255f - MEAN[ch]) / STD[ch]

        for (p in pixels) {
            buffer.putFloat(norm(Color.red(p), 0))
            buffer.putFloat(norm(Color.green(p), 1))
            buffer.putFloat(norm(Color.blue(p), 2))
        }
        buffer.rewind()
        return buffer
    }

    /** 解码 + 按最长边降采样到 512px 以内 + 按 EXIF 方向转正 */
    private fun decodeScaled(path: String, maxDim: Int): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        var side = maxOf(bounds.outWidth, bounds.outHeight)
        while (side / 2 >= maxDim) {
            sample *= 2
            side /= 2
        }
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        var bmp = BitmapFactory.decodeFile(path, opts)
            ?: throw IllegalStateException("不是有效的图片文件")

        // 强制最长边不超过 maxDim（OOM 红线：绝不把原图整张读进内存）
        if (max(bmp.width, bmp.height) > maxDim) {
            val scale = maxDim.toFloat() / max(bmp.width, bmp.height)
            val tw = max(1, (bmp.width * scale).roundToInt())
            val th = max(1, (bmp.height * scale).roundToInt())
            val scaled = Bitmap.createScaledBitmap(bmp, tw, th, true)
            bmp.recycle()
            bmp = scaled
        }

        val rotation = try {
            when (ExifInterface(path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL
            )) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (_: Exception) {
            0f
        }

        return if (rotation != 0f) {
            val matrix = Matrix().apply { postRotate(rotation) }
            val rotated = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, matrix, true)
            bmp.recycle()
            rotated
        } else {
            bmp
        }
    }

    override fun onDestroy() {
        executor.shutdown()
        interpreter?.close()
        interpreter = null
        super.onDestroy()
    }
}
