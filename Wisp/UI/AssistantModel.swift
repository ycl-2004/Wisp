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
        // 面板开着时用户切到别的应用（包括在 Chrome 里换一个标签页——那也会让
        // Chrome 重新激活），只记下新的目标并把上下文标成过期，**不**在这里采集。
        //
        // 以前这里会自动采一次，结果是用户每换一个标签页，屏幕就自己动一下。
        // 采集要等用户真的回到面板前再做：那才说明他准备拿这一页来提问。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, PanelController.shared.isVisible, !self.isStreaming else { return }
                self.targetApp = app
                self.contextIsStale = true
                // 切走／切回都可能改变「该不该自动收起」的答案，重新判一次。
                PanelController.shared.refreshIdleTimer()
                // 头部要立刻跟上新的应用和网址，不必等用户手动刷新。
                self.followFrontWindow()
            }
        }
    }

    // MARK: - 上下文

    /// 第二阶段还没跑的那份活。
    private var pendingText: ContextCapture.PendingText?

    /// 第一阶段：截图 + 网址标题。**必须**在浮窗出现之前跑完，否则浮窗会进画面。
    /// 只做这些，所以很快——读正文留给 `captureText()`，面板显示之后再说。
    func captureShot() async {
        guard !isCapturing else { return }
        isCapturing = true
        errorText = nil
        let (result, pending) = await ContextCapture.captureShot(excludingWindowIDs: ownWindowIDs,
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
        pendingText = pending
        isCapturing = false
        // 截图是新的了，过期标记就该清掉。正文还欠着的话由 `pendingText` 记着，
        // 不要用 contextIsStale 兼职表示这件事——否则发送时会白截一次图。
        contextIsStale = false
        if pending == nil { dumpIfNeeded() }
    }

    /// 第二阶段：读整页正文，必要时滚动采集。
    ///
    /// 刻意留到用户**按下发送**时才跑，而不是面板一出现就跑：滑动采集会真的
    /// 翻动用户的页面，在他还没想好要问什么的时候就动起来，像是电脑自作主张。
    /// 放在发送时，翻页就成了「为了回答你这个问题去把页面看完」，顺理成章。
    ///
    /// 同一份上下文只读一次：`pendingText` 用掉就置空，接着追问同一个页面
    /// 不会再翻一遍。换了标签页会标成过期，下次发送时重新采。
    func captureText() async {
        guard let pending = pendingText, var current = packet else { return }
        pendingText = nil
        isCapturing = true
        await ContextCapture.captureText(pending, into: &current)
        packet = current
        isCapturing = false
        contextIsStale = false
        dumpIfNeeded()
    }

    /// 两个阶段一次跑完。手动刷新走这条。
    func captureContext() async {
        await captureShot()
        await captureText()
    }

    private func dumpIfNeeded() {
        guard settings.debugDumpEnabled, let packet else { return }
        ContextCapture.dumpForDebug(packet)
    }

    func refreshContext() {
        Task { await captureContext() }
    }

    func panelDidResignKey() {
        // 焦点离开面板，说明用户去看别的东西了，等他回来时上下文要是新的。
        contextIsStale = true
    }

    // MARK: - 跟随当前窗口

    private var followTimer: Timer?
    /// 上一次跟随时看到的「应用 + 窗口标题」，用来判断有没有真的换过窗口。
    private var lastFollowKey: String?
    private var followTask: Task<Void, Never>?

    /// 面板显示期间，让头部的应用名和链接跟着当前窗口走。
    ///
    /// 只轮询窗口标题（`CGWindowList`，不起子进程），发现变化了才去问一次网址。
    /// 换标签页不会发任何系统通知，但窗口标题会变，所以这是唯一能发现它的办法。
    /// 注意这里**不**截图、**不**读正文、**不**滑动——那些仍然只在发送时做。
    func startFollowingFrontWindow() {
        stopFollowingFrontWindow()
        lastFollowKey = nil
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followFrontWindow() }
        }
    }

    func stopFollowingFrontWindow() {
        followTimer?.invalidate()
        followTimer = nil
        followTask?.cancel()
        followTask = nil
    }

    /// 检查前台窗口有没有换过；换了才更新头部。
    func followFrontWindow() {
        guard PanelController.shared.isVisible, !isStreaming, !isCapturing else { return }

        let ownBundleID = Bundle.main.bundleIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        // 前台是 Wisp 自己，说明用户正在面板里打字。保持现状，别把头部改掉。
        guard let app = front, app.bundleIdentifier != ownBundleID else { return }

        let title = ContextCapture.frontWindowTitle(pid: app.processIdentifier) ?? ""
        let key = "\(app.processIdentifier)|\(title)"
        guard key != lastFollowKey else { return }
        lastFollowKey = key
        targetApp = app

        followTask?.cancel()
        followTask = Task { [weak self] in
            guard let info = await ContextCapture.captureHeader(fallbackApp: app) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.applyHeader(info) }
        }
    }

    /// 把跟随到的窗口信息写进当前上下文。
    ///
    /// 换了页面就把正文清掉：留着上一页的正文配这一页的网址，模型会拿旧内容
    /// 回答新问题，比没有正文更糟。清掉之后头部显示「正文未读取」，发送时才真去读。
    private func applyHeader(_ info: ContextCapture.HeaderInfo) {
        guard var current = packet else { return }
        let pageChanged = (info.url != current.url) || (info.bundleID != current.bundleID)

        current.appName = info.appName
        current.bundleID = info.bundleID
        current.windowTitle = info.windowTitle ?? current.windowTitle
        current.url = info.url
        current.pageTitle = info.pageTitle

        if pageChanged {
            current.pageText = nil
            current.pageTextTotalChars = nil
            current.pageTextIsPartial = false
            current.usedScrollCollection = false
            current.selectedText = nil
            current.iframeURLs = []
            // 上一页的说明作废，但「要用户去开权限」那类留着——那跟哪个页面无关，
            // 抹掉的话用户就再也看不到该去授权了。
            current.notes = current.notes.filter(\.needsUserAction)
            current.notes.append(.info(String(localized: "已跟到新的页面，正文还没读取。发送问题时会读取当前页面。")))
            pendingText = nil
            contextIsStale = true
        }
        packet = current
    }

    /// 用户点回面板了。补一张新的截图和网址就够——正文和滑动采集留到发送时，
    /// 免得他只是回来看一眼、还没打算问，页面就先翻起来了。
    func panelDidBecomeKey() {
        guard contextIsStale, !isStreaming, !isCapturing else { return }
        Task { await captureShot() }
    }

    func panelDidHide() {
        pendingText = nil
        contextIsStale = true
        stopFollowingFrontWindow()
    }

    private var contextIsStale = false

    /// 距离上次采集过了多久，用于头部显示新鲜度。
    var contextAge: String {
        guard let packet else { return "" }
        let seconds = Int(Date().timeIntervalSince(packet.capturedAt))
        if seconds < 3 { return String(localized: "刚读取") }
        if seconds < 60 { return String(localized: "\(seconds) 秒前") }
        return String(localized: "\(seconds / 60) 分钟前")
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
        return String(localized: "这个对话已经到 \(store.maxUserTurns) 轮上限。新建一个，或删掉一个旧对话腾位置。")
    }

    var conversationLimitMessage: String? {
        guard !store.canCreateNew else { return nil }
        return String(localized: "已经有 \(store.maxConversations) 个对话，到上限了。可以自己删一个，或者让它顶掉最久没用的那个。")
    }

    /// 满额时要被顶掉的那个对话。UI 拿它的标题去问用户。
    var evictionCandidateTitle: String? { store.evictionCandidate?.displayTitle }

    @Published var confirmsEviction = false

    func newConversation() {
        guard store.canCreateNew else {
            // 满了不是死路：把「要顶掉哪一个」摆出来让用户确认。
            showsConversationList = true
            confirmsEviction = true
            return
        }
        store.createNew()
        errorText = nil
        showsConversationList = false
    }

    /// 用户确认之后才真的删。
    func evictOldestAndCreate() {
        store.createNewEvictingOldest()
        errorText = nil
        confirmsEviction = false
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
            // 截图过期了先补一张，然后读正文——滑动采集就发生在这一步。
            // 不再按「超过 N 秒就重来」：那会在用户慢慢打字的时候突然翻动页面。
            if packet == nil || contextIsStale {
                await captureShot()
            }
            await captureText()
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
                    self.errorText = String(localized: "模型没有返回任何内容。可以换个模型名再试。")
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
