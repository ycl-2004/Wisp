import AppKit
import SwiftUI

@MainActor
final class AssistantModel: ObservableObject {
    static let shared = AssistantModel()

    @Published var packet: ContextPacket?
    @Published var isCapturing = false
    @Published var input = ""
    @Published var isStreaming = false {
        didSet {
            IslandModel.shared.isGenerating = isStreaming
            // 正在生成回答时不能自动收起，生成完了才开始计时。
            PanelController.shared.refreshIdleTimer()
        }
    }
    @Published var errorText: String?
    @Published var showsConversationList = false
    @Published var showsNotes = false
    @Published private(set) var isCollapsed = true
    private var suppressCollapseAnimation = false

    /// 用户点收起／展开时走这里，会带动画。
    func setCollapsed(_ collapsed: Bool) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed
        if !suppressCollapseAnimation {
            PanelController.shared.setCollapsed(collapsed)
        }
    }

    /// 面板还没显示时改状态，尺寸由 position 一次算好，不需要动画。
    func setCollapsedSilently(_ collapsed: Bool) {
        suppressCollapseAnimation = true
        isCollapsed = collapsed
        suppressCollapseAnimation = false
    }

    let store = ConversationStore.shared
    let settings = AppSettings.shared

    private var streamTask: Task<Void, Never>?
    /// 已经发过截图的那份上下文，避免同一张图重复发。
    private var lastSentPacketID: UUID?
    /// 上一次采集到的画面，用来判断屏幕有没有真的变过。
    private var lastScreenshotHash: Int?
    private var lastURL: String?

    var ownWindowIDs: [CGWindowID] = []
    /// 浮窗抢到焦点后，仍然记得要读取哪个应用。
    var targetApp: NSRunningApplication?

    private init() {
        // 面板开着时用户切到别的应用，自动跟上新的画面。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, PanelController.shared.isVisible, !self.isStreaming else { return }
                self.targetApp = app
                self.scheduleAutoCapture()
            }
        }
    }

    // MARK: - 上下文

    /// 浮窗即将显示时调用。截图必须在浮窗出现之前完成。
    func captureContext() async {
        guard !isCapturing else { return }
        isCapturing = true
        errorText = nil
        let result = await ContextCapture.capture(excludingWindowIDs: ownWindowIDs,
                                                  fallbackApp: targetApp)
        if let bundleID = result.bundleID,
           bundleID != Bundle.main.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            targetApp = running
        }

        // 画面和网址都没变的话，沿用上一份的「已发过截图」标记，别重复付图片的钱。
        let hash = result.screenshotJPEG?.hashValue
        let unchanged = (hash != nil && hash == lastScreenshotHash && result.url == lastURL)
        if !unchanged { lastSentPacketID = nil }
        lastScreenshotHash = hash
        lastURL = result.url

        packet = result
        isCapturing = false

        if settings.debugDumpEnabled {
            ContextCapture.dumpForDebug(result)
        }
    }

    func refreshContext() {
        Task { await captureContext() }
    }

    private var autoCaptureTask: Task<Void, Never>?

    /// 合并短时间内的多次触发，避免切窗口时连着截好几次。
    private func scheduleAutoCapture() {
        autoCaptureTask?.cancel()
        autoCaptureTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.captureContext()
        }
    }

    func panelDidResignKey() {
        // 焦点离开面板，说明用户去看别的东西了，等他回来时上下文要是新的。
        contextIsStale = true
    }

    func panelDidHide() {
        autoCaptureTask?.cancel()
        contextIsStale = true
    }

    private var contextIsStale = false

    /// 距离上次采集过了多久，用于头部显示新鲜度。
    var contextAge: String {
        guard let packet else { return "" }
        let seconds = Int(Date().timeIntervalSince(packet.capturedAt))
        if seconds < 3 { return "刚读取" }
        if seconds < 60 { return "\(seconds) 秒前" }
        return "\(seconds / 60) 分钟前"
    }

    // MARK: - 对话

    var activeConversation: Conversation? { store.active }

    var canSend: Bool {
        guard !isStreaming else { return false }
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let conversation = store.active else { return store.canCreateNew }
        return !store.isAtTurnLimit(conversation)
    }

    var turnLimitMessage: String? {
        guard let conversation = store.active, store.isAtTurnLimit(conversation) else { return nil }
        return "这个对话已经到 \(store.maxUserTurns) 轮上限。新建一个，或删掉一个旧对话腾位置。"
    }

    var conversationLimitMessage: String? {
        guard !store.canCreateNew else { return nil }
        return "已经有 \(store.maxConversations) 个对话，到上限了。要新建请先手动删一个。"
    }

    func newConversation() {
        guard store.canCreateNew else { return }
        store.createNew()
        errorText = nil
        showsConversationList = false
    }

    func select(_ id: UUID) {
        store.select(id)
        showsConversationList = false
    }

    func delete(_ id: UUID) {
        store.delete(id)
    }

    // MARK: - 发送

    func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }

        if isCollapsed {
            withAnimation(.easeOut(duration: 0.18)) { setCollapsed(false) }
        }
        Task {
            // 发之前先确认上下文是新的，省得用户还要自己点刷新。
            let age = packet.map { Date().timeIntervalSince($0.capturedAt) } ?? .infinity
            if packet == nil || contextIsStale || age > 20 {
                contextIsStale = false
                await captureContext()
            }
            performSend(question: question)
        }
    }

    private func performSend(question: String) {
        guard let conversation = store.ensureActive() else {
            errorText = conversationLimitMessage
            return
        }
        guard !store.isAtTurnLimit(conversation) else {
            errorText = turnLimitMessage
            return
        }

        let conversationID = conversation.id
        errorText = nil
        input = ""

        var screenshotToSend: Data?
        if settings.sendScreenshot, let packet, packet.hasScreenshot, lastSentPacketID != packet.id {
            screenshotToSend = packet.screenshotJPEG
            lastSentPacketID = packet.id
        }

        let snapshot = (packet?.isExcluded == true) ? nil : packet?.snapshot()
        let userMessage = Message(role: .user,
                                  text: question,
                                  context: snapshot,
                                  sentScreenshot: screenshotToSend != nil)
        store.append(userMessage, to: conversationID)

        let assistantMessage = Message(role: .assistant, text: "")
        store.append(assistantMessage, to: conversationID)

        let history = store.conversations.first { $0.id == conversationID }?.messages ?? []
        let payloadMessages = Array(history.dropLast())
        let payload = PromptBuilder.build(messages: payloadMessages, liveScreenshot: screenshotToSend)

        isStreaming = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            var counter = 0
            do {
                let config = try ProviderConfig.current()
                let provider = ProviderConfig.provider(for: config.kind)
                for try await chunk in provider.stream(messages: payload, config: config) {
                    if Task.isCancelled { break }
                    accumulated += chunk
                    counter += 1
                    self.store.updateStreaming(text: accumulated, messageID: assistantMessage.id,
                                               in: conversationID, persistNow: false)
                    if counter % 40 == 0 { self.store.flush() }
                }
                if accumulated.isEmpty {
                    self.store.removeMessage(assistantMessage.id, from: conversationID)
                    self.errorText = "模型没有返回任何内容。可以换个模型名再试。"
                } else {
                    self.store.updateStreaming(text: accumulated, messageID: assistantMessage.id,
                                               in: conversationID, persistNow: true)
                }
            } catch {
                if accumulated.isEmpty {
                    self.store.removeMessage(assistantMessage.id, from: conversationID)
                } else {
                    self.store.updateStreaming(text: accumulated, messageID: assistantMessage.id,
                                               in: conversationID, persistNow: true)
                }
                if let providerError = error as? ProviderError {
                    if case .cancelled = providerError { self.errorText = nil }
                    else { self.errorText = providerError.errorDescription }
                } else {
                    self.errorText = error.localizedDescription
                }
            }
            self.isStreaming = false
            self.streamTask = nil
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        store.flush()
    }

    // MARK: - 杂项

    func toggleScreenshot() {
        settings.sendScreenshot.toggle()
    }

    func excludeCurrentApp() {
        guard let bundleID = packet?.bundleID, !bundleID.isEmpty else { return }
        var list = settings.excludedBundleIDs
        guard !list.contains(bundleID) else { return }
        list.append(bundleID)
        settings.excludedBundleIDs = list
        refreshContext()
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
