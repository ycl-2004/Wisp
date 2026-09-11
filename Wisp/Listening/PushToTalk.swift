import AVFoundation
import Speech

/// Hold a shortcut, ask out loud, release: the words go out with the current screen context in the
/// current response mode.
///
/// Microphone only, whatever the recording source setting says: this is the user's own question.
/// Nothing is written to the listening records, since every question would otherwise take one of
/// the archive's 100 session slots. It never runs beside a recording, which owns the microphone.
@MainActor
final class PushToTalk: ObservableObject {
    static let shared = PushToTalk()
    enum State { case idle, preparing, listening, finishing }

    @Published private(set) var state: State = .idle
    @Published private(set) var caption = ""
    @Published private(set) var error: String?
    @Published private(set) var startedAt: Date?

    /// Shorter than this is a slip of the finger, not a question.
    static let minimumHold: TimeInterval = 0.3
    /// Longer than this is more likely a key-up that never arrived than a question, so the words
    /// wait in the input box instead of being sent.
    static let maximumHold: TimeInterval = 60

    private var capture: ListeningCapture?
    private var transcript: ListeningTranscript?
    private var startTask: Task<Void, Never>?
    private var limitTimer: Timer?
    private var generation = UUID()

    private init() {}

    var isActive: Bool { state != .idle }

    func clearError() { error = nil }

    func begin() {
        let listening = ListeningModel.shared
        guard listening.isEnabled, state == .idle else { return }
        guard !listening.isActive else {
            error = String(localized: "正在录音，先停下录音再按住说话。")
            return
        }
        let generation = UUID()
        self.generation = generation
        error = nil
        caption = ""
        startedAt = Date()
        state = .preparing
        transcript = ListeningTranscript(id: UUID(), startedAt: Date(), locale: listening.locale,
                                         applicationName: nil, savesAudio: false)
        // Showing the panel captures the context the question is about, and shows it is listening.
        if !PanelController.shared.isVisible { PanelController.shared.show() }
        PanelController.shared.refreshIdleTimer()
        let engine = listening.engine, locale = listening.locale
        let language = listening.localLanguage, script = listening.chineseScript
        startTask = Task {
            do {
                try await Self.requirePermissions(for: engine)
                let recognition: LocalSpeechRecognition?
                if case .local(let id) = engine {
                    let model = try await Task.detached { try LocalSpeechCatalog.readyModel(id: id) }.value
                    // Loads while the microphone already listens; decoding queues behind the load.
                    recognition = LocalSpeechRecognition.prepare(model, language: language, script: script)
                } else {
                    recognition = nil
                }
                guard self.generation == generation else { return }
                let capture = try ListeningCapture(mode: .microphone, locale: locale, recognition: recognition, directory: nil,
                    onSegment: { [weak self] segment in
                        Task { @MainActor in self?.receive(segment, generation: generation) }
                    }, onFailure: { [weak self] message in
                        Task { @MainActor in self?.fail(message, generation: generation) }
                    })
                self.capture = capture
                try await capture.start(mode: .microphone, application: nil)
                guard self.generation == generation else { return }
                state = .listening
                limitTimer = Timer.scheduledTimer(withTimeInterval: Self.maximumHold, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.finish(sending: false, generation: generation) }
                }
            } catch {
                fail(error.localizedDescription, generation: generation)
            }
        }
    }

    func end() {
        switch state {
        case .idle, .finishing:
            return
        case .preparing:
            // Released before the microphone was even open: nothing was heard.
            cancel()
        case .listening:
            let held = Date().timeIntervalSince(startedAt ?? .distantPast)
            if held < Self.minimumHold { cancel() } else { finish(sending: true, generation: generation) }
        }
    }

    /// Stops without sending anything.
    func cancel() {
        generation = UUID()
        startTask?.cancel()
        capture?.terminate()
        reset()
    }

    private func receive(_ segment: ListeningSegment, generation: UUID) {
        guard self.generation == generation, transcript?.upsert(segment) == true else { return }
        caption = transcript?.spokenText() ?? ""
    }

    private func fail(_ message: String, generation: UUID) {
        guard self.generation == generation else { return }
        cancel()
        error = message
    }

    /// Drains the trailing batch before reading the words, or the last word would be cut off.
    private func finish(sending: Bool, generation: UUID) {
        guard self.generation == generation, state == .listening, let capture else { return }
        limitTimer?.invalidate()
        state = .finishing
        Task {
            let issue = await capture.stop()
            guard self.generation == generation else { return }
            let text = transcript?.spokenText() ?? ""
            reset()
            guard !text.isEmpty else {
                error = issue ?? String(localized: "没听清，请按住快捷键再说一次。")
                return
            }
            let assistant = AssistantModel.shared
            guard assistant.stageSpeechDraft(text) else {
                error = String(localized: "请等待回答结束，或缩短输入框文字后重试。")
                return
            }
            if sending {
                assistant.send()
            } else {
                error = String(localized: "按住说话最长 60 秒，这段话已放进输入框。")
            }
        }
    }

    private func reset() {
        limitTimer?.invalidate()
        limitTimer = nil
        startTask = nil
        capture = nil
        transcript = nil
        caption = ""
        startedAt = nil
        state = .idle
        PanelController.shared.refreshIdleTimer()
    }

    /// Asking for access while the key is held cannot record this press; the next one works.
    private static func requirePermissions(for engine: ListeningEngine) async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw ListeningFailure.microphoneDenied }
            throw ListeningFailure(message: String(localized: "已允许麦克风，再按住说一次。"))
        default:
            throw ListeningFailure.microphoneDenied
        }
        guard engine.requiresSpeechAuthorization else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw ListeningFailure.speechRecognitionDenied }
            throw ListeningFailure(message: String(localized: "已允许语音识别，再按住说一次。"))
        default:
            throw ListeningFailure.speechRecognitionDenied
        }
    }
}
