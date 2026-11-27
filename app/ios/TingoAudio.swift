// TingoAudio.swift —— iOS 版把 macOS 的 tingo-recorder 子进程换成进程内实现。
//
// macOS 版把录音、解码、A4 排版交给一个打包在 App 里的 Swift 命令行程序（ScreenCaptureKit +
// AVFoundation + afconvert）。iOS 不允许 fork/exec 第三方可执行文件，所以这里用同一批系统框架
// 在 App 进程内完成同样的事，并通过 @_cdecl 暴露给 Rust（tingo-engine）直接调用。
//
// 对外契约（Rust 侧见 app/engine/src/ios.rs）：
//   返回 Int32，0 = 成功；非 0 时错误文字放在 tingo_ios_last_error() 里，取走后由调用方 free。
//   文件名与目录布局必须和 macOS 版一致：录音写 <dir>/mic.wav，16 kHz 单声道 16 bit PCM。
//
// 与 macOS 版的差别只有一个，且是系统限制：拿不到别的 App 的声音（没有 ScreenCaptureKit 的
// 系统音轨），所以只录麦克风；`system` 参数在 Rust 侧已被忽略。

import AVFoundation
import CoreMedia
import UIKit

// MARK: - 错误传递（Rust 每 5 秒轮询一次，取走即清空）

private let errorLock = NSLock()
private var errorBox: String = ""

private func setError(_ msg: String) {
    errorLock.lock()
    errorBox = msg
    errorLock.unlock()
}

@discardableResult
private func takeError() -> String {
    errorLock.lock()
    defer { errorLock.unlock() }
    let s = errorBox
    errorBox = ""
    return s
}

@_cdecl("tingo_ios_last_error")
public func tingo_ios_last_error() -> UnsafeMutablePointer<CChar>? {
    let s = takeError()
    return s.isEmpty ? nil : strdup(s)
}

@_cdecl("tingo_ios_free")
public func tingo_ios_free(_ p: UnsafeMutablePointer<CChar>?) {
    if let p { free(p) }
}

private func cString(_ p: UnsafePointer<CChar>?) -> String? {
    guard let p else { return nil }
    let s = String(cString: p)
    return s.isEmpty ? nil : s
}

// MARK: - 音频会话

/// .playAndRecord + 外放 + 与其它 App 混音：开会时 Tingo 录音不能把腾讯会议的声音掐掉。
/// 后台继续录音靠 Info.plist 的 UIBackgroundModes=audio（构建脚本会注入）。
/// 把音频会话的操作放到主线程：首次激活音频硬件时系统会把实际工作派回主队列，
/// 在 Rust 的后台线程里直接调容易超时或拿不到有效的输入格式。
private func onMain(_ work: () throws -> Void) rethrows {
    if Thread.isMainThread {
        try work()
    } else {
        try DispatchQueue.main.sync(execute: work)
    }
}

private func configureSession() throws {
    let session = AVAudioSession.sharedInstance()
    try onMain {
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }
}

@_cdecl("tingo_ios_setup_session")
public func tingo_ios_setup_session() -> Int32 {
    do {
        try configureSession()
        return 0
    } catch {
        setError("音频会话初始化失败：\(error.localizedDescription)")
        return -1
    }
}

/// 麦克风权限（iOS 17 起用 AVAudioApplication，之前用 AVAudioSession.recordPermission）。
/// 同步等待用户点完授权框，最多 20 秒。
/// 麦克风授权状态：0=已允许，1=被拒绝，2=还没问过
@_cdecl("tingo_ios_mic_status")
public func tingo_ios_mic_status() -> Int32 {
    if #available(iOS 17.0, *) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return 0
        case .denied: return 1
        default: return 2
        }
    } else {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return 0
        case .denied: return 1
        default: return 2
        }
    }
}

@_cdecl("tingo_ios_request_mic")
public func tingo_ios_request_mic() -> Int32 {
    final class Box: @unchecked Sendable { var value = false }
    let sem = DispatchSemaphore(value: 0)
    let box = Box()
    let finish: (Bool) -> Void = { ok in
        box.value = ok
        sem.signal()
    }
    if #available(iOS 17.0, *) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return 0
        case .denied:
            setError("麦克风权限被拒绝，请到「设置 → Tingo」里打开")
            return -1
        default:
            AVAudioApplication.requestRecordPermission { ok in finish(ok) }
        }
    } else {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return 0
        case .denied:
            setError("麦克风权限被拒绝，请到「设置 → Tingo」里打开")
            return -1
        default:
            AVAudioSession.sharedInstance().requestRecordPermission { ok in finish(ok) }
        }
    }
    if sem.wait(timeout: .now() + 20) == .timedOut {
        setError("等待麦克风授权超时")
        return -1
    }
    return box.value ? 0 : -1
}

