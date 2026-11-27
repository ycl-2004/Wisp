import AppKit
import SwiftUI

@MainActor
final class AssistantModel: ObservableObject {
    static let shared = AssistantModel()

    enum QuestionSource { case manual, captionCommand, automaticCaption, pushToTalk }

    @Published var packet: ContextPacket?
    @Published var isCapturing = false
    @Published var input = "" {
        didSet { if input.isEmpty { isSpeechDraft = false } }
    }
    @Published private(set) var isSpeechDraft = false
    @Published private(set) var speechDraftRevision = 0
    @Published var isStreaming = false {
        didSet {
            IslandModel.shared.isGenerating = isStreaming
            // 正在生成回答时不能自动收起，生成完了才开始计时。
            PanelController.shared.refreshIdleTimer()
        }
    }
    @Published private(set) var isPreparingResponse = false
    @Published private(set) var lastResponseTiming: ResponseTiming?
    @Published private(set) var lastResponseSkippedPage = false
    private var preparationTask: Task<Void, Never>?
    private var preparingSource: QuestionSource?
    private var responseGeneration = UUID()
    @Published var errorText: String?
    var panelError: String? { errorText ?? PushToTalk.shared.error }
    @Published var showsConversationList = false
    @Published var showsNotes = false
    /// 首次设置向导是否正显示（#8）。显示条件由实时状态推导，见
    /// `OnboardingReadiness`，不存「已完成引导」标记。
    @Published var showsOnboarding = false
    /// 当前是否没有任何可用模型路径（云端 Key / 本地 Ollama / 本地 CLI 全缺）。
    @Published private(set) var onboardingNeeded = false
    private var onboardingOfferedThisLaunch = false
    private var onboardingDismissedThisLaunch = false
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
    private var capturedScreenshotOnly = false

    /// 采集代次（#40/#41）：每次新的采集意图都会让它 +1 — 截图、正文采集、
    /// 停止、面板隐藏。captureShot/captureText 在每个 await 之后先核对代次，
    /// 过期就整份丢弃：不许把 packet、已发截图标记、过期标记写回成上一个
    /// 时代的状态。以前没有这层纪律，迟到的采集结果能把新截图换成旧的，
    /// 已取消的那次采集还会偷偷把 packet 填回去，让紧接着的发送跳过采集、
    /// 拿取消掉的画面作答。每个 bump 的地方要么自己接管 isCapturing，
    /// 要么当场把它复位。
    private var captureGeneration = 0

    /// 第一阶段：截图 + 网址标题。**必须**在浮窗出现之前跑完，否则浮窗会进画面。
    /// 只做这些，所以很快——读正文留给 `captureText()`，面板显示之后再说。
    func captureShot(screenshotOnly: Bool? = nil, attachScreenshot: Bool? = nil,
                     deliverQueuedSend: Bool = true) async {
        guard !isCapturing else { return }
        let screenshotOnly = screenshotOnly ?? (settings.responseMode == .quick)
        // Opening/refocusing Quick with the camera off must not capture either.
        if screenshotOnly && !(attachScreenshot ?? settings.sendScreenshot) { return }
        captureGeneration += 1
        let generation = captureGeneration
        isCapturing = true
        errorText = nil
        let (result, pending) = await ContextCapture.captureShot(excludingWindowIDs: ownWindowIDs,
                                                                 fallbackApp: targetApp,
                                                                 screenshotOnly: screenshotOnly)
        // 采集期间用户按了停止、藏了面板、或者更新的采集已经接管：这份结果
        // 属于上一个时代，整份丢弃，状态一概不碰（#41）。
        guard generation == captureGeneration else { return }
        if let bundleID = result.bundleID,
           bundleID != Bundle.main.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            targetApp = running
        }

