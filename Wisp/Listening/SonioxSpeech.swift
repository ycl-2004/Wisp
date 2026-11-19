import AVFoundation

/// Soniox's real-time recognizer over a WebSocket. The audio leaves the Mac: it is sent to Soniox
/// as 16 kHz 16-bit mono PCM while captions run, and billed by the minute.
///
/// Protocol: authenticate with an `Authorization: Bearer` header, send one JSON configuration as
/// the first text message, then audio as binary frames; an empty text frame ends the stream, and
/// the server answers with `finished: true` before closing. Final tokens arrive once; the
/// non-final tail is re-sent with every response until it settles.
/// https://docs.soniox.com/api-reference/stt/websocket-api
final class SonioxSpeech: SpeechFeed, @unchecked Sendable {
    static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    static let model = "stt-rt-v6"
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                      channels: 1, interleaved: true)!

    private let task: URLSessionWebSocketTask
    private let onUpdate: @Sendable (CaptionUpdate) -> Void
    private let onFailure: @Sendable (String) -> Void
    /// Sink queue only.
    private let converter = PCMConverter(format: SonioxSpeech.format)
    private let lock = NSLock()
    private var drained = false

    private init(task: URLSessionWebSocketTask, onUpdate: @escaping @Sendable (CaptionUpdate) -> Void,
                 onFailure: @escaping @Sendable (String) -> Void) {
        self.task = task
        self.onUpdate = onUpdate
        self.onFailure = onFailure
    }

    /// Opens the stream and sends the configuration. A rejected key or quota arrives as the
    /// server's first response, through `onFailure`.
    static func start(apiKey: String?, locale: String,
                      onUpdate: @escaping @Sendable (CaptionUpdate) -> Void,
                      onFailure: @escaping @Sendable (String) -> Void) async throws -> SonioxSpeech {
        guard let apiKey, !apiKey.isEmpty else {
            throw ListeningFailure(message: String(localized: "云端识别需要 Soniox API Key，请在设置 → 音频中填写。"))
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        let speech = SonioxSpeech(task: task, onUpdate: onUpdate, onFailure: onFailure)
        task.resume()
        try await task.send(.string(configuration(locale: locale)))
        speech.receive()
        return speech
    }

    /// The first message. Hints keep the model to the meeting's language plus English terms.
    static func configuration(locale: String) -> String {
        let language = String(locale.prefix(2))
        let hints = language == "en" ? ["en"] : [language, "en"]
        let object: [String: Any] = [
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "language_hints": hints,
            "enable_endpoint_detection": true,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// What one server message means for the captions.
    enum Message: Equatable {
        case updates([CaptionUpdate])
        case finished
        case failure(String)
    }

    /// Final tokens become committed words with their own times; the non-final tokens are the
    /// current guess. `<end>` and `<fin>` mark endpoints, not speech.
    static func parse(_ text: String) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        if let code = object["error_code"] {
            let message = object["error_message"] as? String ?? ""
            return .failure(String(localized: "Soniox 拒绝了请求（\(String(describing: code))）：\(message)"))
        }
        if object["finished"] as? Bool == true { return .finished }
        guard let tokens = object["tokens"] as? [[String: Any]] else { return .updates([]) }
        var committed: [CaptionPiece] = []
        var guess: [CaptionPiece] = []
        for token in tokens {
            guard let text = token["text"] as? String, !text.isEmpty, text != "<end>", text != "<fin>" else { continue }
            let piece = CaptionPiece(text: text,
                                     start: (token["start_ms"] as? Double ?? 0) / 1000,
                                     end: (token["end_ms"] as? Double ?? 0) / 1000)
            if token["is_final"] as? Bool == true { committed.append(piece) } else { guess.append(piece) }
        }
        // Every response carries the whole non-final tail, so what it holds (possibly nothing)
        // is the current guess.
        let tail = guess.first.map { CaptionPiece(text: guess.map(\.text).joined(), start: $0.start, end: guess.last!.end) }
        return .updates((committed.isEmpty ? [] : [.committed(committed)]) + [.volatile(tail)])
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                switch Self.parse(text) {
                case .updates(let updates)?: updates.forEach(self.onUpdate)
                case .finished?: self.markDrained(); return
                case .failure(let message)?: self.markDrained(); self.onFailure(message); return
                case nil: break
                }
                self.receive()
            case .success:
                self.receive()
            case .failure(let error):
                guard !self.isDrained else { return }
                self.markDrained()
                self.onFailure(String(localized: "与 Soniox 的连接中断：\(error.localizedDescription)"))
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, !isDrained else { return }
        guard let converted = converter.convert(buffer) else {
            markDrained()
            return onFailure(String(localized: "无法转换这段音频的格式，字幕已停止。"))
        }
        let bytes = Int(converted.frameLength) * Int(Self.format.streamDescription.pointee.mBytesPerFrame)
        guard bytes > 0, let samples = converted.audioBufferList.pointee.mBuffers.mData else { return }
        task.send(.data(Data(bytes: samples, count: bytes))) { _ in }
    }

    func endAudio() {
        // An empty text frame ends the stream; the server sends what is left, then `finished`.
        task.send(.string("")) { _ in }
    }

    var isDrained: Bool { lock.withLock { drained } }

    private func markDrained() { lock.withLock { drained = true } }

    func cancel() {
        markDrained()
        task.cancel(with: .goingAway, reason: nil)
    }
}
