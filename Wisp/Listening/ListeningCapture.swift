import AppKit
import AVFoundation
import ScreenCaptureKit

/// Owns recognition and file IO on one queue, never on the realtime microphone thread.
final class ListeningAudioSink: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.yichenlin.Wisp.listening", qos: .userInitiated)
    private let capacity = DispatchSemaphore(value: 32)
    private let overflowLock = NSLock()
    private var overflowReported = false
    private var tracks: [ListeningSource: ListeningSpeechTrack] = [:]
    private let scheduler: ListeningSpeechScheduler
    nonisolated private let onFailure: @Sendable (String) -> Void
    private let origin = ProcessInfo.processInfo.systemUptime
    private var acceptsAudio = true

    init(mode: ListeningMode, locale: String, recognition: LocalSpeechRecognition? = nil, directory: URL?,
         onSegment: @escaping (ListeningSegment) -> Void, onFailure: @escaping @Sendable (String) -> Void) throws {
        self.onFailure = onFailure
        if let recognition {
            scheduler = ListeningSpeechScheduler(queue: queue, recognize: recognition.recognize,
                                                 onSegment: onSegment, onFailure: onFailure)
        } else {
            scheduler = try ListeningSpeechScheduler(locale: locale, queue: queue, onSegment: onSegment, onFailure: onFailure)
        }
        for source in mode.sources {
            tracks[source] = ListeningSpeechTrack(source: source, scheduler: scheduler,
                                                  directory: directory, onFailure: onFailure)
        }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer, source: ListeningSource) {
        guard capacity.wait(timeout: .now()) == .success else {
            overflowLock.lock()
            let shouldReport = !overflowReported
            overflowReported = true
            overflowLock.unlock()
            guard shouldReport else { return }
            queue.async { [weak self] in
                guard let self, self.acceptsAudio else { return }
                self.acceptsAudio = false
                self.onFailure(String(localized: "音频处理跟不上输入，已停止以避免丢失内容。请关闭其他高负载应用后重试。"))
            }
            return
        }
        let offset = max(0, ProcessInfo.processInfo.systemUptime - origin - Double(buffer.frameLength) / buffer.format.sampleRate)
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.capacity.signal() }
            guard self.acceptsAudio else { return }
            self.tracks[source]?.append(buffer, offset: offset)
        }
    }

    func finish() {
        queue.sync {
            acceptsAudio = false
            tracks.values.forEach { $0.finish() }
        }
    }

    func cancel() {
        queue.sync {
            acceptsAudio = false
            tracks.values.forEach { $0.cancel() }
            scheduler.cancel()
            tracks.removeAll()
        }
    }

    var isDrained: Bool { queue.sync { scheduler.isDrained } }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices {
            guard let src = source[index].mData, let dst = destination[index].mData else { return nil }
            memcpy(dst, src, Int(source[index].mDataByteSize))
        }
        return copy
    }
}

@MainActor
final class ListeningCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let sink: ListeningAudioSink
    nonisolated private let onFailure: @Sendable (String) -> Void
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var engineObserver: NSObjectProtocol?
    private var accepting = true

    init(mode: ListeningMode, locale: String, recognition: LocalSpeechRecognition? = nil, directory: URL?,
         onSegment: @escaping (ListeningSegment) -> Void, onFailure: @escaping @Sendable (String) -> Void) throws {
        self.onFailure = onFailure
        sink = try ListeningAudioSink(mode: mode, locale: locale, recognition: recognition, directory: directory,
                                      onSegment: onSegment, onFailure: onFailure)
        super.init()
    }

    func start(mode: ListeningMode, application: SCRunningApplication?) async throws {
        if mode.sources.contains(.application) {
            guard let application else { throw ListeningFailure(message: String(localized: "请选择要转写的应用。")) }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            guard let display = content.displays.first,
                  content.applications.contains(where: { $0.processID == application.processID }) else {
                throw ListeningFailure(message: String(localized: "所选应用已退出或无法采集，请刷新应用列表。"))
            }
            // Audio filtering is application-level, not browser-tab/window-level.
            // https://developer.apple.com/videos/play/wwdc2022/10156/
            let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 1
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sink.queue)
            self.stream = stream
            do {
                try await stream.startCapture()
                try Task.checkCancellation()
                guard accepting else { throw CancellationError() }
            } catch {
                try? await stream.stopCapture()
                self.stream = nil
                throw error
            }
        }
        if mode.sources.contains(.microphone) {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw ListeningFailure(message: String(localized: "没有可用的麦克风，请检查系统声音输入设置。"))
            }
            let sink = self.sink
            let failure = self.onFailure
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                guard let copy = ListeningAudioSink.copy(buffer) else {
                    failure(String(localized: "无法复制麦克风音频，录音已停止。"))
                    return
                }
                sink.enqueue(copy, source: .microphone)
            }
            self.engine = engine
            engine.prepare()
            try engine.start()
            engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.accepting else { return }
                    self.onFailure(String(localized: "音频输入设备已变化，录音已停止。请确认麦克风后重新开始。"))
                }
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
                                                                  frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else {
            onFailure(String(localized: "无法读取应用音频，录音已停止。"))
            return
        }
        sink.enqueue(buffer, source: .application)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure(error.localizedDescription)
    }

    private func stopMicrophone() {
        accepting = false
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
    }

    func stop() async -> String? {
        stopMicrophone()
        var issue: String?
        if let stream {
            do { try await stream.stopCapture() }
            catch { issue = error.localizedDescription }
        }
        stream = nil
        sink.finish()
        // Drain the bounded queue, with a deadline so Stop cannot hang indefinitely.
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !sink.isDrained && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { break }
        }
        if !sink.isDrained, issue == nil {
            issue = String(localized: "末尾音频未能全部完成转写；已保留现有文字，临时文字可能不完整。")
        }
        sink.cancel()
        return issue
    }

    func terminate() {
        stopMicrophone()
        sink.cancel()
        // Also used by data reset while the process stays alive.
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
    }
}
