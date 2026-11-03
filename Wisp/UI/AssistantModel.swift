import AppKit
import Combine
import SwiftUI

@MainActor
final class AssistantModel: ObservableObject {
    static let shared = AssistantModel()

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
    private var responseGeneration = UUID()
    @Published var errorText: String?
    @Published var showsConversationList = false {
        didSet {
            // 删除确认 alert 是对话列表的子视图（ConversationListView 只在
            // 列表显示时存在）：列表一关，alert 就不存在，待删标记必须
            // 跟着清。否则标记永久非 nil、`hasModalPresented` 恒真，闲置
            // 自动收起会在本次运行内整体失效。关列表的路径有多条
            // （新建/顶替/选择/转写/语音草稿，后者还是非 UI 触发），收口
            // 在属性本身比逐条路径补清更不会漏。
            if !showsConversationList, pendingConversationDeletion != nil {
                pendingConversationDeletion = nil
            }
        }
    }
    @Published var showsNotes = false
    /// 首次设置向导窗口是否正呈现（#8；UX 改造第 3 项起是独立窗口，
    /// 不是面板的 sheet）。这只是窗口的镜像状态：呈现/关闭都走下面的
    /// `presentOnboarding()` / `onboardingWindowClosed()`，实际窗口由
    /// `OnboardingWindowController` 观察这个标记来开/关。显示条件仍由
    /// 实时状态推导，见 `OnboardingReadiness`，不存「已完成引导」标记。
    @Published var showsOnboarding = false
    /// 就绪判断的缓存：当前选中的连接到底能不能用（没有 Key / Ollama 没在跑 /
    /// 选中的 CLI 找不到）。启动时算一次、设置变更时防抖重算（见 init 与
    /// `refreshOnboardingReadiness()`），所以读它不需要做任何 I/O——展示
    /// 路径（panelDidShow、send 拦截）只读这份缓存。
    @Published private(set) var onboardingNeeded = false
    private var onboardingOfferedThisLaunch = false
    private var onboardingDismissedThisLaunch = false
    /// 展开区显示的是这次录到的转写原文，而不是 AI 回答。只是视图切换，不影响录音。
    @Published var showsTranscript = false
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

