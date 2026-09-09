import AVFoundation
import SherpaOnnx
import SherpaOnnxC

enum ListeningRecognitionEngine: String, Codable, CaseIterable, Identifiable {
    case appleSpeech, senseVoice
    var id: String { rawValue }
    var requiresSpeechAuthorization: Bool { self == .appleSpeech }
    var title: String {
        switch self {
        case .appleSpeech: return String(localized: "Apple 设备端语音识别")
        case .senseVoice: return "SenseVoice Small"
        }
    }
}

/// Owns a native recognizer for one session. All loads and decodes use the same serial
/// worker, including across Stop/Start, so an uncancellable native call cannot pile up.
final class SenseVoiceRecognition: @unchecked Sendable {
    static let languages = ["auto", "zh", "en", "ja", "ko", "yue"]
    static let modelFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/huggingface/models/k2-fsa/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17", isDirectory: true)
    private static let worker = DispatchQueue(label: "com.yichenlin.Wisp.sensevoice", qos: .userInitiated)
    private let recognizer: OpaquePointer

    static func validateModel(in folder: URL = modelFolder) throws {
        for name in ["model.int8.onnx", "tokens.txt"] {
            let url = folder.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw ListeningFailure(message: String(localized: "SenseVoice 模型文件缺失或不可读：") + "\n" + url.path)
            }
        }
    }

    static func load(language: String, folder: URL = modelFolder) async throws -> SenseVoiceRecognition {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                do { continuation.resume(returning: try SenseVoiceRecognition(language: language, folder: folder)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private init(language: String, folder: URL) throws {
        try Self.validateModel(in: folder)
        guard Self.languages.contains(language) else {
            throw ListeningFailure(message: String(localized: "SenseVoice 不支持所选语言。"))
        }
        // Official v1.13.7 Swift config helpers; use the fallible C constructor instead
        // of the Swift wrapper's fatalError when a model cannot be loaded.
        // https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.7/swift-api-examples/SherpaOnnx.swift
        let modelPath = folder.appendingPathComponent("model.int8.onnx").path
        let tokensPath = folder.appendingPathComponent("tokens.txt").path
        let pointer = modelPath.withCString { model in
            tokensPath.withCString { tokens in
                language.withCString { language in
                    var config = sherpaOnnxOfflineRecognizerConfig(
                        featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
                        modelConfig: sherpaOnnxOfflineModelConfig(tokens: "", numThreads: min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)), provider: "cpu"),
                        decodingMethod: "greedy_search")
                    config.model_config.tokens = tokens
                    config.model_config.sense_voice.model = model
                    config.model_config.sense_voice.language = language
                    config.model_config.sense_voice.use_itn = 1
                    return SherpaOnnxCreateOfflineRecognizer(&config)
                }
            }
        }
        guard let pointer else {
            throw ListeningFailure(message: String(localized: "SenseVoice 模型加载失败，请检查本地模型文件。"))
        }
        recognizer = pointer
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

    func recognize(_ batch: ListeningSpeechScheduler.Batch,
                   receive: @escaping (ListeningSpeechScheduler.Update) -> Void) -> () -> Void {
        let work = DispatchWorkItem { [self] in
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

    private func decode(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            throw ListeningFailure(message: String(localized: "SenseVoice 无法创建转写任务。"))
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        SherpaOnnxAcceptWaveformOffline(stream, 16_000, samples, Int32(samples.count))
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw ListeningFailure(message: String(localized: "SenseVoice 未能返回转写结果。"))
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let text = result.pointee.text else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Convert the whole bounded batch, preserving converter state between input buffers.
    /// https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions
    static func samples(from buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        guard let first = buffers.first else { return [] }
        let duration = buffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        guard duration.isFinite, duration <= 30,
              buffers.allSatisfy({ $0.format == first.format }),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: first.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw ListeningFailure(message: String(localized: "SenseVoice 无法转换此音频格式。"))
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
            guard status != .error, let channel = output.floatChannelData?[0] else {
                throw ListeningFailure(message: String(localized: "SenseVoice 无法转换此音频格式。"))
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            if status == .endOfStream { return samples }
            if output.frameLength == 0 { break }
        }
        throw ListeningFailure(message: String(localized: "SenseVoice 无法转换此音频格式。"))
    }
}
