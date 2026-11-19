import AppKit
import AVFoundation
import ScreenCaptureKit

/// Hands audio to a recognizer on one serial queue, never on the realtime audio thread.
final class ListeningAudioSink: @unchecked Sendable {
    let queue: DispatchQueue
    private let feed: SpeechFeed
    private let capacity = DispatchSemaphore(value: 32)
    private let overflowLock = NSLock()
    private var overflowReported = false
    nonisolated private let onFailure: @Sendable (String) -> Void
    private var acceptsAudio = true

    init(feed: SpeechFeed, queue: DispatchQueue, onFailure: @escaping @Sendable (String) -> Void) {
        self.feed = feed
        self.queue = queue
        self.onFailure = onFailure
    }

    static func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "com.yichenlin.Wisp.listening", qos: .userInitiated)
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard capacity.wait(timeout: .now()) == .success else {
            overflowLock.lock()
            let shouldReport = !overflowReported
            overflowReported = true
            overflowLock.unlock()
            guard shouldReport else { return }
            queue.async { [weak self] in
                guard let self, self.acceptsAudio else { return }
                self.acceptsAudio = false
                self.onFailure(String(localized: "音频处理跟不上输入，字幕已停止。请关闭其他高负载应用后重试。"))
            }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.capacity.signal() }
            guard self.acceptsAudio else { return }
            self.feed.append(buffer)
        }
    }

    func finish() {
        queue.sync {
            acceptsAudio = false
            feed.endAudio()
        }
    }

    func cancel() {
        queue.sync {
            acceptsAudio = false
            feed.cancel()
        }
    }

    var isDrained: Bool { queue.sync { feed.isDrained } }

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

/// Captures one source: everything the Mac plays, through ScreenCaptureKit, or the microphone.
@MainActor
final class ListeningCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let sink: ListeningAudioSink
    nonisolated private let onFailure: @Sendable (String) -> Void
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var engineObserver: NSObjectProtocol?
    private var accepting = true

    init(sink: ListeningAudioSink, onFailure: @escaping @Sendable (String) -> Void) {
        self.sink = sink
        self.onFailure = onFailure
        super.init()
    }

    /// Everything this Mac plays, from every app, except Wisp's own sound.
    func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard let display = content.displays.first else {
            throw ListeningFailure(message: String(localized: "没有找到可以采集声音的显示器。"))
        }
        // A display filter that excludes no application carries the audio of all of them; which
        // display it names does not matter for sound.
        // https://developer.apple.com/videos/play/wwdc2022/10156/
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
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

    func startMicrophone() throws {
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
                failure(String(localized: "无法复制麦克风音频，已停止。"))
                return
            }
            sink.enqueue(copy)
        }
        self.engine = engine
        engine.prepare()
        try engine.start()
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.accepting else { return }
                self.onFailure(String(localized: "音频输入设备已变化，已停止。请确认麦克风后重试。"))
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
            onFailure(String(localized: "无法读取应用音频，字幕已停止。"))
            return
        }
        sink.enqueue(buffer)
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

    /// Stops capture and waits for the trailing words, with a deadline so Stop cannot hang.
    func stop(deadline seconds: TimeInterval = 10) async -> String? {
        stopMicrophone()
        var issue: String?
        if let stream {
            do { try await stream.stopCapture() }
            catch { issue = error.localizedDescription }
        }
        stream = nil
        sink.finish()
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !sink.isDrained && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { break }
        }
        if !sink.isDrained, issue == nil {
            issue = String(localized: "末尾的话没能识别完。")
        }
        sink.cancel()
        return issue
    }

    func terminate() {
        stopMicrophone()
        sink.cancel()
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
    }
}

/// Builds the recognizer a session's engine names, and the capture that feeds it.
@MainActor
enum ListeningSession {
    static func make(engine: ListeningEngine, locale: String,
                     onUpdate: @escaping @Sendable (CaptionUpdate) -> Void,
                     onFailure: @escaping @Sendable (String) -> Void) async throws -> ListeningCapture {
        let feed: SpeechFeed
        switch engine {
        case .appleSpeech:
            feed = try await StreamingSpeech.start(locale: locale, onUpdate: onUpdate, onFailure: onFailure)
        case .soniox:
            feed = try await SonioxSpeech.start(apiKey: KeychainStore.loadSpeechKey(), locale: locale,
                                                onUpdate: onUpdate, onFailure: onFailure)
        }
        let sink = ListeningAudioSink(feed: feed, queue: ListeningAudioSink.makeQueue(), onFailure: onFailure)
        return ListeningCapture(sink: sink, onFailure: onFailure)
    }
}