        // 就绪判断前置缓存（UX 改造第 2 项）：设置一变就防抖重算一次，
        // 展示路径只读缓存。objectWillChange 在新值真正写入之前就会发，
        // 不能在回调里同步读设置；防抖的这段延迟同时把「等新值落定」
        // 和「连续改设置只算一次」都办了。
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.scheduleReadinessRefresh() }
        }

        // Key 的写路径（填 Key 保存、清除 Key、CLI Key 保存、恢复出厂）全是
        // 纯 KeychainStore 调用，不经过 AppSettings，上面那条订阅对就绪判断
        // 最重要的输入是瞎的。KeychainStore 写成功后会发
        // `.wispKeychainDidChange`，这里订上，走同一条防抖重算通道。
        keychainObserver = NotificationCenter.default.publisher(for: .wispKeychainDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in self?.scheduleReadinessRefresh() }
            }
    }

    private var settingsObserver: AnyCancellable?
    private var keychainObserver: AnyCancellable?
    private var readinessRefreshTask: Task<Void, Never>?

    private func scheduleReadinessRefresh() {
        readinessRefreshTask?.cancel()
        readinessRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshOnboardingReadiness()
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

    /// 第一阶段：截图 + 网址标题。呈现不必等它跑完（UX 改造第 2 项）：
    /// show() 先把面板亮出来，截图随后并发补上——浮窗不进画面靠的是截图
    /// 按排除名单排除自家窗口，不靠「先截图后显示」的时序兜底
    /// （与 ContextCapture 侧的注释同一口径）。只做这些，所以很快——
    /// 读正文留给 `captureText()`，发送时再说。
    func captureShot(screenshotOnly: Bool? = nil, attachScreenshot: Bool? = nil) async {
        guard !isCapturing else { return }
        let screenshotOnly = screenshotOnly ?? (settings.responseMode == .quick)
        // Opening/refocusing Quick with the camera off must not capture either.
        if screenshotOnly && !(attachScreenshot ?? settings.sendScreenshot) { return }
        captureGeneration += 1
        let generation = captureGeneration
        isCapturing = true
        errorText = nil
        // 排除名单在采集这一刻组装，不用 show() 时刻写下的快照
        // （`ownWindowIDs`）：向导窗口能独立于 show() 出现——甚至就是
        // 同一轮 show 的 offer 打开的，快照里还没有它——整屏采集会把
        // 开着的向导（连同里面的 Key 输入框）截进去。它此刻不可见时
        // windowID 为 nil、自然不并入。captureText 只读正文、不截图，
        // 不吃这份名单，无需同样处理。
        var excludedWindowIDs = ownWindowIDs
        if let onboardingID = OnboardingWindowController.shared.windowID,
           !excludedWindowIDs.contains(onboardingID) {
            excludedWindowIDs.append(onboardingID)
        }
        let (result, pending) = await ContextCapture.captureShot(excludingWindowIDs: excludedWindowIDs,
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

        // 画面和网址都没变的话，沿用上一份的「已发过截图」标记，别重复付图片的钱。
        let hash = result.screenshotJPEG?.hashValue
        let unchanged = (hash != nil && hash == lastScreenshotHash && result.url == lastURL)
        if !unchanged { lastSentPacketID = nil }
        lastScreenshotHash = hash
        lastURL = result.url

        packet = result
        pendingText = pending
        capturedScreenshotOnly = screenshotOnly
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
    }

    /// 两个阶段一次跑完。手动刷新走这条。
    func captureContext() async {
        await captureShot(screenshotOnly: false)
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

    /// 面板打开时要不要主动给向导，只读缓存做判定（#8 的打扰预算）：
    /// 本轮启动还没弹过、也没被用户跳过，才主动打开。展示路径不做 I/O——
    /// readiness 是前置缓存（启动时算、设置变更时防抖重算）；这里另起一个
    /// 不阻塞的后台刷新让缓存向真实状态收敛（比如用户刚在别处删了 Key），
    /// 但这次 offer 不等它：判定慢半拍最多是下次打开面板时再给，绝不能
    /// 让向导在面板出现之后才迟到滑出。
    func panelDidShow() {
        if OnboardingReadiness.shouldOfferOnPanelOpen(
            needsSetup: onboardingNeeded,
            alreadyOfferedThisLaunch: onboardingOfferedThisLaunch,
            dismissedThisLaunch: onboardingDismissedThisLaunch) {
            onboardingOfferedThisLaunch = true
            presentOnboarding()
        }
        Task { await refreshOnboardingReadiness() }
    }

    /// readiness 刷新的代次（单调递增）。四个触发点（启动、防抖重算、
    /// panelDidShow 后台收敛、向导关闭）发起的刷新可以并发在飞，Ollama
    /// probe 最长要 4 秒——先发起的那次完全可能后落地。没有序列化时，
    /// 它落地时写回的是旧快照派生出的值，能把更新的缓存覆盖回去。
    /// 规则：开始时领一个代次，写缓存前校验仍是最新，不是就丢弃。
    private var readinessGeneration = 0

    /// 从实时状态推导引导条件并写进 `onboardingNeeded` 缓存，只看当前
    /// 选中的连接：云端有没有 Key、Ollama 在不在跑、选中的 Agent CLI
    /// 找不找得到（先认设置里填的路径）。触发点：启动时、设置变更防抖、
    /// panelDidShow 的后台收敛、向导关闭时——都不在展示路径的临界点上。
    func refreshOnboardingReadiness() async {
        readinessGeneration += 1
        let generation = readinessGeneration
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
        // 期间有更新的刷新发起了，这份就是旧快照：整份丢弃，别写回缓存。
        guard generation == readinessGeneration else { return }
        onboardingNeeded = OnboardingReadiness.needsSetup(signals)
    }

    /// 打开向导窗口。所有入口都走这里：首启自动开窗（见
    /// `presentOnboardingIfFirstRun()`）、面板打开时的 offer、提问拦截、
    /// 设置里「重新运行首次设置」。窗口本体由
    /// `OnboardingWindowController` 观察 `showsOnboarding` 呈现；
    /// 已经开着时再调一次只是把窗口带到前面。
    func presentOnboarding() {
        showsOnboarding = true
    }

    /// 向导里点「开始使用 Wisp」且就绪复查通过：完成交接——关窗，
    /// 然后把面板亮出来，用户落点就是提问输入框（面板的
    /// panelDidShow/focusRequest 既有路径负责聚焦，不另造）。关窗的
    /// 记账由 `onboardingWindowClosed()` 在窗口消失时统一跑，这条路径
    /// 不重复记。
    func completeOnboarding() {
        showsOnboarding = false
        PanelController.shared.show()
    }

    /// 向导窗口真正消失时由 `OnboardingWindowController` 回调（用户点
    /// 关闭按钮、或程序置 `showsOnboarding = false` 关窗，都收口到
    /// 这里）：还没配置好就记下「这次启动跳过了」，面板打开路径不再
    /// 主动弹；同时重新推导一次，用户在向导里配好了就立刻消掉标记。
    /// 语义与 sheet 时代的 onDismiss 完全一致，只是宿主换了。
    func onboardingWindowClosed() {
        if onboardingNeeded { onboardingDismissedThisLaunch = true }
        Task { await refreshOnboardingReadiness() }
    }

    /// 首启自动开窗的判定：由 AppDelegate 在首轮 readiness 刷新落地
    /// 之后调用一次——调用方保证此刻读的 `onboardingNeeded` 是算过的
    /// 值，不是初始 false。需要配置且从未展示过才开窗；展示记账
    /// 在控制器 `present()` 被调用时落盘（见
    /// `AppSettings.hasShownFirstRunOnboarding`），这里只读不写。
    func presentOnboardingIfFirstRun() {
        guard onboardingNeeded, !settings.hasShownFirstRunOnboarding else { return }
        presentOnboarding()
    }

    func panelDidHide() {
        // 还在飞的采集就此作废（#41）：它回来时不许再写 packet。
        captureGeneration += 1
        isCapturing = false
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

    /// 对话列表里待确认删除的那一个。放在模型上而不是列表视图的
    /// @State 里，是为了让模态护栏（`hasModalPresented`）看得见它：
    /// 这个 alert 同样挂在面板上，不能被面板的闲置收起连带带走。
    @Published var pendingConversationDeletion: Conversation?

    /// 此刻是否有「人正办事办到一半」的界面开着：面板自家的腾位确认、
    /// 删对话确认，外加首次向导窗口。唯一用途是 idle 豁免——
    /// `PanelController.isIdle` 问它，任一为真，面板就不得被闲置计时
    /// 收走（向导开着时用户多半正切去浏览器拿 Key，回来发现面板没了
    /// 和 sheet 时代是同一种事故；向导窗口本身是普通窗口，不吃面板的
    /// idle 逻辑，不需要谁保护它）。
    ///
    /// 它不再兼任 hide()/Esc 的清理判据（第 3 项检查裁定，修订第 1 项
    /// 在新宿主下的语义）：sheet 时代向导长在面板上，「藏面板 = 关
    /// 向导」是宿主关系决定的；窗口化后两者生命周期解耦，hide() 与
    /// 面板 onCancel 只清理面板自家的两个模态（它们挂在面板上、不先
    /// 关就会被 orderOut 悬空），向导只进这份 idle 豁免名单、不进
    /// 清理名单——藏面板或按 Esc 时连带关掉一个独立窗口，用户看不见
    /// 因果。向导的关闭与记账只走它自己的路径。
    /// 以后加新界面：挂在面板上的，idle 豁免与 hide/onCancel 清理两处
    /// 都要加；独立窗口只加这里。
    var hasModalPresented: Bool {
        showsOnboarding || confirmsEviction || pendingConversationDeletion != nil
    }

    func toggleConversationList() {
        let showing = !showsConversationList
        showsConversationList = showing
        if showing {
            showsTranscript = false
            if isCollapsed { setCollapsed(false) }
        }
    }

    func newConversation() {
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
        store.delete(id)
    }

    // MARK: - 发送

    func send() {
        send(question: input, mode: settings.responseMode)
    }

    /// `mode` 只管这一次：常用指令可以带着自己的模式发，不改输入框旁边那个开关。
    func send(question raw: String, mode: ResponseMode) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, canStartQuestion else { return }
        // 一个模型都没连上时，先打开首次设置向导，而不是让这次提问
        // 撞上一句没有出路的配置错误（#8）。onboardingNeeded 是前置缓存
        // （启动/设置变更时算好），这里只读，不现算、不做 I/O。
        if onboardingNeeded { presentOnboarding(); return }
        guard let config = requestConfig(for: mode) else { return }
        let conversationID = store.active?.id
        let sendScreenshot = settings.sendScreenshot
        let generation = beginResponse(config)
        preparationTask = Task {
            defer { endPreparation(generation) }
            if mode == .quick {
                if sendScreenshot { await captureShot(screenshotOnly: true, attachScreenshot: true) }
            } else if packet == nil || contextIsStale || capturedScreenshotOnly {
                await captureShot(screenshotOnly: false)
            }
            guard !Task.isCancelled, responseGeneration == generation else { return }
            let skippedPage = !mode.capturesPageText
            if mode.capturesPageText { await captureText() }
            guard !Task.isCancelled, responseGeneration == generation else { return }
            guard store.active?.id == conversationID else { return cancelPreparation() }
            lastResponseSkippedPage = skippedPage
            performSend(question: question, config: config, sendScreenshot: sendScreenshot,
                        skippedPage: skippedPage, generation: generation)
        }
    }

    /// 常用指令：指令文字就是问题，输入框里写了的东西作为材料跟在后面。
    func run(_ command: QuickCommand) {
        guard canStartQuestion else {
            errorText = turnLimitMessage ?? String(localized: "请等待回答结束，或新建对话后重试。")
            return
        }
        send(question: command.question(withDraft: input), mode: command.mode ?? settings.responseMode)
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
            if packet == nil || contextIsStale || capturedScreenshotOnly {
                await captureShot(screenshotOnly: false)
            }
            guard !Task.isCancelled, responseGeneration == generation else { return }
            let samePage = Self.isSamePage(packet, question.context)
            // 换了页面就不去读（更不去滚动）一个跟这个问题无关的页面。
            if samePage { await captureText() }
            guard !Task.isCancelled, responseGeneration == generation else { return }
            guard !isStreaming, store.active?.id == conversationID,
                  store.active?.messages.last?.id == answerID else { return cancelPreparation() }
            var screenshot: Data?
            if samePage {
                let (snapshot, shot) = contextForSend(config: config, sendScreenshot: sendScreenshot)
                store.updateContext(snapshot, sentScreenshot: shot != nil, messageID: question.id, in: conversationID)
                screenshot = shot
            }
            store.removeMessage(previous.id, from: conversationID)
            errorText = nil
            streamAnswer(in: conversationID, config: config, screenshot: screenshot,
                         skippedPage: false, generation: generation, restoring: previous)
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

    /// 这一次要发出去的配置。模型由 `ActiveModels` 决定，界面上显示的就是这一个。
    private func requestConfig(for mode: ResponseMode) -> ProviderConfig? {
        do {
            return try ProviderConfig.authorized(ActiveModels(settings: settings, state: .shared).config(for: mode),
                                                 settings: settings)
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
        if isCollapsed { withAnimation(.easeOut(duration: 0.18)) { setCollapsed(false) } }
        return generation
    }

    private func endPreparation(_ generation: UUID) {
        guard responseGeneration == generation else { return }
        isPreparingResponse = false
        preparationTask = nil
    }

    private func cancelPreparation() {
        errorText = String(localized: "准备期间切换了对话，请重新发送。")
        lastResponseTiming?.finishedAt = ProcessInfo.processInfo.systemUptime
        lastResponseTiming?.outcome = "cancelled"
    }

    func toggleTranscriptView() {
        showsTranscript.toggle()
        showsConversationList = false
        if showsTranscript { setCollapsed(false) }
    }

    /// 把转写放进输入框。用户自己写了字就用他的问题，一个字没写才用 `fallbackQuestion`
    /// ——一键分析总得带着问题过去，否则模型只收到一段没有指令的会议记录。
    @discardableResult
    func stageSpeechDraft(_ text: String, fallbackQuestion: String? = nil) -> Bool {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = typed.isEmpty ? (fallbackQuestion ?? "") : input
        guard !text.isEmpty, !isStreaming, !isPreparingResponse,
              let draft = ListeningTranscript.appendingToDraft(text, existing: existing) else { return false }
        input = draft
        isSpeechDraft = true
        speechDraftRevision += 1
        showsTranscript = false
        showsConversationList = false
        setCollapsed(false)
        return true
    }

    private func performSend(question: String, config: ProviderConfig, sendScreenshot: Bool,
                             skippedPage: Bool, generation: UUID) {
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
        input = ""

        let (snapshot, screenshot) = contextForSend(config: config, sendScreenshot: sendScreenshot)
        store.append(Message(role: .user, text: question, context: snapshot, sentScreenshot: screenshot != nil),
                     to: conversationID)
        streamAnswer(in: conversationID, config: config, screenshot: screenshot,
                     skippedPage: skippedPage, generation: generation, restoring: nil)
    }

    /// 这一轮附哪张截图、问题记下哪份上下文。
    private func contextForSend(config: ProviderConfig, sendScreenshot: Bool) -> (ContextSnapshot?, Data?) {
        // Conversation history remains in PromptBuilder; stale screen context does not
        // belong to a camera-off Quick question.
        if config.responseMode == .quick && !sendScreenshot { return (nil, nil) }
        var screenshotToSend: Data?
        if sendScreenshot, let packet, packet.hasScreenshot,
           (config.responseMode != .standard || lastSentPacketID != packet.id) {
            screenshotToSend = packet.screenshotJPEG
            lastSentPacketID = packet.id
        }
        var snapshot = packet?.isExcluded == true ? nil : packet?.snapshot()
        // History never stores screenshot bytes; report only the image actually sent this turn.
        snapshot?.hadScreenshot = screenshotToSend != nil
        return (snapshot, screenshotToSend)
    }

    /// 给对话里最后那个问题生成回答。`previous` 是被重答替换掉的旧回答：
    /// 新回答一个字都没出来时放回去，重答失败不会让人两头落空。
    private func streamAnswer(in conversationID: UUID, config: ProviderConfig, screenshot: Data?,
                              skippedPage: Bool, generation: UUID, restoring previous: Message?) {
        let assistantMessage = Message(role: .assistant, text: "", mode: config.responseMode)
        store.append(assistantMessage, to: conversationID)

        let history = store.conversations.first { $0.id == conversationID }?.messages ?? []
        let payloadMessages = Array(history.dropLast())
        let payload = PromptBuilder.build(messages: payloadMessages, liveScreenshot: screenshot,
                                          mode: config.responseMode, skippedPageCapture: skippedPage)

        lastResponseTiming?.requestStartedAt = ProcessInfo.processInfo.systemUptime
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
            self.streamTask = nil
        }
    }

    /// 一个字都没出来的回答不留空壳；重答时把原来那条放回去。
    private func discard(_ answerID: UUID, restoring previous: Message?, in conversationID: UUID) {
        store.removeMessage(answerID, from: conversationID)
        if let previous { store.append(previous, to: conversationID) }
    }

    func stopStreaming() {
        if isPreparingResponse, !isStreaming {
            preparationTask?.cancel()
            responseGeneration = UUID()
            isPreparingResponse = false
            lastResponseTiming?.finishedAt = ProcessInfo.processInfo.systemUptime
            lastResponseTiming?.outcome = "cancelled"
        }
        // 准备阶段里可能还有一次采集在飞（ContextCapture 的 continuation
        // 没有取消通道，叫不回来）：让它过期，回来时整份丢弃，别让它填回
        // packet、清掉过期标记，害下一次发送跳过采集（#41）。
        captureGeneration += 1
        isCapturing = false
        streamTask?.cancel()
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
