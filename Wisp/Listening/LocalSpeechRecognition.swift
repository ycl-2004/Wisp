import AVFoundation
import SherpaOnnxC

/// Owns a native sherpa-onnx recognizer for one session, whatever the model family. All loads and
/// decodes use the same serial worker, including across Stop/Start, so an uncancellable native
/// call cannot pile up — and a decode queued behind a load simply waits for it.
final class LocalSpeechRecognition: @unchecked Sendable {
    private static let worker = DispatchQueue(label: "com.yichenlin.Wisp.local-speech", qos: .userInitiated)
    private let model: LocalSpeechModel
    let title: String
    /// The hint actually passed to the model, recorded with the transcript.
    let language: String
    let script: ChineseScript
    /// Touched only on `worker` (and in deinit, after every queued call has run).
    private var recognizer: OpaquePointer?
    private var loadFailure: Error?

    /// Waits for the model, so a broken model is reported before a session starts.
    static func load(_ model: LocalSpeechModel, language: String,
                     script: ChineseScript = .original) async throws -> LocalSpeechRecognition {
        let recognition = LocalSpeechRecognition(model: model, language: language, script: script)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async {
                do { try recognition.create(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
        return recognition
    }

    /// Returns at once and loads ahead of every decode on the same serial worker, so capture can
    /// start while the model loads: push-to-talk cannot ask the speaker to wait seconds first.
    /// A failed load is reported by the first decode.
    static func prepare(_ model: LocalSpeechModel, language: String, script: ChineseScript) -> LocalSpeechRecognition {
        let recognition = LocalSpeechRecognition(model: model, language: language, script: script)
        worker.async {
            do { try recognition.create() } catch { recognition.loadFailure = error }
        }
        return recognition
    }

    private init(model: LocalSpeechModel, language saved: String, script: ChineseScript) {
        self.model = model
        title = model.family.title
        language = model.family.language(for: saved)
        self.script = script
    }

    private func create() throws {
        // Zeroed fields mean "sherpa-onnx default"; c-api.h asks callers to zero-initialize and
        // fill only one family's section. The C constructor returns nil for a failed validation
        // where the Swift wrapper would fatalError.
        // https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.7/sherpa-onnx/c-api/c-api.h
        let strings = CStringPool()
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.decoding_method = strings("greedy_search")
        config.model_config.num_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
        config.model_config.provider = strings("cpu")
        model.family.configure(&config.model_config, files: model.files, language: language, strings: strings)
        let pointer = withExtendedLifetime(strings) { SherpaOnnxCreateOfflineRecognizer(&config) }
        guard let pointer else {
            throw ListeningFailure(message: String(localized: "\(title) 模型加载失败，请检查本地模型文件。") + "\n" + model.folder.path)
        }
        recognizer = pointer
    }

    deinit { if let recognizer { SherpaOnnxDestroyOfflineRecognizer(recognizer) } }

    func recognize(_ batch: ListeningSpeechScheduler.Batch,
                   receive: @escaping (ListeningSpeechScheduler.Update) -> Void) -> () -> Void {
        let work = DispatchWorkItem { [self] in
            // Measured on the shipped models: SenseVoice turns silence and room noise into a
            // stray syllable ("그.") at every level up to the quiet threshold, and application
            // audio delivers silence continuously between turns. A batch that never rises above
            // that threshold carries no speech, so it is not decoded at all.
            guard !Self.isSilent(batch) else {
                receive(.init(text: "", end: batch.duration, isFinal: true))
                return
            }
            do {
                let samples = try Self.samples(from: batch.buffers)
                let text = try decode(samples)
                receive(.init(text: text, end: batch.duration, isFinal: true))
            } catch { receive(.init(error: error)) }
        }
        Self.worker.async(execute: work)
        // Native inference cannot be interrupted mid-call. The scheduler invalidates
        // callbacks immediately; cancellation prevents queued work from starting.
        return { work.cancel() }
    }

    static func isSilent(_ batch: ListeningSpeechScheduler.Batch) -> Bool {
        batch.buffers.allSatisfy(ListeningSpeechTrack.isQuiet)
    }

    private func decode(_ samples: [Float]) throws -> String {
        guard let recognizer else {
            throw loadFailure ?? ListeningFailure(message: String(localized: "\(title) 模型加载失败，请检查本地模型文件。"))
        }
        guard !samples.isEmpty else { return "" }
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            throw ListeningFailure(message: String(localized: "\(title) 无法创建转写任务。"))
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        SherpaOnnxAcceptWaveformOffline(stream, 16_000, samples, Int32(samples.count))
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw ListeningFailure(message: String(localized: "\(title) 未能返回转写结果。"))
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let text = result.pointee.text else { return "" }
        return script.apply(to: String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Convert the whole bounded batch, preserving converter state between input buffers.
    /// https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions
    static func samples(from buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        guard let first = buffers.first else { return [] }
        let failure = ListeningFailure(message: String(localized: "本地模型无法转换此音频格式。"))
        let duration = buffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        guard duration.isFinite, duration <= 30,
              buffers.allSatisfy({ $0.format == first.format }),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: first.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw failure
        }
        var index = 0
        var samples: [Float] = []
        let limit = Int(ceil(duration * 16_000)) + 4096
        while samples.count <= limit {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                guard index < buffers.count else { state.pointee = .endOfStream; return nil }
                let buffer = buffers[index]
                index += 1
                state.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            guard status != .error, let channel = output.floatChannelData?[0] else { throw failure }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            if status == .endOfStream { return samples }
            if output.frameLength == 0 { break }
        }
        throw failure
    }
}
