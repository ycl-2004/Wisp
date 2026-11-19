import AppKit

/// Live captions of the other side of a meeting: everything this Mac plays (never the
/// microphone), kept for 30 seconds in memory and never written to disk.
///
/// Captions show as a strip in the assistant panel. A command that attaches recent words asks about
/// them in a conversation that is never saved either, and stopping the captions discards that too.
/// Closing the panel stops the captions: Wisp never listens with nothing on screen.
@MainActor
final class LiveCaptions: ObservableObject {
    static let shared = LiveCaptions()
    enum State { case idle, starting, running }

    @Published private(set) var state: State = .idle
    @Published private(set) var buffer = CaptionBuffer()
    /// When the recognizer last changed the words, for dimming the bar in a silence.
    @Published private(set) var lastChange: Date?
    @Published private(set) var message: String?
    /// The stop message is about Screen & System Audio Recording, which only System Settings grants.
    @Published private(set) var needsScreenPermission = false

    @Published private var preferences = ListeningPreferences.load(from: .standard) {
        didSet { preferences.save(to: .standard) }
    }
    var engine: ListeningEngine {
        get { preferences.recognitionEngine ?? .appleSpeech }
        set { guard state == .idle else { return }; preferences.recognitionEngine = newValue }
    }
    var locale: String {
        get { preferences.locale }
        set { guard state == .idle else { return }; preferences.locale = newValue }
    }
    /// See `ListeningPreferences.asksThroughAPI`.
    var asksThroughAPI: Bool {
        get { preferences.asksThroughAPI ?? true }
        set { preferences.asksThroughAPI = newValue }
    }
    /// See `ListeningPreferences.autoAnswer`. Off by default: every detected question is a request.
    var autoAnswer: Bool {
        get { preferences.autoAnswer ?? false }
        set { preferences.autoAnswer = newValue }
    }

    /// 关闭语音时停止两个音频来源，以及尚未发出的语音提问。
    var isEnabled: Bool {
        get { AppSettings.shared.listeningEnabled }
        set {
            guard newValue != AppSettings.shared.listeningEnabled else { return }
            objectWillChange.send()
            AppSettings.shared.listeningEnabled = newValue
            if !newValue {
                PushToTalk.shared.cancel()
                AssistantModel.shared.cancelPendingVoiceQuestion()
                stop()
            }
        }
    }

    var isActive: Bool { state != .idle }
    var isRunning: Bool { state == .running }
    /// The panel shows the caption strip: running, or explaining why it stopped.
    var showsStrip: Bool { isActive || message != nil }

    /// How long a question waits for the words still being recognized: the question is usually the
    /// last thing said. Recognition settles about 0.5–1 s after speech ends.
    static let settleTimeout: TimeInterval = 1
    static let settledAfter: TimeInterval = 0.4