// MARK: - WAV 写入（16 kHz 单声道 16 bit，和 macOS 版 write_wav16 完全一致）

private let kSampleRate = 16_000
private let kHeaderBytes = 44

private func wavHeader(sampleBytes: UInt32) -> Data {
    var v = Data(capacity: kHeaderBytes)
    func u32(_ x: UInt32) { var b = x.littleEndian; withUnsafeBytes(of: &b) { v.append(contentsOf: $0) } }
    func u16(_ x: UInt16) { var b = x.littleEndian; withUnsafeBytes(of: &b) { v.append(contentsOf: $0) } }
    v.append(contentsOf: Array("RIFF".utf8))
    u32(36 &+ sampleBytes)
    v.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16)
    u16(1)                              // PCM
    u16(1)                              // 单声道
    u32(UInt32(kSampleRate))
    u32(UInt32(kSampleRate) * 2)        // byte rate
    u16(2)                              // block align
    u16(16)                             // bits per sample
    v.append(contentsOf: Array("data".utf8))
    u32(sampleBytes)
    return v
}

final class WavWriter {
    private let handle: FileHandle
    private var written: UInt32 = 0

    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else {
            throw NSError(domain: "Tingo", code: 1, userInfo: [NSLocalizedDescriptionKey: "写不了录音文件：\(path)"])
        }
        handle = h
        try handle.write(contentsOf: wavHeader(sampleBytes: 0))
        try handle.synchronize()
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            setError("写录音文件失败：\(error.localizedDescription)")
            return
        }
        written &+= UInt32(data.count)
    }

    /// 回填文件头里的大小字段，然后关闭。
    func close() {
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: wavHeader(sampleBytes: written))
            try handle.synchronize()
            try handle.close()
        } catch {
            setError("收尾录音文件失败：\(error.localizedDescription)")
        }
    }

    var byteCount: UInt32 { written }
}

// MARK: - 录音器

final class MicRecorder {
    static let shared = MicRecorder()

    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "tingo.mic.writer", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var writer: WavWriter?
    private var drainTimer: DispatchSourceTimer?
    private var startedAt: Date?
    private var stoppedAt: Date?
    private var running = false
    private var observer: NSObjectProtocol?

    private init() {}

    /// 录音期间在实时线程拿不到锁写入，先攒在内存里，由定时器每 0.5 秒冲一次盘。
    private var pending = Data()
    private let pendingLock = NSLock()

