package com.hui.ting

import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Android 侧的音频桥：替代 macOS 的 tingo-recorder 子进程、iOS 的 TingoAudio.swift。
 *
 * Rust 通过 JNI 反射调用这里带 @JvmStatic 的方法（见 app/engine/src/android.rs），
 * 返回 0 表示成功，失败时错误文字放在 lastError() 里。
 *
 * 文件名与格式和桌面/ iOS 版一致：录音写 <dir>/mic.wav，16 kHz 单声道 16 bit PCM。
 */
object TingoAudio {

    private const val SR = 16000
    private const val HEADER = 44

    @Volatile private var errText: String = ""

    private fun setErr(msg: String) { errText = msg }

    @JvmStatic fun lastError(): String = errText

    // Tauri 的 Rust 库已经加载好，这里只需把 JavaVM 交给 Rust（Rust 靠它回调本类）。
    // Kotlin object 的初始化是惰性的：Rust 第一次反射访问本类时触发。
    init {
        try {
            initNative()
        } catch (t: Throwable) {
            errText = "音频桥初始化失败：${t.message}"
        }
    }

    @JvmStatic fun takeError(): String {
        val s = errText
        errText = ""
        return s
    }

    // ---------- 拿 Context（Tauri 的 Activity 不对外暴露，用 ActivityThread 反射） ----------
    private val appContext: Context? by lazy {
        try {
            val cls = Class.forName("android.app.ActivityThread")
            val m = cls.getMethod("currentApplication")
            m.invoke(null) as? Context
        } catch (t: Throwable) {
            null
        }
    }

    private fun hasMicPermission(): Boolean {
        val ctx = appContext ?: return false
        return ctx.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    }

    // ---------- 由 Kotlin 在启动时调用，把 JavaVM 交给 Rust ----------
    external fun initNative()

    // ---------- 录音 ----------
    private var record: AudioRecord? = null
    private var recordThread: Thread? = null
    @Volatile private var recording = false
    @Volatile private var startAt = 0L
    @Volatile private var stopAt = 0L
    private var micFile: RandomAccessFile? = null
    @Volatile private var micBytes = 0L

    /** 0=已允许，1=被拒绝，2=还没问过 */
    @JvmStatic fun micStatus(): Int {
        val ctx = appContext ?: return 2
        return if (ctx.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED) 0 else 1
    }

    @JvmStatic fun setup(): Int {
        if (!hasMicPermission()) {
            setErr("需要麦克风权限：请在系统设置 → 应用 → 会听 → 权限里打开「麦克风」")
            return -1
        }
        return 0
    }

