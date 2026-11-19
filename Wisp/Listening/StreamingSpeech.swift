import AVFoundation
import Speech

/// Apple's on-device streaming recognizer (`SpeechAnalyzer`, macOS 26). With volatile and fast
/// results it revises a guess as audio arrives instead of waiting for a pause. Measured on
/// synthetic Mandarin with English terms fed at real-time pace: a caption stops changing
/// 0.5–1.1 s after a sentence ends (docs/live-listening.md).
/// https://developer.apple.com/documentation/speech/speechanalyzer
final class StreamingSpeech: SpeechFeed, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let onFailure: @Sendable (String) -> Void
    /// Sink queue only.
    private let converter: PCMConverter
    private var results: Task<Void, Never>?
    private let lock = NSLock()
    private var drained = false

    private init(analyzer: SpeechAnalyzer, format: AVAudioFormat,
                 input: AsyncStream<AnalyzerInput>.Continuation, onFailure: @escaping @Sendable (String) -> Void) {
        self.analyzer = analyzer
        converter = PCMConverter(format: format)
        self.input = input
        self.onFailure = onFailure
    }

    /// Resolves the language, installs its model if macOS has not yet, and starts the analyzer.
    static func start(locale identifier: String,
                      onUpdate: @escaping @Sendable (CaptionUpdate) -> Void,
                      onFailure: @escaping @Sendable (String) -> Void) async throws -> StreamingSpeech {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw ListeningFailure(message: String(localized: "这台电脑的设备端识别不支持所选语言。请在设置 → 音频中换一种语言。音频不会上传。"))
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [.audioTimeRange])
        // macOS downloads language models on demand; this returns nil once one is installed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ListeningFailure(message: String(localized: "设备端识别没有可用的音频格式。"))
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .lingering))
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let speech = StreamingSpeech(analyzer: analyzer, format: format, input: input, onFailure: onFailure)
        speech.results = Task {
            do {
                for try await result in transcriber.results {
                    onUpdate(Self.update(for: result))
                }
            } catch {
                if !(error is CancellationError) { onFailure(error.localizedDescription) }
            }
            speech.markDrained()
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            speech.cancel()
            throw error
        }
        return speech
    }

    /// A final result is split into its words, each with its own audio time, so a question window
    /// can cut between words. Measured: final timestamps match the audio; volatile ones do not
    /// (every word reports the end of the guess), so a guess stays one piece.
    static func update(for result: SpeechTranscriber.Result) -> CaptionUpdate {
        guard result.isFinal else {
            return .volatile(CaptionPiece(text: String(result.text.characters),
                                          start: result.range.start.seconds, end: result.range.end.seconds))
        }
        let words = result.text.runs.compactMap { run -> CaptionPiece? in
            guard let range = run.audioTimeRange else { return nil }
            return CaptionPiece(text: String(result.text[run.range].characters),
                                start: range.start.seconds, end: range.end.seconds)
        }
        let whole = String(result.text.characters)
        // Fall back to one piece if any text came without a time.
        guard words.map(\.text).joined() == whole else {
            return .committed([CaptionPiece(text: whole, start: result.range.start.seconds,
                                            end: result.range.end.seconds)])
        }
        return .committed(words)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        guard let converted = converter.convert(buffer) else {
            return fail(String(localized: "无法转换这段音频的格式，字幕已停止。"))
        }
        if converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
    }

    func endAudio() {
        input.finish()
        Task { [analyzer] in try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    var isDrained: Bool { lock.withLock { drained } }

    private func markDrained() { lock.withLock { drained = true } }

    func cancel() {
        input.finish()
        results?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
        markDrained()
    }

    private func fail(_ message: String) {
        cancel()
        onFailure(message)
    }
}