    private var capture: ListeningCapture?
    private var startTask: Task<Void, Never>?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop(reason: String(localized: "电脑进入睡眠或锁定，字幕已停止。")) }
            })
        }
    }

    // MARK: - Start and stop

    func toggleFromUser() {
        guard isEnabled else { return }
        if isActive { stop(); return }
        message = nil
        needsScreenPermission = false
        if !PanelController.shared.isVisible { PanelController.shared.show() }
        // Without this permission macOS delivers no audio; say so instead of showing an empty strip.
        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            needsScreenPermission = true
            message = String(localized: "字幕要用「屏幕与系统音频录制」权限才能听电脑的声音。请在系统设置中打开 Wisp，再开字幕。")
            PanelController.shared.rowsChanged()
            return
        }
        start()
    }

    private func start() {
        guard state == .idle, isEnabled else { return }
        let engine = self.engine, locale = self.locale
        let generation = UUID()
        self.generation = generation
        state = .starting
        message = nil
        buffer = CaptionBuffer()
        lastChange = nil
        PanelController.shared.rowsChanged()
        startTask = Task {
            do {
                let capture = try await ListeningSession.make(engine: engine, locale: locale,
                    onUpdate: { [weak self] update in
                        Task { @MainActor in self?.receive(update, generation: generation) }
                    }, onFailure: { [weak self] message in
                        Task { @MainActor in
                            guard self?.generation == generation else { return }
                            self?.stop(reason: message)
                        }
                    })
                guard self.generation == generation else { return capture.terminate() }
                self.capture = capture
                try await capture.startSystemAudio()
                guard self.generation == generation else { return }
                state = .running
            } catch {
                guard self.generation == generation else { return }
                stop(reason: error is CancellationError ? nil : error.localizedDescription)
            }
            if self.generation == generation { startTask = nil }
        }
    }

    private func receive(_ update: CaptionUpdate, generation: UUID) {
        guard self.generation == generation, state == .running else { return }
        let before = buffer
        buffer.apply(update)
        guard buffer != before else { return }
        lastChange = Date()
        if autoAnswer { scheduleAutoAnswer() }
    }

    // MARK: - Auto answer (experimental)

    /// How long the words must stay still after a question mark before it counts as asked.
    static let autoAnswerPause: TimeInterval = 1
    /// No second automatic question within this long of the last one.
    static let autoAnswerCooldown: TimeInterval = 8
    private var autoAnswerTask: Task<Void, Never>?
    private var lastAutoAnswer: Date?
    /// The audio time of the last question answered automatically, so one question is asked once.
    private var answeredThrough: TimeInterval = -1

    /// Each change restarts the wait: the question counts once the other side has paused after it.
    private func scheduleAutoAnswer() {
        autoAnswerTask?.cancel()
        let generation = self.generation
        autoAnswerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoAnswerPause))
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.autoAnswerIfAsked()
        }
    }

    private func autoAnswerIfAsked() {
        let assistant = AssistantModel.shared
        guard isRunning, autoAnswer, buffer.latestEnd > answeredThrough,
              CaptionBuffer.endsWithQuestion(buffer.text),
              Date().timeIntervalSince(lastAutoAnswer ?? .distantPast) >= Self.autoAnswerCooldown,
              let command = QuickCommandStore.shared.commands.first(where: { $0.attachedSeconds > 0 && $0.isRunnable }),
              !assistant.isStreaming, !assistant.isPreparingResponse, !assistant.isCapturing else { return }
        answeredThrough = buffer.latestEnd
        lastAutoAnswer = Date()
        assistant.runAutomaticCaptionCommand(command, words: buffer.text(lastSeconds: TimeInterval(command.attachedSeconds)))
    }

    /// Stops at once: nothing is saved, so there are no trailing words to wait for. The words and the
    /// caption conversation are discarded. A `reason` stays on the bar until it is dismissed.
    func stop(reason: String? = nil) {
        generation = UUID()
        startTask?.cancel()
        startTask = nil
        capture?.terminate()
        capture = nil
        state = .idle
        autoAnswerTask?.cancel()
        answeredThrough = -1
        lastAutoAnswer = nil
        buffer = CaptionBuffer()
        lastChange = nil
        ConversationStore.shared.discardEphemeral()
        message = reason
        needsScreenPermission = false
        PanelController.shared.rowsChanged()
    }

    func dismissMessage() {
        message = nil
        needsScreenPermission = false
        PanelController.shared.rowsChanged()
    }

    func terminate() { stop() }

    /// 恢复出厂之后重新读一遍偏好：内存里那份还是旧的，不重读的话下一次改动又把它整份写回去。
    func reloadPreferences() {
        preferences = ListeningPreferences.load(from: .standard)
    }

    // MARK: - Questions

    /// The other side's words from the last `seconds`, after giving the words still being
    /// recognized up to a second to settle. Nil if the capture session ends while waiting.
    func recentText(seconds: TimeInterval) async -> String? {
        guard state == .running else { return nil }
        let generation = self.generation
        let deadline = Date().addingTimeInterval(Self.settleTimeout)
        while self.generation == generation, !Task.isCancelled, Date() < deadline,
              let lastChange, Date().timeIntervalSince(lastChange) < Self.settledAfter {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard self.generation == generation, !Task.isCancelled else { return nil }
        return buffer.text(lastSeconds: seconds)
    }
}
