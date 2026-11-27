import AppKit
import AVFoundation

/// Hold a shortcut, ask out loud, release: the words go out with the current screen context in the
/// current response mode.
///
/// The microphone recording is discarded. Once sent, the recognized text follows the
/// active conversation's history rules. Live captions can listen to system audio alongside it.
@MainActor
final class PushToTalk: ObservableObject {
    static let shared = PushToTalk()
    enum State { case idle, preparing, listening, finishing }

    @Published private(set) var state: State = .idle {
        // Its live row shows under the panel header only while it listens.
        didSet { if (oldValue == .idle) != (state == .idle) { PanelController.shared.rowsChanged() } }
    }
    @Published private(set) var caption = ""
    @Published private(set) var error: String?

    /// Shorter than this is a slip of the finger, not a question.
    static let minimumHold: TimeInterval = 0.3
    /// Longer than this is more likely a key-up that never arrived than a question, so the words
    /// wait in the input box instead of being sent.
    static let maximumHold: TimeInterval = 60

    private var capture: ListeningCapture?
    private var words = CaptionBuffer(retention: .infinity)
    private var startedAt: Date?
    private var startTask: Task<Void, Never>?
    private var limitTimer: Timer?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    self.cancel()
                }
            })
        }
    }

    var isActive: Bool { state != .idle }

    func clearError() { error = nil }

    func begin() {
        let captions = LiveCaptions.shared
        guard captions.isEnabled, state == .idle else { return }
        let generation = UUID()
        self.generation = generation
        error = nil
        caption = ""
        words = CaptionBuffer(retention: .infinity)
        startedAt = Date()
        state = .preparing
        // Showing the panel captures the context the question is about, and shows it is listening.
        if !PanelController.shared.isVisible { PanelController.shared.show() }
        PanelController.shared.refreshIdleTimer()
        let engine = captions.engine, locale = captions.locale
        startTask = Task {
            do {
                try Task.checkCancellation()
                try await Self.requireMicrophone()
                try Task.checkCancellation()
                let capture = try await ListeningSession.make(engine: engine, locale: locale,
                    onUpdate: { [weak self] update in
                        Task { @MainActor in self?.receive(update, generation: generation) }
                    }, onFailure: { [weak self] message in
                        Task { @MainActor in self?.fail(message, generation: generation) }
                    })
                guard self.generation == generation else { return capture.terminate() }
                self.capture = capture
                try capture.startMicrophone()
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
        error = nil
    }

    private func receive(_ update: CaptionUpdate, generation: UUID) {
        guard self.generation == generation else { return }
        words.apply(update)
        caption = words.text
    }

    private func fail(_ message: String, generation: UUID) {
        guard self.generation == generation else { return }
        let partial = state == .finishing ? words.text : ""
        cancel()
        if !partial.isEmpty {
            _ = AssistantModel.shared.stageSpeechDraft(partial)
        }
        error = message
    }

    /// Waits for the trailing words before reading them, or the last word would be cut off.
    private func finish(sending: Bool, generation: UUID) {
        guard self.generation == generation, state == .listening, let capture else { return }
        limitTimer?.invalidate()
        state = .finishing
        Task {
            let issue = await capture.stop()
            // Let any MainActor `receive` Task queued right before `isDrained` flipped run first.
            await Task.yield()
            guard self.generation == generation else { return }
            let text = words.text
            reset()
            guard !text.isEmpty else {
                error = issue ?? String(localized: "没听清，请按住快捷键再说一次。")
                return
            }
            let assistant = AssistantModel.shared
            let accepted = sending ? assistant.submitSpeech(text) : assistant.stageSpeechDraft(text)
            guard accepted else {
                error = String(localized: "请等待回答结束，或缩短输入框文字后重试。")
                return
            }
            if !sending {
                error = String(localized: "按住说话最长 60 秒，这段话已放进输入框。")
            }
        }
    }

    private func reset() {
        generation = UUID()
        limitTimer?.invalidate()
        limitTimer = nil
        startTask = nil
        capture = nil
        caption = ""
        words = CaptionBuffer(retention: .infinity)
        startedAt = nil
        state = .idle
        PanelController.shared.refreshIdleTimer()
    }

    /// Asking for access while the key is held cannot record this press; the next one works.
    private static func requireMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw ListeningFailure.microphoneDenied }
            throw ListeningFailure(message: String(localized: "已允许麦克风，再按住说一次。"))
        default:
            throw ListeningFailure.microphoneDenied
        }
    }
}