    func start(dir: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if running { throw NSError(domain: "Tingo", code: 2, userInfo: [NSLocalizedDescriptionKey: "已经在录音了"]) }

        try configureSession()
        let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let micPath = dirURL.appendingPathComponent("mic.wav").path
        // 上一次的残留先清掉，避免读到旧音轨
        try? FileManager.default.removeItem(atPath: micPath)

        let w = try WavWriter(path: micPath)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Tingo", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风输入"])
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(kSampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw NSError(domain: "Tingo", code: 4, userInfo: [NSLocalizedDescriptionKey: "音频格式转换器创建失败"])
        }

        pendingLock.lock()
        pending = Data()
        pendingLock.unlock()
        writer = w

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // 实时音频线程：只做转换和入队，绝不同步写盘
            let ratio = target.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var convError: NSError?
            let status = converter.convert(to: out, error: &convError) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            let bytes = Int(out.frameLength) * MemoryLayout<Int16>.size
            let data = Data(bytes: ch[0], count: bytes)
            self.pendingLock.lock()
            self.pending.append(data)
            self.pendingLock.unlock()
        }

        do {
            try onMain {
                engine.prepare()
                try engine.start()
            }
        } catch {
            input.removeTap(onBus: 0)
            w.close()
            throw NSError(domain: "Tingo", code: 5, userInfo: [NSLocalizedDescriptionKey: "启动麦克风失败：\(error.localizedDescription)"])
        }

        // 每 0.5 秒把攒的 PCM 写进文件
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()

        // 来电、其它 App 抢占音频会话时 AVAudioEngine 会被系统停掉，记下原因让 Rust 侧报出来
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                setError("录音被系统中断（来电或其它 App 占用了麦克风）")
            } else if type == .ended, let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                MicRecorder.shared.resumeAfterInterruption()
            }
        }

        self.engine = engine
        drainTimer = timer
        startedAt = Date()
        stoppedAt = nil
        running = true
    }

    private func onMainOrIgnore(_ work: () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    /// 中断结束、系统允许恢复时重新起引擎（文件保持同一个，继续往后写）。
    fileprivate func resumeAfterInterruption() {
        lock.lock()
        let e = engine
        lock.unlock()
        guard let e, !e.isRunning else { return }
        do {
            try configureSession()
            try e.start()
        } catch {
            setError("中断后恢复录音失败：\(error.localizedDescription)")
        }
    }

    private func flush() {
        pendingLock.lock()
        let data = pending
        pending = Data()
        pendingLock.unlock()
        guard !data.isEmpty, let w = writer else { return }
        w.append(data)
    }

    func stop() {
        lock.lock()
        if !running {
            lock.unlock()
            return
        }
        running = false
        let e = engine
        let timer = drainTimer
        let obs = observer
        let w = writer
        engine = nil
        drainTimer = nil
        observer = nil
        writer = nil
        stoppedAt = Date()
        lock.unlock()

        if let obs { NotificationCenter.default.removeObserver(obs) }
        timer?.cancel()
        if let e {
            onMainOrIgnore {
                e.inputNode.removeTap(onBus: 0)
                e.stop()
            }
        }

        // 收尾：把内存里剩下的冲出去，再回填 wav 头
        pendingLock.lock()
        let rest = pending
        pending = Data()
        pendingLock.unlock()
        if !rest.isEmpty { w?.append(rest) }
        w?.close()

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func elapsed() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let start = startedAt else { return 0 }
        return (stoppedAt ?? Date()).timeIntervalSince(start)
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// 结束录音时把最后一笔错误也交给 Rust 侧（比如写盘失败发生在 stop 之前）。
    func drainError() -> String { takeError() }
}

@_cdecl("tingo_ios_rec_start")
public func tingo_ios_rec_start(_ dir: UnsafePointer<CChar>?) -> Int32 {
    guard let dir = cString(dir) else {
        setError("录音目录为空")
        return -1
    }
    if tingo_ios_request_mic() != 0 { return -1 }
    do {
        try MicRecorder.shared.start(dir: dir)
        return 0
    } catch {
        setError(error.localizedDescription)
        return -1
    }
}

@_cdecl("tingo_ios_rec_stop")
public func tingo_ios_rec_stop() -> Int32 {
    MicRecorder.shared.stop()
    return 0
}

@_cdecl("tingo_ios_rec_elapsed")
public func tingo_ios_rec_elapsed() -> Double {
    MicRecorder.shared.elapsed()
}

// MARK: - 任意音视频 → 16 kHz 单声道 wav（AVAssetReader，覆盖 m4a/mp3/mp4/mov/wav）

@_cdecl("tingo_ios_decode")
public func tingo_ios_decode(_ input: UnsafePointer<CChar>?, _ outWav: UnsafePointer<CChar>?) -> Int32 {
    guard let input = cString(input), let outWav = cString(outWav) else {
        setError("解码参数为空")
        return -1
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: input))
    guard let track = asset.tracks(withMediaType: .audio).first else {
        setError("这个文件里没有音轨：\((input as NSString).lastPathComponent)")
        return -1
    }
    do {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: kSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            setError("这个文件的音频解码不了")
            return -1
        }
        reader.add(output)
        let writer = try WavWriter(path: outWav)
        reader.startReading()
        while let sample = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sample) {
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                   let pointer, length > 0 {
                    writer.append(Data(bytes: pointer, count: length))
                }
            }
            CMSampleBufferInvalidate(sample)
        }
        if reader.status == .failed {
            writer.close()
            try? FileManager.default.removeItem(atPath: outWav)
            setError("解码失败：\(reader.error?.localizedDescription ?? "未知原因")")
            return -1
        }
        writer.close()
        if writer.byteCount == 0 {
            try? FileManager.default.removeItem(atPath: outWav)
            setError("解码出来没有声音")
            return -1
        }
        return 0
    } catch {
        setError("解码失败：\(error.localizedDescription)")
        return -1
    }
}

// MARK: - 16 kHz wav → AAC m4a（替代 macOS 的 afconvert，48 kbps）

@_cdecl("tingo_ios_encode_aac")
public func tingo_ios_encode_aac(_ inputWav: UnsafePointer<CChar>?, _ outM4a: UnsafePointer<CChar>?) -> Int32 {
    guard let inputWav = cString(inputWav), let outM4a = cString(outM4a) else {
        setError("压缩参数为空")
        return -1
    }
    try? FileManager.default.removeItem(atPath: outM4a)
    let asset = AVURLAsset(url: URL(fileURLWithPath: inputWav))
    guard let track = asset.tracks(withMediaType: .audio).first else {
        setError("录音文件里没有音轨")
        return -1
    }
    do {
        let reader = try AVAssetReader(asset: asset)
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: kSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: outM4a), fileType: .m4a)
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: kSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            setError("这个设备不支持 AAC 编码")
            return -1
        }
        writer.add(input)
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        group.enter()
        let queue = DispatchQueue(label: "tingo.aac")
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    writer.finishWriting {
                        group.leave()
                    }
                    return
                }
                if !input.append(sample) {
                    input.markAsFinished()
                    reader.cancelReading()
                    writer.cancelWriting()
                    group.leave()
                    return
                }
            }
        }
        _ = group.wait(timeout: .now() + 300)

        if writer.status != .completed {
            setError("压缩录音失败：\(writer.error?.localizedDescription ?? "未知原因")")
            try? FileManager.default.removeItem(atPath: outM4a)
            return -1
        }
        return 0
    } catch {
        setError("压缩录音失败：\(error.localizedDescription)")
        return -1
    }
}