    @JvmStatic fun startRecording(dir: String): Int {
        if (recording) { setErr("已经在录音了"); return -1 }
        if (!hasMicPermission()) {
            setErr("需要麦克风权限：请在系统设置 → 应用 → 会听 → 权限里打开「麦克风」")
            return -1
        }
        return try {
            val d = File(dir)
            if (!d.exists()) d.mkdirs()
            val f = File(d, "mic.wav")
            if (f.exists()) f.delete()
            val raf = RandomAccessFile(f, "rw")
            raf.setLength(0)
            raf.write(ByteArray(HEADER))          // 先占位，停止时回填
            micBytes = 0

            val minBuf = AudioRecord.getMinBufferSize(
                SR, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(SR / 2)
            val rec = AudioRecord(
                MediaRecorder.AudioSource.MIC, SR,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, minBuf * 2
            )
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                rec.release(); raf.close()
                setErr("麦克风初始化失败（可能被其它 App 占用）")
                return -1
            }
            rec.startRecording()
            record = rec; micFile = raf
            recording = true
            startAt = System.currentTimeMillis(); stopAt = 0

            recordThread = Thread {
                val buf = ByteArray(minBuf)
                while (recording) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n > 0) {
                        try {
                            raf.seek(HEADER + micBytes)
                            raf.write(buf, 0, n)
                            micBytes += n
                        } catch (t: Throwable) {
                            setErr("写录音文件失败：${t.message}")
                            break
                        }
                    } else if (n < 0) {
                        setErr("录音中断（麦克风被占用或权限被收回）")
                        break
                    }
                }
            }.also { it.isDaemon = true; it.start() }
            0
        } catch (t: Throwable) {
            setErr("开始录音失败：${t.message}")
            -1
        }
    }

    @JvmStatic fun stopRecording(): Int {
        if (!recording) return 0
        recording = false
        try { recordThread?.join(2000) } catch (_: Throwable) {}
        try { record?.stop() } catch (_: Throwable) {}
        try { record?.release() } catch (_: Throwable) {}
        record = null; recordThread = null
        stopAt = System.currentTimeMillis()
        try {
            micFile?.let { raf ->
                raf.seek(0)
                raf.write(wavHeader(micBytes.toInt()))
                raf.close()
            }
        } catch (t: Throwable) {
            setErr("收尾录音文件失败：${t.message}")
        }
        micFile = null
        return 0
    }

    @JvmStatic fun elapsed(): Double {
        if (startAt == 0L) return 0.0
        val end = if (stopAt > 0) stopAt else System.currentTimeMillis()
        return (end - startAt) / 1000.0
    }

    private fun wavHeader(dataBytes: Int): ByteArray {
        val h = ByteBuffer.allocate(HEADER).order(ByteOrder.LITTLE_ENDIAN)
        h.put("RIFF".toByteArray())
        h.putInt(36 + dataBytes)
        h.put("WAVE".toByteArray())
        h.put("fmt ".toByteArray())
        h.putInt(16); h.putShort(1); h.putShort(1)
        h.putInt(SR); h.putInt(SR * 2); h.putShort(2); h.putShort(16)
        h.put("data".toByteArray())
        h.putInt(dataBytes)
        return h.array()
    }

    // ---------- 任意音视频 → 16k 单声道 wav ----------
    @JvmStatic fun decodeToWav(input: String, out: String): Int {
        var extractor: MediaExtractor? = null
        var decoder: MediaCodec? = null
        var raf: RandomAccessFile? = null
        return try {
            extractor = MediaExtractor()
            extractor.setDataSource(input)
            var track = -1
            var fmt: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) { track = i; fmt = f; break }
            }
            if (track < 0 || fmt == null) { setErr("这个文件里没有音轨"); return -1 }
            extractor.selectTrack(track)
            val mime = fmt.getString(MediaFormat.KEY_MIME)!!
            decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(fmt, null, null, 0)
            decoder.start()

            val srcRate = if (fmt.containsKey(MediaFormat.KEY_SAMPLE_RATE)) fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE) else SR
            val channels = if (fmt.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 1

            val f = File(out)
            f.parentFile?.mkdirs()
            if (f.exists()) f.delete()
            raf = RandomAccessFile(f, "rw")
            raf.setLength(0)
            raf.write(ByteArray(HEADER))
            var written = 0L

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var sameRate = srcRate == SR

            while (!outputDone) {
                if (!inputDone) {
                    val inIdx = decoder.dequeueInputBuffer(10_000L)
                    if (inIdx >= 0) {
                        val inBuf = decoder.getInputBuffer(inIdx)!!
                        val size = extractor.readSampleData(inBuf, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIdx = decoder.dequeueOutputBuffer(info, 10_000L)
                if (outIdx >= 0) {
                    val outBuf = decoder.getOutputBuffer(outIdx)!!
                    if (info.size > 0) {
                        val pcm = ByteArray(info.size)
                        outBuf.position(info.offset)
                        outBuf.get(pcm)
                        val mono16 = toMono16(pcm, channels)
                        val target = if (sameRate) mono16 else resample(mono16, srcRate, SR)
                        raf.seek(HEADER + written)
                        raf.write(target)
                        written += target.size
                    }
                    decoder.releaseOutputBuffer(outIdx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                } else if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val of = decoder.outputFormat
                    if (of.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                        sameRate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE) == SR
                    }
                }
            }
            raf.seek(0)
            raf.write(wavHeader(written.toInt()))
            if (written == 0L) { setErr("解码出来没有声音"); return -1 }
            0
        } catch (t: Throwable) {
            setErr("解码失败：${t.message}")
            -1
        } finally {
            try { raf?.close() } catch (_: Throwable) {}
            try { decoder?.stop(); decoder?.release() } catch (_: Throwable) {}
            try { extractor?.release() } catch (_: Throwable) {}
        }
    }

    /** 多声道混成单声道（取平均） */
    private fun toMono16(pcm: ByteArray, channels: Int): ByteArray {
        if (channels <= 1) return pcm
        val shorts = pcm.size / 2
        val frames = shorts / channels
        val out = ByteArray(frames * 2)
        val bb = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN)
        val ob = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until frames) {
            var sum = 0
            for (c in 0 until channels) sum += bb.getShort()
            ob.putShort((sum / channels).toShort())
        }
        return out
    }

    /** 线性插值重采样（16 bit PCM） */
    private fun resample(pcm: ByteArray, from: Int, to: Int): ByteArray {
        if (from == to || pcm.isEmpty()) return pcm
        val inN = pcm.size / 2
        val outN = (inN.toLong() * to / from).toInt()
        val src = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN)
        val out = ByteArray(outN * 2)
        val ob = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        val ratio = from.toDouble() / to
        for (i in 0 until outN) {
            val pos = i * ratio
            val i0 = pos.toInt().coerceIn(0, inN - 1)
            val i1 = (i0 + 1).coerceAtMost(inN - 1)
            val frac = pos - i0
            val s0 = src.getShort(i0 * 2)
            val s1 = src.getShort(i1 * 2)
            ob.putShort((s0 + (s1 - s0) * frac).toInt().toShort())
        }
        return out
    }

    // ---------- 16k wav → AAC m4a ----------
    @JvmStatic fun encodeAac(inputWav: String, outM4a: String): Int {
        var encoder: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var raf: RandomAccessFile? = null
        return try {
            val wav = File(inputWav)
            if (!wav.exists()) { setErr("找不到录音文件"); return -1 }
            raf = RandomAccessFile(wav, "r")
            val total = raf.length() - HEADER
            if (total <= 0) { setErr("录音文件是空的"); return -1 }

            val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SR, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 48_000)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
            }
            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            encoder.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()

            val target = File(outM4a)
            target.parentFile?.mkdirs()
            if (target.exists()) target.delete()
            muxer = MediaMuxer(target.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

            val info = MediaCodec.BufferInfo()
            raf.seek(HEADER.toLong())
            var muxStarted = false
            var trackIndex = -1
            var eos = false
            val chunk = ByteArray(4096)
            var pts = 0L

            while (!eos) {
                if (encoder != null) {
                    val inIdx = encoder.dequeueInputBuffer(10_000L)
                    if (inIdx >= 0) {
                        val inBuf = encoder.getInputBuffer(inIdx)!!
                        inBuf.clear()
                        val n = raf.read(chunk)
                        if (n <= 0) {
                            encoder.queueInputBuffer(inIdx, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        } else {
                            inBuf.put(chunk, 0, n)
                            encoder.queueInputBuffer(inIdx, 0, n, pts, 0)
                            pts += (n / 2) * 1_000_000L / SR
                        }
                    }
                    val outIdx = encoder.dequeueOutputBuffer(info, 10_000L)
                    if (outIdx >= 0) {
                        val outBuf = encoder.getOutputBuffer(outIdx)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                            info.size = 0
                        }
                        if (info.size > 0) {
                            if (!muxStarted) {
                                trackIndex = muxer.addTrack(encoder.outputFormat)
                                muxer.start()
                                muxStarted = true
                            }
                            outBuf.position(info.offset)
                            outBuf.limit(info.offset + info.size)
                            muxer.writeSampleData(trackIndex, outBuf, info)
                        }
                        encoder.releaseOutputBuffer(outIdx, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) eos = true
                    } else if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        if (!muxStarted) {
                            trackIndex = muxer.addTrack(encoder.outputFormat)
                            muxer.start()
                            muxStarted = true
                        }
                    }
                }
            }
            if (muxStarted) muxer.stop()
            0
        } catch (t: Throwable) {
            setErr("压缩录音失败：${t.message}")
            -1
        } finally {
            try { raf?.close() } catch (_: Throwable) {}
            try { encoder?.stop(); encoder?.release() } catch (_: Throwable) {}
            try { muxer?.release() } catch (_: Throwable) {}
        }
    }

    // ---------- 排好版的 HTML → A4 PDF ----------
    // 不用 PrintDocumentAdapter：它的 LayoutResultCallback / WriteResultCallback 构造函数是
    // package-private（android.print 包内才能 new），第三方 App 无法匿名继承。
    // 这里把 WebView 按 A4 宽度布局、撑到整页高度，再用 PdfDocument 逐页 translate + draw。
    @JvmStatic fun htmlToPdf(htmlPath: String, outPdf: String): Int {
        val ctx = appContext
        if (ctx == null) { setErr("拿不到 App 上下文，无法导出 PDF"); return -1 }
        val html = try {
            File(htmlPath).readText(Charsets.UTF_8)
        } catch (t: Throwable) {
            setErr("读取排版 HTML 失败：${t.message}")
            return -1
        }
        val latch = CountDownLatch(1)
        val result = intArrayOf(-1)
        Handler(Looper.getMainLooper()).post {
            try {
                val pageW = 595   // A4 @72dpi
                val pageH = 842
                val web = WebView(ctx)
                // 软件渲染层：未挂载到窗口的 WebView 必须关掉硬件加速，否则 PdfDocument.canvas 画出来是空白
                web.setLayerType(android.view.View.LAYER_TYPE_SOFTWARE, null)
                web.settings.javaScriptEnabled = false
                web.settings.allowFileAccess = true
                web.webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView?, url: String?) {
                        Handler(Looper.getMainLooper()).postDelayed({
                            try {
                                val w = view ?: throw IllegalStateException("WebView 为空")
                                val widthSpec = android.view.View.MeasureSpec.makeMeasureSpec(pageW, android.view.View.MeasureSpec.EXACTLY)
                                val heightSpec = android.view.View.MeasureSpec.makeMeasureSpec(0, android.view.View.MeasureSpec.UNSPECIFIED)
                                w.measure(widthSpec, heightSpec)
                                val contentH = w.measuredHeight.coerceAtLeast(pageH)
                                w.layout(0, 0, pageW, contentH)

                                val doc = android.graphics.pdf.PdfDocument()
                                var top = 0
                                var pageNo = 1
                                while (top < contentH) {
                                    val info = android.graphics.pdf.PdfDocument.PageInfo
                                        .Builder(pageW, pageH, pageNo).create()
                                    val page = doc.startPage(info)
                                    val canvas = page.canvas
                                    canvas.save()
                                    canvas.translate(0f, -top.toFloat())
                                    w.draw(canvas)
                                    canvas.restore()
                                    doc.finishPage(page)
                                    top += pageH
                                    pageNo++
                                    if (pageNo > 200) break
                                }
                                val out = File(outPdf)
                                out.parentFile?.mkdirs()
                                out.outputStream().use { doc.writeTo(it) }
                                doc.close()
                                if (out.length() == 0L) {
                                    setErr("导出 PDF 失败：文件为空")
                                } else {
                                    result[0] = 0
                                }
                            } catch (t: Throwable) {
                                setErr("导出 PDF 失败：${t.message}")
                            } finally {
                                latch.countDown()
                            }
                        }, 150L)
                    }
                }
                web.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
            } catch (t: Throwable) {
                setErr("导出 PDF 失败：${t.message}")
                latch.countDown()
            }
        }
        if (!latch.await(90, TimeUnit.SECONDS)) { setErr("导出 PDF 超时"); return -1 }
        return result[0]
    }

    // ---------- 后台 CPU 保活（PARTIAL_WAKE_LOCK） ----------
    private var wakeLock: android.os.PowerManager.WakeLock? = null
    private var keepAliveCount = 0

    @JvmStatic @Synchronized fun setKeepAlive(active: Int): Int {
        if (active != 0) {
            keepAliveCount++
            if (keepAliveCount == 1) {
                try {
                    val ctx = appContext ?: return 0
                    val pm = ctx.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager ?: return 0
                    val wl = pm.newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "HuiT:BackgroundJob")
                    wl.acquire(60 * 60 * 1000L) // 最长 1 小时保护
                    wakeLock = wl
                } catch (_: Throwable) {}
            }
        } else {
            keepAliveCount = (keepAliveCount - 1).coerceAtLeast(0)
            if (keepAliveCount == 0) {
                try {
                    wakeLock?.let { if (it.isHeld) it.release() }
                } catch (_: Throwable) {}
                wakeLock = null
            }
        }
        return 0
    }
}
