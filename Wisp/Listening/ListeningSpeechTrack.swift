import AVFoundation
import Speech

/// One device recognizer processes short batches from both sources in FIFO order.
/// We do not depend on support for concurrent on-device recognition requests.
/// https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition
final class ListeningSpeechScheduler {
    struct Batch {
        let id = UUID()
        let source: ListeningSource
        let offset: TimeInterval
        let duration: TimeInterval
        let buffers: [AVAudioPCMBuffer]
    }

    struct Update {
        var text: String?
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var isFinal = false
        var error: Error?
    }
    typealias Recognize = (Batch, @escaping (Update) -> Void) -> (() -> Void)
    private let recognize: Recognize
    private let queue: DispatchQueue
    private let onSegment: (ListeningSegment) -> Void
    private let onFailure: (String) -> Void
    private var pending: [Batch] = []
    private var current: Batch?
    private var cancelTask: (() -> Void)?
    private var cancelled = false

    convenience init(locale: String, queue: DispatchQueue, onSegment: @escaping (ListeningSegment) -> Void,
         onFailure: @escaping (String) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw ListeningFailure(message: String(localized: "此电脑暂不支持所选语言的设备端转写。请在系统设置中启用该语言的听写并下载语言资源，或换一种语言。音频不会自动上传。"))
        }
        self.init(queue: queue, recognize: { batch, receive in
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            let task = recognizer.recognitionTask(with: request) { result, error in
                let words = result?.bestTranscription.segments
                receive(Update(text: result?.bestTranscription.formattedString,
                    start: words?.first?.timestamp ?? 0,
                    end: words?.last.map { $0.timestamp + $0.duration } ?? batch.duration,
                    isFinal: result?.isFinal == true, error: error))
            }
            batch.buffers.forEach { request.append($0) }
            request.endAudio()
            return { task.cancel() }
        }, onSegment: onSegment, onFailure: onFailure)
    }

    /// Injectable recognition boundary keeps scheduling/cancellation tests independent of TCC.
    init(queue: DispatchQueue, recognize: @escaping Recognize,
         onSegment: @escaping (ListeningSegment) -> Void, onFailure: @escaping (String) -> Void) {
        self.queue = queue
        self.recognize = recognize
        self.onSegment = onSegment
        self.onFailure = onFailure
    }

    func enqueue(_ batch: Batch) {
        guard !cancelled, !batch.buffers.isEmpty else { return }
        guard pending.count < 8 else {
            onFailure(String(localized: "转写积压过多，已停止录音。请关闭其他高负载应用后重试。"))
            cancel()
            return
        }
        pending.append(batch)
        startNext()
    }

    private func startNext() {
        guard !cancelled, current == nil, !pending.isEmpty else { return }
        let batch = pending.removeFirst()
        let id = batch.id
        current = batch
        cancelTask = recognize(batch) { [weak self] update in
            guard let self else { return }
            self.queue.async { [weak self] in self?.receive(update, id: id) }
        }
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.current?.id == id else { return }
            self.onFailure(String(localized: "设备端识别响应超时，录音已停止；末尾文字可能不完整。"))
            self.cancel()
        }
    }

    private func receive(_ update: Update, id: UUID) {
        guard !cancelled, let batch = current, batch.id == id else { return }
        if let text = update.text {
            onSegment(ListeningSegment(id: id, source: batch.source,
                start: batch.offset + update.start,
                end: batch.offset + update.end,
                text: text, isFinal: update.isFinal))
        }
        guard update.isFinal || update.error != nil else { return }
        if let error = update.error, !update.isFinal {
            let nsError = error as NSError
            // Silence is normal. Other failures must not silently lose an audio batch.
            if !(nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110) {
                onFailure("\(batch.source.title): \(error.localizedDescription)")
                cancel()
                return
            }
        }
        current = nil
        cancelTask = nil
        startNext()
    }

    var isDrained: Bool { current == nil && pending.isEmpty }

    func cancel() {
        cancelled = true
        cancelTask?()
        cancelTask = nil
        current = nil
        pending.removeAll()
    }
}

/// Groups audio without omitting quiet speech. A short pause is preferred as a
/// boundary; continuous speech is flushed after four seconds. File IO shares the queue.
final class ListeningSpeechTrack {
    private let source: ListeningSource
    private let scheduler: ListeningSpeechScheduler
    private let onFailure: (String) -> Void
    private let directory: URL?
    private var buffers: [AVAudioPCMBuffer] = []
    private var duration: TimeInterval = 0
    private var quietDuration: TimeInterval = 0
    private var offset: TimeInterval = 0
    private var file: AVAudioFile?
    private var filePart = 0
    private var writtenBytes: Int64 = 0
    private var stopped = false

    init(source: ListeningSource, scheduler: ListeningSpeechScheduler, directory: URL?,
         onFailure: @escaping (String) -> Void) {
        self.source = source
        self.scheduler = scheduler
        self.directory = directory
        self.onFailure = onFailure
    }

    func append(_ buffer: AVAudioPCMBuffer, offset: TimeInterval) {
        guard !stopped, buffer.frameLength > 0 else { return }
        do {
            if let directory {
                if file == nil || file?.processingFormat != buffer.format {
                    guard filePart < 128 else {
                        throw ListeningFailure(message: String(localized: "音频格式变化过多，录音已停止。请检查音频设备后重试。"))
                    }
                    filePart += 1
                    let url = directory.appendingPathComponent("\(source.rawValue)-\(filePart).caf")
                    file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                           commonFormat: buffer.format.commonFormat,
                                           interleaved: buffer.format.isInterleaved)
                }
                let bytes = Int64(buffer.frameLength) * Int64(buffer.format.streamDescription.pointee.mBytesPerFrame)
                    * Int64(buffer.format.isInterleaved ? 1 : buffer.format.channelCount)
                if writtenBytes + bytes > 256 * 1024 * 1024 {
                    throw ListeningFailure(message: String(localized: "本次音频已达到保存上限，录音已停止。可以开始新的记录。"))
                }
                try file?.write(from: buffer)
                writtenBytes += bytes
            }
            if let previous = buffers.last, previous.format != buffer.format { flush() }
            if buffers.isEmpty { self.offset = offset }
            buffers.append(buffer)
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            duration += seconds
            quietDuration = Self.isQuiet(buffer) ? quietDuration + seconds : 0
            if duration >= 4 || (duration >= 1 && quietDuration >= 0.5) { flush() }
        } catch {
            stopped = true
            onFailure(error.localizedDescription)
        }
    }

    private func flush() {
        guard !buffers.isEmpty else { return }
        scheduler.enqueue(.init(source: source, offset: offset, duration: duration, buffers: buffers))
        buffers.removeAll(keepingCapacity: true)
        duration = 0
        quietDuration = 0
    }

    /// Only chooses batch boundaries, never discards input based on a threshold.
    static func isQuiet(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return false }
        var peak: Float = 0
        let channelCount = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let samples = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        for channel in 0..<channelCount {
            for frame in stride(from: 0, to: samples, by: 8) {
                peak = max(peak, abs(channels[channel][frame]))
            }
        }
        return peak < 0.008
    }

    func finish() {
        stopped = true
        flush()
        file = nil
    }

    func cancel() {
        stopped = true
        buffers.removeAll()
        file = nil
    }
}