// MARK: - 排好版的 HTML → A4 PDF（替代 macOS 版 recorder 的 WKWebView 打印）

private final class TingPDFRenderer: UIPrintPageRenderer {
    private let paper: CGRect
    private let printable: CGRect

    init(paper: CGRect, margin: CGFloat) {
        self.paper = paper
        self.printable = paper.insetBy(dx: margin, dy: margin)
        super.init()
    }

    override var paperRect: CGRect { paper }
    override var printableRect: CGRect { printable }
}

@_cdecl("tingo_ios_html_to_pdf")
public func tingo_ios_html_to_pdf(_ htmlPath: UnsafePointer<CChar>?, _ outPdf: UnsafePointer<CChar>?) -> Int32 {
    guard let htmlPath = cString(htmlPath), let outPdf = cString(outPdf) else {
        setError("排版参数为空")
        return -1
    }
    var result: Int32 = 0
    let render = {
        guard let html = try? String(contentsOfFile: htmlPath, encoding: .utf8) else {
            setError("读不了要排版的 HTML")
            result = -1
            return
        }
        try? FileManager.default.removeItem(atPath: outPdf)
        // A4 @ 72 dpi
        let paper = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let renderer = TingPDFRenderer(paper: paper, margin: 36)
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        formatter.perPageContentInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)

        UIGraphicsBeginPDFContextToFile(outPdf, paper, nil)
        defer { UIGraphicsEndPDFContext() }
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        let pages = max(1, renderer.numberOfPages)
        for i in 0..<pages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: paper)
        }
        if !FileManager.default.fileExists(atPath: outPdf) {
            setError("导出 PDF 失败")
            result = -1
        }
    }
    if Thread.isMainThread {
        render()
    } else {
        DispatchQueue.main.sync(execute: render)
    }
    return result
}

// MARK: - 后台任务保活与屏幕防休眠（转写 / 生成纪要 / 下载模型期间防息屏与后台挂起）

/// 生成一段静音 WAV（16 kHz 单声道 16 bit，1 秒），供后台保活播放器循环播放。
private func silentWavData() -> Data {
    let samples = kSampleRate // 1 秒静音
    let bytes = UInt32(samples * 2)
    var d = wavHeader(sampleBytes: bytes)
    d.append(Data(count: Int(bytes)))
    return d
}

final class KeepAliveManager {
    static let shared = KeepAliveManager()

    private let lock = NSLock()
    private var activeCount = 0
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var silentPlayer: AVAudioPlayer?

    private init() {}

    func acquire() {
        lock.lock()
        activeCount += 1
        let first = (activeCount == 1)
        lock.unlock()
        guard first else { return }

        DispatchQueue.main.async {
            // 1. 前台防自动息屏
            UIApplication.shared.isIdleTimerDisabled = true
            // 2. 申请系统后台任务配额
            self.beginBgTask()
            // 3. 若当前未在录音，启用静音保活音频会话（配合 UIBackgroundModes=audio，锁屏或切后台也不被挂起）
            self.startSilentAudioIfNeeded()
        }
    }

    func release() {
        lock.lock()
        activeCount = max(0, activeCount - 1)
        let last = (activeCount == 0)
        lock.unlock()
        guard last else { return }

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            self.stopSilentAudio()
            self.endBgTask()
        }
    }

    private func beginBgTask() {
        if bgTask != .invalid { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "TingoBackgroundProcessing") { [weak self] in
            self?.endBgTask()
        }
    }

    private func endBgTask() {
        guard bgTask != .invalid else { return }
        let id = bgTask
        bgTask = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    private func startSilentAudioIfNeeded() {
        // 如果正在录音，MicRecorder 已经激活了 AVAudioSession，无需静音播放器
        if MicRecorder.shared.isRunning { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // 纯后台处理用 .playback + .mixWithOthers，避免系统在无录音时回收 .playAndRecord 会话
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: silentWavData(), fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            player.play()
            silentPlayer = player
        } catch {
            // 静音保活失败不阻塞主流程
        }
    }

    private func stopSilentAudio() {
        silentPlayer?.stop()
        silentPlayer = nil
    }
}

@_cdecl("tingo_ios_keep_alive")
public func tingo_ios_keep_alive(_ active: Int32) -> Int32 {
    if active != 0 {
        KeepAliveManager.shared.acquire()
    } else {
        KeepAliveManager.shared.release()
    }
    return 0
}