        packet = result
        pendingText = pending
        capturedScreenshotOnly = screenshotOnly
        isCapturing = false
        // 截图是新的了，过期标记就该清掉。正文还欠着的话由 `pendingText` 记着，
        // 不要用 contextIsStale 兼职表示这件事——否则发送时会白截一次图。
        contextIsStale = false
        if pending == nil { dumpIfNeeded() }
        if deliverQueuedSend { sendIfQueuedDuringCapture() }
    }

    /// 第二阶段：读整页正文。
    ///
    /// 留到用户**按下发送**时才跑，而不是面板一出现就跑：没提问就不去读页面。
    ///
    /// 同一份上下文只读一次：`pendingText` 用掉就置空，接着追问同一个页面
    /// 不会再读一遍。换了标签页会标成过期，下次发送时重新采。
    func captureText() async {
        guard let pending = pendingText, var current = packet else { return }
        pendingText = nil
        captureGeneration += 1
        let generation = captureGeneration
        isCapturing = true
        await ContextCapture.captureText(pending, into: &current)
        // 同 captureShot：过期结果整份丢弃（#40）。isCapturing 由接管的那
        // 一方负责，这里不碰。
        guard generation == captureGeneration else { return }
        packet = current
        isCapturing = false
        contextIsStale = false
        dumpIfNeeded()
        sendIfQueuedDuringCapture()
    }

    /// 采集期间按下的回车，在采集收尾时补发。两个阶段都要接：手动刷新时回车可能落在读正文那段。
    private func sendIfQueuedDuringCapture() {
        guard sendsAfterCapture else { return }
        sendsAfterCapture = false
        send()
    }

    /// 两个阶段一次跑完。手动刷新走这条。
    func captureContext() async {
        await captureShot(screenshotOnly: false, deliverQueuedSend: false)
        if pendingText != nil {
            await captureText()
        } else {
            sendIfQueuedDuringCapture()
        }
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
        // 采集正文、准备发送、正在生成时都不要落地（#42）：跟随任务的这次
        // 结果可能迟到很久，它一旦判定「换页面了」就会把刚读好的正文清掉。
        // 头部信息丢一轮没关系，跟随定时器下一秒还会再来。
        guard !isCapturing, !isPreparingResponse, !isStreaming else { return }
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
        // 用户可能刚在设置窗口里填好 Key 回来：别让过期的标记在下次发送时又把向导弹出来。
        if onboardingNeeded { Task { await refreshOnboardingReadiness() } }
        guard contextIsStale, !isStreaming, !isCapturing else { return }
        Task { await captureShot() }
    }

    /// 面板每次打开都重新推导一次是否需要引导；满足条件且本轮启动还没
    /// 弹过、也没被用户跳过，才主动打开（#8 的打扰预算）。
    func panelDidShow() {
        Task {
            await refreshOnboardingReadiness()
            if OnboardingReadiness.shouldOfferOnPanelOpen(
                needsSetup: onboardingNeeded,
                alreadyOfferedThisLaunch: onboardingOfferedThisLaunch,
                dismissedThisLaunch: onboardingDismissedThisLaunch) {
                onboardingOfferedThisLaunch = true
                showsOnboarding = true
            }
        }
    }

    /// 从实时状态推导引导条件，只看当前选中的连接：云端有没有 Key、
    /// Ollama 在不在跑、选中的 Agent CLI 找不找得到（先认设置里填的路径）。
    func refreshOnboardingReadiness() async {
        let selection = ProviderConfig.selection(settings: settings)
        var signals = OnboardingSignals()
        switch selection.kind {
        case .openAICompatible:
            signals.selected = .cloud
            signals.hasCloudKey = KeychainStore.hasKey(for: settings.cloudProvider)
            signals.cloudBaseURLIsEmpty = settings.baseURL
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .ollama:
            signals.selected = .ollama
            if case .running = await OllamaSupport.probe(baseURL: settings.ollamaBaseURL) {
                signals.ollamaRunning = true
            }
        case .codexCLI:
            signals.selected = .cli
            switch selection.cliProvider {
            case .codex:      signals.selectedCLIFound = CodexCLIProvider.resolvePath(selection.cliPath) != nil
            case .agy:        signals.selectedCLIFound = AgyCLIProvider.resolvePath(selection.cliPath) != nil
            case .claudeCode: signals.selectedCLIFound = ClaudeCodeCLIProvider.resolvePath(selection.cliPath) != nil
            }
        }
        onboardingNeeded = OnboardingReadiness.needsSetup(signals)
    }

    /// 向导关掉之后：还没配置好就记下「这次启动跳过了」，面板打开路径
    /// 不再主动弹；同时重新推导一次，用户在向导里配好了就立刻消掉标记。
    func onboardingSheetDismissed() {
        if onboardingNeeded { onboardingDismissedThisLaunch = true }
        Task { await refreshOnboardingReadiness() }
    }

    func panelDidHide() {
        abandonPreparation()
        // 还在飞的采集就此作废（#41）：它回来时不许再写 packet。
        captureGeneration += 1
        isCapturing = false
        sendsAfterCapture = false
        // 下次打开回到当前对话，而不是停在一个收起的历史列表上。
        showsConversationList = false
        showsNotes = false
        pendingText = nil
        contextIsStale = true
        stopFollowingFrontWindow()
    }

    private var contextIsStale = false

    /// 距离上次采集过了多久，用于头部显示新鲜度。
    var contextAge: String { contextAge(relativeTo: Date()) }

    func contextAge(relativeTo now: Date) -> String {
        guard let packet else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(packet.capturedAt)))
        if seconds < 60 { return String(localized: "刚读取") }
        return String(localized: "\(seconds / 60) 分钟前")
    }

    // MARK: - 对话

    var activeConversation: Conversation? { store.active }

    /// 除「输入框里有东西」以外的发送前置条件。空状态里那几个建议自带问题文本，
    /// 不该被空输入框挡住，所以单独拆出来一份。
    var canStartQuestion: Bool {
        guard !isStreaming, !isPreparingResponse, !isCapturing else { return false }
        guard let conversation = store.active else { return store.canCreateNew }
        return !store.isAtTurnLimit(conversation)
    }

    var canSend: Bool {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return canStartQuestion
    }

    static var voiceDisabledMessage: String { String(localized: "请先在设置 → 音频中启用语音，再打开字幕。") }

    /// 错误行要不要给「打开设置」、开哪一页。按错误原文精确比对：
    /// 按「设置」二字去猜会把「系统设置 → 隐私」这类去 macOS 处理的错误也算进来。
    var errorSettingsTab: SettingsView.Tab? {
        guard let errorText else { return nil }
        if ProviderError.fixableInModelSettings.contains(where: { $0.errorDescription == errorText }) { return .model }
        if errorText == Self.voiceDisabledMessage { return .audio }
        return nil
    }

    var turnLimitMessage: String? {
        guard let conversation = store.active, store.isAtTurnLimit(conversation) else { return nil }
        return String(localized: "这个对话已经到 \(store.maxUserTurns) 轮上限。新建一个，或删掉一个旧对话腾位置。")
    }

    var conversationLimitMessage: String? {
        guard !store.canCreateNew else { return nil }
        let count = store.savedCount
        if count > store.maxConversations {
            return String(localized: "已经有 \(count) 个对话，超过了上限 \(store.maxConversations) 个。可以自己删几个，或者让它顶掉最久没用的那几个。")
        }
        return String(localized: "已经有 \(store.maxConversations) 个对话，到上限了。可以自己删一个，或者让它顶掉最久没用的那个。")
    }

    /// 满额时要被顶掉的对话的标题（通常一个；上限调低过时可能几个）。UI 拿它们去问用户。
    var evictionCandidateTitles: [String] { store.evictionCandidates.map(\.displayTitle) }

    @Published var confirmsEviction = false

    func toggleConversationList() {
        let showing = !showsConversationList
        showsConversationList = showing
        if showing, isCollapsed { setCollapsed(false) }
    }

    func newConversation() {
        // 当前这个还一句没问：直接用它，不再多建一个空对话占名额。
        if store.activeIsBlank {
            errorText = nil
            showsConversationList = false
            return
        }
        guard store.canCreateNew else {
            // 满了不是死路：把「要顶掉哪一个」摆出来让用户确认。
            showsConversationList = true
            if isCollapsed { setCollapsed(false) }
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
        // 删的正是在回答的那个：先停下，别让请求继续烧 token、药丸继续显示「生成中」。
        // 准备阶段还没开始流，那时在答的就是当前对话（准备期间切换对话会作废这次提问）。
        let answering = isStreaming ? answeringConversationID : (isPreparingResponse ? store.active?.id : nil)
        if let answering, answering == id {
            stopStreaming()
            responseGeneration = UUID()
            isStreaming = false
            answeringConversationID = nil
            streamTask = nil
        }
        store.delete(id)
    }

    // MARK: - 发送

    func send() {
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText, isStreaming || isPreparingResponse {
            // 以前这里静默返回，看起来像回车坏了。
            errorText = String(localized: "正在回答。等它结束，或按 ⌘. 停止后再发送。")
            return
        }
        if hasText, isCapturing {
            // 点回面板会补拍一张截图，通常不到一秒；这期间按的回车等它拍完就发，不吞掉。
            sendsAfterCapture = true
            return
        }
        send(question: input, mode: settings.responseMode)
    }

    /// 截图期间按了回车：拍完立即发送。藏面板、按停止时作废。
    private var sendsAfterCapture = false
    /// 正在流式回答的对话。用户可以边等边切去别的对话，所以不能拿当前对话代替。
    private var answeringConversationID: UUID?

    /// `mode` 只管这一次：常用指令可以带着自己的模式发，不改输入框旁边那个开关。
    /// `screenshot` 同理，nil 跟随相机开关；`.current` 用面板当前的连接。
    @discardableResult
    func send(question raw: String, mode: ResponseMode, screenshot: Bool? = nil,
              connection: QuestionConnection = .current, source: QuestionSource = .manual) -> Bool {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, canStartQuestion else { return false }
        // 一个模型都没连上时，先打开首次设置向导，而不是让这次提问
        // 撞上一句没有出路的配置错误（#8）。
        if onboardingNeeded && connection == .current { showsOnboarding = true; return false }
        guard let config = requestConfig(for: mode, connection: connection) else { return false }
        let conversationID = store.active?.id
        let sendScreenshot = screenshot ?? settings.sendScreenshot
        let generation = beginResponse(config)
        preparingSource = source
        preparationTask = Task {
            defer { endPreparation(generation) }
            guard !Task.isCancelled else { return }
            if mode == .quick {
                if sendScreenshot { await captureShot(screenshotOnly: true, attachScreenshot: true) }
            } else if packet == nil || contextIsStale || capturedScreenshotOnly || (sendScreenshot && packet?.hasScreenshot != true) {
                await captureShot(screenshotOnly: false)
            }
            guard !Task.isCancelled, responseGeneration == generation else { return }
            let skippedPage = !mode.capturesPageText
            if mode.capturesPageText { await captureText() }
            guard !Task.isCancelled, responseGeneration == generation else { return }
            guard store.active?.id == conversationID else { return cancelPreparation() }
            lastResponseSkippedPage = skippedPage
            performSend(question: question, config: config, sendScreenshot: sendScreenshot,
                        skippedPage: skippedPage, generation: generation, source: source)
        }
        return true
    }

    /// 常用指令：指令文字就是问题，输入框里写了的东西作为材料跟在后面。
    func run(_ command: QuickCommand) {
        if command.attachedSeconds > 0 { return ask(aboutCaptions: command) }
        guard canStartQuestion else {
            errorText = turnLimitMessage ?? String(localized: "请等待回答结束，或新建对话后重试。")
            return
        }
        send(question: command.question(withDraft: input), mode: command.mode ?? settings.responseMode,
             screenshot: command.includesScreenshot)
    }

    /// 带上对方最近几秒说的话来问。问答放在一个只在内存里的对话里：里面有别人的原话，
    /// 不写盘；关掉字幕时连同字幕一起丢掉。
    private func ask(aboutCaptions command: QuickCommand) {
        let captions = LiveCaptions.shared
        guard captions.isEnabled else {
            errorText = Self.voiceDisabledMessage
            return
        }
        guard captions.isRunning else {
            errorText = captions.isActive ? String(localized: "正在准备字幕…")
                : String(localized: "请先点面板上的字幕按钮，再运行这条指令。")
            return
        }
        guard !isStreaming, !isPreparingResponse, !isCapturing else {
            errorText = String(localized: "请等待回答结束后重试。")
            return
        }
        let draft = input
        Task {
            guard let words = await captions.recentText(seconds: TimeInterval(command.attachedSeconds)) else { return }
            guard !words.isEmpty else {
                errorText = String(localized: "还没听到对方说话。等字幕出现后再试。")
                return
            }
            sendCaptionQuestion(command, words: words, draft: draft, source: .captionCommand)
        }
    }

    func runAutomaticCaptionCommand(_ command: QuickCommand, words: String) {
        guard !words.isEmpty else { return }
        sendCaptionQuestion(command, words: words, draft: "", source: .automaticCaption)
    }

    private func sendCaptionQuestion(_ command: QuickCommand, words: String, draft: String, source: QuestionSource) {
        guard !isStreaming, !isPreparingResponse, !isCapturing else {
            if source == .captionCommand { errorText = String(localized: "请等待回答结束后重试。") }
            return
        }
        let mode = command.mode ?? .quick
        let connection: QuestionConnection = LiveCaptions.shared.asksThroughAPI ? .api : .current
        guard requestConfig(for: mode, connection: connection) != nil else { return }
        // 问满了一个就换一个新的，反正都不保存。
        if let existing = store.conversations.first(where: { store.isEphemeral($0.id) }),
           store.isAtTurnLimit(existing) {
            store.discardEphemeral()
        }
        store.activateEphemeral(title: String(localized: "会议提问（不保存）"))
        send(question: command.question(withCaptions: words, draft: draft), mode: mode,
             screenshot: command.includesScreenshot,
             connection: connection, source: source)
    }

    /// 最后一条回答能不能用深入重答：快速模式答的、已经答完、此刻没有别的请求在跑。
    func canReanswerDeeply(_ message: Message) -> Bool {
        message.role == .assistant && message.mode == .quick && !message.text.isEmpty
            && store.active?.messages.last?.id == message.id
            && !isStreaming && !isPreparingResponse && !isCapturing
    }

    /// 深入重答：问题留着，只把最后那条快速回答换成深入模式的，不多占一轮。
    ///
    /// 那一页还开着，就把正文读全、附上新截图再答——快速模式正是跳过了这一步。已经换到
    /// 别的页面，就用问题当时记下的上下文，不拿新页面去答旧问题。新回答一个字都没出来
    /// （出错、被停掉）时，原来那条回答会放回去。
    func reanswerDeeply(_ answerID: UUID) {
        guard let conversation = store.active, conversation.messages.count >= 2,
              let previous = conversation.messages.last, previous.id == answerID, canReanswerDeeply(previous),
              let question = conversation.messages.dropLast().last, question.role == .user,
              let config = requestConfig(for: .deep) else { return }
        let conversationID = conversation.id
        let sendScreenshot = settings.sendScreenshot
        let generation = beginResponse(config)
        preparationTask = Task {
            defer { endPreparation(generation) }
            if packet == nil || contextIsStale || capturedScreenshotOnly || (sendScreenshot && packet?.hasScreenshot != true) {
                await captureShot(screenshotOnly: false)
            }
            guard !Task.isCancelled, responseGeneration == generation else { return }
            let samePage = Self.isSamePage(packet, question.context)
            // 换了页面就不去读（更不去滚动）一个跟这个问题无关的页面。
            if samePage { await captureText() }
            guard !Task.isCancelled, responseGeneration == generation else { return }
            guard !isStreaming, store.active?.id == conversationID,
                  store.active?.messages.last?.id == answerID else { return cancelPreparation() }
            let attachedImages = ScreenCapturer.loadReferencedImages(in: question.text)
            var screenshot: Data?
            if samePage {
                let (snapshot, shot) = contextForSend(config: config, sendScreenshot: sendScreenshot)
                store.updateContext(snapshot, sentScreenshot: shot != nil || !attachedImages.isEmpty,
                                    messageID: question.id, in: conversationID)
                screenshot = shot
            }
            store.removeMessage(previous.id, from: conversationID)
            errorText = nil
            streamAnswer(in: conversationID, config: config, screenshot: screenshot,
                         attachedImages: attachedImages, skippedPage: false, generation: generation, restoring: previous)
        }
    }

    /// 同一个应用、同一个网址。不是浏览器时网址都是空的，就按应用算。
    nonisolated static func isSamePage(_ packet: ContextPacket?, _ context: ContextSnapshot?) -> Bool {
        guard let packet, let context, !packet.isExcluded else { return false }
        guard packet.bundleID == context.bundleID else { return false }
        if context.url == nil, let title = context.windowTitle, !title.isEmpty {
            return packet.windowTitle == title
        }
        return packet.url == context.url
    }

    /// 这一次要发出去的配置。面板的连接由 `ActiveModels` 决定，界面上显示的就是这一个；
    /// 字幕提问可以固定走 API 连接（CLI 每问一次都要起一个进程）。
    private func requestConfig(for mode: ResponseMode, connection: QuestionConnection = .current) -> ProviderConfig? {
        do {
            let config: ProviderConfig
            switch connection {
            case .current: config = ActiveModels(settings: settings, state: .shared).config(for: mode)
            case .api: config = ProviderConfig.api(settings: settings, mode: mode)
            }
            return try ProviderConfig.authorized(config, settings: settings)
        } catch {
            errorText = error.localizedDescription
            return nil
        }
    }

    /// 一次回答开始：记下代次与计时，展开面板。
    private func beginResponse(_ config: ProviderConfig) -> UUID {
        let generation = UUID()
        responseGeneration = generation
        lastResponseSkippedPage = false
        lastResponseTiming = ResponseTiming(mode: config.responseMode, model: config.model,
                                            startedAt: ProcessInfo.processInfo.systemUptime)
        errorText = nil
        isPreparingResponse = true
        // 在历史列表里按了回车：回答写进当前对话，列表不收起的话就看不见它。
        showsConversationList = false
        if isCollapsed { withAnimation(.easeOut(duration: 0.18)) { setCollapsed(false) } }
        return generation
    }

    private func endPreparation(_ generation: UUID) {
        guard responseGeneration == generation else { return }
        isPreparingResponse = false
        preparationTask = nil
        preparingSource = nil
    }

    private func cancelPreparation() {
        errorText = String(localized: "准备期间切换了对话，请重新发送。")
        lastResponseTiming?.finishedAt = ProcessInfo.processInfo.systemUptime
        lastResponseTiming?.outcome = "cancelled"
    }

    /// 按住说话的那段话最多这么长，连同输入框里已有的文字。
    static let speechDraftLimit = 12_000

    /// 把按住说话听到的话接在输入框已有文字后面。
    @discardableResult
    func stageSpeechDraft(_ text: String) -> Bool {
        guard let draft = speechDraft(appending: text) else { return false }
        input = draft
        isSpeechDraft = true
        speechDraftRevision += 1
        showsConversationList = false
        setCollapsed(false)
        return true
    }

    func submitSpeech(_ text: String) -> Bool {
        guard let draft = speechDraft(appending: text) else { return false }
        if send(question: draft, mode: settings.responseMode, source: .pushToTalk) {
            showsConversationList = false
            return true
        }
        return stageSpeechDraft(text)
    }

    private func speechDraft(appending text: String) -> String? {
        guard !text.isEmpty, !isStreaming, !isPreparingResponse else { return nil }
        let draft = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : input + "\n\n" + text
        return draft.count <= Self.speechDraftLimit ? draft : nil
    }

    private func performSend(question: String, config: ProviderConfig, sendScreenshot: Bool,
                             skippedPage: Bool, generation: UUID, source: QuestionSource) {
        // A previous asynchronous screen read may finish after another send started.
        guard !isStreaming else { return }
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
        if source != .automaticCaption { input = "" }

        let (snapshot, screenshot) = contextForSend(config: config, sendScreenshot: sendScreenshot)
        let attachedImages = source == .manual ? ScreenCapturer.loadReferencedImages(in: question) : []
        let hasImage = screenshot != nil || !attachedImages.isEmpty
        store.append(Message(role: .user, text: question, context: snapshot, sentScreenshot: hasImage),
                     to: conversationID)
        streamAnswer(in: conversationID, config: config, screenshot: screenshot,
                     attachedImages: attachedImages, skippedPage: skippedPage, generation: generation, restoring: nil)
    }

    /// 这一轮附哪张截图、问题记下哪份上下文。
    private func contextForSend(config: ProviderConfig, sendScreenshot: Bool) -> (ContextSnapshot?, Data?) {
        // Conversation history remains in PromptBuilder; stale screen context does not
        // belong to a camera-off Quick question.
        if config.responseMode == .quick && !sendScreenshot { return (nil, nil) }
        let screenshotToSend = (sendScreenshot && packet?.hasScreenshot == true) ? packet?.screenshotJPEG : nil
        var snapshot = packet?.isExcluded == true ? nil : packet?.snapshot()
        // History never stores screenshot bytes; report only the image actually sent this turn.
        snapshot?.hadScreenshot = screenshotToSend != nil
        return (snapshot, screenshotToSend)
    }

    /// 给对话里最后那个问题生成回答。`previous` 是被重答替换掉的旧回答：
    /// 新回答一个字都没出来时放回去，重答失败不会让人两头落空。
    private func streamAnswer(in conversationID: UUID, config: ProviderConfig, screenshot: Data?,
                              attachedImages: [Data] = [], skippedPage: Bool, generation: UUID, restoring previous: Message?) {
        let assistantMessage = Message(role: .assistant, text: "", mode: config.responseMode)
        store.append(assistantMessage, to: conversationID)

        let history = store.conversations.first { $0.id == conversationID }?.messages ?? []
        let payloadMessages = Array(history.dropLast())
        let payload = PromptBuilder.build(messages: payloadMessages, liveScreenshot: screenshot,
                                          attachedImages: attachedImages, mode: config.responseMode,
                                          skippedPageCapture: skippedPage)

        lastResponseTiming?.requestStartedAt = ProcessInfo.processInfo.systemUptime
        answeringConversationID = conversationID
        isStreaming = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            var counter = 0
            do {
                let provider = ProviderConfig.provider(for: config)
                for try await chunk in provider.stream(messages: payload, config: config) {
                    if Task.isCancelled || self.responseGeneration != generation { throw CancellationError() }
                    self.lastResponseTiming?.receive(chunk, at: ProcessInfo.processInfo.systemUptime)
                    accumulated += chunk
                    counter += 1
                    self.store.updateStreaming(text: accumulated, messageID: assistantMessage.id,
                                               in: conversationID, persistNow: false)
                    if counter % 40 == 0 { self.store.flush() }
                }
                try Task.checkCancellation()
                self.lastResponseTiming?.outcome = accumulated.isEmpty ? "empty" : "completed"
                if accumulated.isEmpty {
                    self.discard(assistantMessage.id, restoring: previous, in: conversationID)
                    self.errorText = String(localized: "模型没有返回任何内容。可以换个模型名再试。")
                } else {
                    self.store.updateStreaming(text: accumulated, messageID: assistantMessage.id,
                                               in: conversationID, persistNow: true)
                }
            } catch {
                guard self.responseGeneration == generation else { return }
                self.lastResponseTiming?.outcome = Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
                if accumulated.isEmpty {
                    self.discard(assistantMessage.id, restoring: previous, in: conversationID)
                } else {
                    let incomplete = accumulated + "\n\n" + String(localized: "（回答未完成：生成过程已中断。）")
                    self.store.updateStreaming(text: incomplete, messageID: assistantMessage.id,
                                               in: conversationID, persistNow: true)
                }
                if error is CancellationError { self.errorText = nil }
                else if let providerError = error as? ProviderError {
                    if case .cancelled = providerError { self.errorText = nil }
                    else { self.errorText = providerError.errorDescription }
                } else {
                    self.errorText = error.localizedDescription
                }
            }
            guard self.responseGeneration == generation else { return }
            self.lastResponseTiming?.finishedAt = ProcessInfo.processInfo.systemUptime
            self.isStreaming = false
            self.answeringConversationID = nil
            self.streamTask = nil
        }
    }

    /// 一个字都没出来的回答不留空壳；重答时把原来那条放回去。
    private func discard(_ answerID: UUID, restoring previous: Message?, in conversationID: UUID) {
        store.removeMessage(answerID, from: conversationID)
        if let previous { store.append(previous, to: conversationID) }
    }

    func cancelPendingVoiceQuestion() {
        guard let preparingSource, preparingSource != .manual, !isStreaming else { return }
        stopStreaming()
    }

    /// 还在准备（截图、读正文）、没开始流的提问就此作废；输入框里的问题原样留着。
    private func abandonPreparation() {
        guard isPreparingResponse, !isStreaming else { return }
        preparationTask?.cancel()
        preparationTask = nil
        preparingSource = nil
        responseGeneration = UUID()
        isPreparingResponse = false
        lastResponseTiming?.finishedAt = ProcessInfo.processInfo.systemUptime
        lastResponseTiming?.outcome = "cancelled"
    }

    func stopStreaming() {
        abandonPreparation()
        // 准备阶段里可能还有一次采集在飞（ContextCapture 的 continuation
        // 没有取消通道，叫不回来）：让它过期，回来时整份丢弃，别让它填回
        // packet、清掉过期标记，害下一次发送跳过采集（#41）。
        captureGeneration += 1
        isCapturing = false
        sendsAfterCapture = false
        streamTask?.cancel()
        store.flush()
    }

    // MARK: - 杂项

    func toggleScreenshot() {
        settings.sendScreenshot.toggle()
        if settings.sendScreenshot, packet?.hasScreenshot != true {
            contextIsStale = true
        }
    }

    func excludeCurrentApp() {
        guard let bundleID = packet?.bundleID, !bundleID.isEmpty else { return }
        let appName = packet?.appName ?? bundleID
        var list = settings.excludedBundleIDs
        guard !list.contains(bundleID) else { return }
        list.append(bundleID)
        settings.excludedBundleIDs = list
        captureGeneration += 1
        isCapturing = false
        pendingText = nil
        sendsAfterCapture = false
        packet = .excluded(appName: appName, bundleID: bundleID)
        refreshContext()
    }

    func resetAfterDataWipe() {
        preparationTask?.cancel()
        preparationTask = nil
        preparingSource = nil
        streamTask?.cancel()
        streamTask = nil
        responseGeneration = UUID()
        captureGeneration += 1
        isPreparingResponse = false
        isStreaming = false
        isCapturing = false
        answeringConversationID = nil
        sendsAfterCapture = false
        packet = nil
        pendingText = nil
        capturedScreenshotOnly = false
        contextIsStale = false
        targetApp = nil
        input = ""
        errorText = nil
        lastResponseTiming = nil
        lastResponseSkippedPage = false
        showsConversationList = false
        showsNotes = false
        confirmsEviction = false
        showsOnboarding = false
        onboardingOfferedThisLaunch = false
        onboardingDismissedThisLaunch = false
        Task { await refreshOnboardingReadiness() }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
