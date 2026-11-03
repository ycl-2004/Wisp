import AppKit
import SwiftUI

/// 无边框、半透明、贴屏幕上方的悬浮面板。
/// 面板靠窗口 ID 从截图里排除自己（见 `show()`），所以呈现不必等截图跑完。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var panel: NSPanel?
    private var presentationGeneration = UUID()

    static let width: CGFloat = 620
    static let expandedHeight: CGFloat = 560
    static let collapsedHeight: CGFloat = 110
    /// AppKit's resizable style installs its own frame cursors around the window.
    /// Resizing is handled by `PanelResizeOverlay`, so keep the system style non-resizable.
    static let panelStyleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    private static let minimumCollapsedHeight: CGFloat = 110
    private static let legacyCollapsedHeight: CGFloat = 180
    private static let maximumCollapsedHeight: CGFloat = 240
    private static let minimumExpandedHeight: CGFloat = 280
    private static let maximumExpandedHeight: CGFloat = 1000

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - 显隐

    func toggle() {
        isVisible ? hide() : show()
    }

    /// `then` runs once this show's capture has finished — the panel itself is already
    /// on screen by then. The callback still waits for the capture because a quick
    /// command started from a shortcut goes through run() → send(), and
    /// `canStartQuestion` refuses to start while a capture is in flight.
    func show(then: (@MainActor () -> Void)? = nil) {
        presentationGeneration = UUID()
        let generation = presentationGeneration
        let model = AssistantModel.shared
        // 必须在切换焦点之前记住目标应用。
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            model.targetApp = front
        }
        let panel = ensurePanel()
        var excluded = [CGWindowID(panel.windowNumber)]
        if let islandID = IslandController.shared.windowID { excluded.append(islandID) }
        // 向导窗口里有 Key 输入框，它开着时整屏采集同样要把它排除。
        if let onboardingID = OnboardingWindowController.shared.windowID { excluded.append(onboardingID) }
        model.ownWindowIDs = excluded
        IslandController.shared.setDimmed(true)

        // 每次唤起都回到输入尺寸，发送时再自动展开。
        model.setCollapsedSilently(true)
        isPointerInside = false

        // 呈现不再等截图（UX 改造第 2 项）：先定位、亮出来、成为 key window，
        // 用户立刻就能打字。浮窗不会进自己的截图——截图按 ownWindowIDs
        // 排除自家窗口（上面刚写进 model），不靠「先截图后显示」的时序兜底。
        // 截图转到下面的并发 Task 里补，落地前 captureShot 内部有代次校验：
        // 藏面板（panelDidHide 自增代次）或新一轮采集都会让在飞的这份作废。
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        // 永不激活：面板样式本来就是 .nonactivatingPanel，成为 key window 已
        // 足够收键盘输入，不需要把整个 App 激活、把用户从当前应用里拽走。
        // 这是有意决定，靠真机验证门兜底（中文 IME 组字、Cmd+V/Z/A/X、听写、
        // hide 后焦点交还）。若验证不过，回退方式是把
        // `NSApp.activate(ignoringOtherApps: true)` 加回此处——在 orderFront
        // 的同一时刻立即执行；绝不能改成延迟激活：延迟会在用户组字中途
        // 切换激活状态，是所有时机里最差的一个。
        // 已知交叉项：LocalCursorController 在 localCursor +
        // hideFromScreenCapture 开启时有自己的「未激活则点击激活」分支
        // （prepare(for:) 里对 sharingType == .none 窗口的点击会 activate）；
        // 以前 show() 每次都激活，这个分支在面板路径上轮不到触发，现在
        // 永不激活了，点面板会实际触发它、把 App 整体激活。是否给面板
        // 窗口豁免待真机验证门 1c 裁定，这里只记录，不预先改它的行为。
        NotificationCenter.default.post(name: .wispPanelDidShow, object: nil)
        refreshIdleTimer()
        // 面板开着期间让头部跟着当前窗口走（只更新应用名和链接）。
        model.startFollowingFrontWindow()
        Task {
            await model.captureShot()
            // 藏面板或更新的一次唤起之后才跑完的这一轮，不许再触发它的回调。
            guard self.presentationGeneration == generation else { return }
            // 正文和滑动采集**不**在这里跑：留到用户按下发送时。
            // 面板一出现就翻动页面，用户问题都还没想好，观感是电脑自作主张。
            then?()
        }
    }

    func hide() {
        presentationGeneration = UUID()
        ListeningModel.shared.stop()
        PushToTalk.shared.cancel()
        guard let panel else { return }
        cancelIdleTimer()
        saveFrame(panel)
        flushFrameSave()
        // 先让模态走正常关闭路径再藏面板：直接 orderOut 的话 alert 只是
        // 跟着面板一起不见、关不掉，待删标记会悬空。showsOnboarding 同
        // 理：置 false 后向导窗口由它自己的控制器关闭并走
        // onboardingWindowClosed() 记账，标记不悬空、「这次启动跳过了」
        // 也记得上账（UX 改造第 3 项后向导是独立窗口，机理从 sheet 的
        // onDismiss 换成了控制器收口，语义不变）。
        if AssistantModel.shared.hasModalPresented {
            AssistantModel.shared.showsOnboarding = false
            AssistantModel.shared.confirmsEviction = false
            AssistantModel.shared.pendingConversationDeletion = nil
        }
        panel.orderOut(nil)
        isPointerInside = false
        broadcastActivity()
        IslandController.shared.setDimmed(false)
        AssistantModel.shared.panelDidHide()
    }

    // MARK: - 失焦自动收起

    /// 鼠标是否停在面板上。悬停也算「还在用」，不计时。
    private var isPointerInside = false
    private var idleTimer: Timer?
    private var frameSaveTimer: Timer?
    private var pendingFrameString: String?

    func setPointerInside(_ inside: Bool) {
        guard isPointerInside != inside else { return }
        isPointerInside = inside
        refreshIdleTimer()
        broadcastActivity()
    }

    /// 面板此刻算不算「正在用」：拿着焦点，或者鼠标停在上面。
    /// 半透明只在闲置时生效，这两种情况下要先变实。
    var isActive: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.isKeyWindow || isPointerInside
    }

    /// 悬停和焦点分别由 SwiftUI 和窗口回调发现，谁变了都从这里通知视图。
    private func broadcastActivity() {
        NotificationCenter.default.post(name: .wispPanelActivityChanged, object: nil,
                                        userInfo: ["active": isActive])
    }

    /// 焦点、悬停、生成状态、设置里的秒数，任何一样变了都重新决定要不要计时。
    func refreshIdleTimer() {
        guard let panel, panel.isVisible else { cancelIdleTimer(); return }
        guard isIdle(panel) else { cancelIdleTimer(); return }

        // 已经在倒计时就让它继续走，别重置——否则鼠标扫过窗口边缘会一直续命。
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: AppSettings.shared.idleDismissSeconds,
                                         repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.idleTimer = nil
                self.hideIfStillIdle()
            }
        }
    }

    private func cancelIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// 倒计时这几秒里状态可能已经变了，真收之前再确认一次。
    private func hideIfStillIdle() {
        guard let panel, panel.isVisible, isIdle(panel) else { refreshIdleTimer(); return }
        hide()
    }

    /// 这几种情况都说明人还在用它：设置关了、面板有焦点（在打字或点它）、
    /// 鼠标停在上面、回答正在生成、正在录音或按住说话、正在采集。任何一条成立都不能收。
    /// 模态（设置向导、删除确认）盖着时同理：那正是用户办事办到一半的时刻
    /// （比如切去浏览器拿 API Key），计时到了也不能连模态一起把面板收走。
    ///
    /// 还有一条：用户正待在**要读的那个应用**里。在 Chrome 里翻标签页找资料
    /// 恰恰说明他在准备提问，这时候把面板收掉最讨嫌。只有他跑去第三个
    /// 不相干的应用、也就是真的走开了，倒计时才有意义。
    private func isIdle(_ panel: NSPanel) -> Bool {
        AppSettings.shared.idleDismissSeconds > 0
            && !panel.isKeyWindow
            && !isPointerInside
            && !AssistantModel.shared.isStreaming
            && !ListeningModel.shared.isActive
            && !PushToTalk.shared.isActive
            && !AssistantModel.shared.isCapturing
            && !isWorkingInCapturedApp
            && !AssistantModel.shared.hasModalPresented
    }

    /// 前台应用就是这份上下文读到的那个应用吗？
    ///
    /// 比的是 `packet.bundleID`（真正采集过的那个），不是 `targetApp`——后者会跟着
    /// 用户切到的任何应用变，拿它来判断的话这里永远为真，等于把空闲收起废掉了。
    /// 用 packet 才是想要的语义：在 Chrome 里翻标签页找资料不收，跑去 Slack 才收。
    private var isWorkingInCapturedApp: Bool {
        guard let captured = AssistantModel.shared.packet?.bundleID,
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return false }
        return front == captured
    }

    /// 收起／展开：只改高度，宽度和左上角位置不动。
    func setCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard panel != nil else { return }
        let target = collapsed ? storedCollapsedHeight : storedExpandedHeight
        setPanelHeight(target, animated: animated)
    }

    /// Keep the collapsed panel tight to the composer as a multiline question grows.
    /// The stored value is updated even while expanded so the next show starts at the
    /// one-line height after the draft is cleared.
    func updateCollapsedHeight(forInputHeight inputHeight: CGFloat, animated: Bool = true) {
        let target = Self.collapsedHeight(forInputHeight: inputHeight)
        storedCollapsedHeight = target
        guard AssistantModel.shared.isCollapsed else { return }
        setPanelHeight(target, animated: animated)
    }

    /// The collapsed height follows the measured composer height one point for one,
    /// while keeping a predictable one-line minimum and a bounded multiline maximum.
    static func collapsedHeight(forInputHeight inputHeight: CGFloat) -> CGFloat {
        let delta = max(0, inputHeight - ChatInput.defaultHeight)
        return min(max(Self.collapsedHeight + delta, Self.minimumCollapsedHeight),
                   Self.maximumCollapsedHeight)
    }

    private func setPanelHeight(_ target: CGFloat, animated: Bool) {
        guard let panel else { return }
        var frame = panel.frame
        guard abs(frame.height - target) > 0.5 else { return }
        // 底边不动，向上展开。输入框位置保持稳定，内容从上方长出来。
        frame.size.height = target
        if let screen = panel.screen ?? ScreenGeometry.activeScreen {
            frame = ScreenGeometry.clamp(frame, on: screen)
        }
        frameAnimationGeneration += 1
        let generation = frameAnimationGeneration
        isApplyingProgrammaticFrame = true
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.frameAnimationGeneration == generation else { return }
                    self.isApplyingProgrammaticFrame = false
                }
            }
        } else {
            panel.setFrame(frame, display: true)
            isApplyingProgrammaticFrame = false
        }
    }

    /// 程序动画期间不保存中间值；用户手动调整的紧凑／展开高度各记一份。
    private var storedCollapsedHeight: CGFloat = PanelController.collapsedHeight
    private var storedExpandedHeight: CGFloat = PanelController.expandedHeight
    private var storedWidth: CGFloat = PanelController.width
    private var storedOrigin: NSPoint?
    private var isApplyingProgrammaticFrame = false
    private var frameAnimationGeneration = 0

    // MARK: - 构造

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.collapsedHeight),
            styleMask: Self.panelStyleMask,
            backing: .buffered,
            defer: false
        )
        panel.onCancel = {
            // Esc 先退最上面一层：有模态盖着就只关模态，面板留着；
            // 没有模态才轮到把面板整个藏掉。showsOnboarding 现在是向导
            // 窗口的镜像：置 false 即关窗并由控制器记账（第 3 项）。
            if AssistantModel.shared.hasModalPresented {
                AssistantModel.shared.showsOnboarding = false
                AssistantModel.shared.confirmsEviction = false
                AssistantModel.shared.pendingConversationDeletion = nil
            } else {
                PanelController.shared.hide()
            }
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.minSize = NSSize(width: 380, height: Self.minimumCollapsedHeight)
        panel.maxSize = NSSize(width: 2400, height: Self.maximumExpandedHeight)
        panel.delegate = self
        ScreenPrivacy.apply(to: panel)

        let root = ChatView()
            .environmentObject(AssistantModel.shared)
            .environmentObject(ConversationStore.shared)
        let hosting = Self.makePanelContentView(root)
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    static func makePanelContentView<Content: View>(_ root: Content) -> NSView {
        let container = NSView()
        let hosting = NSHostingView(rootView: root)
        // AppKit owns resizing. Content-derived bounds otherwise grow/lock the window.
        // https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = DS.windowCorner
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        // Keep NSHostingView out of NSWindow.contentView so SwiftUI cannot override
        // the borderless panel's AppKit min/max sizes during root-view changes.
        container.addSubview(hosting)
        // 缩放层盖在内容之上，只吃边缘那几个点；其余位置事件照常落到 SwiftUI。
        let resize = PanelResizeOverlay(frame: container.bounds)
        resize.autoresizingMask = [.width, .height]
        container.addSubview(resize)
        return container
    }

    private func position(_ panel: NSPanel) {
        guard let screen = ScreenGeometry.activeScreen else { return }
        let collapsed = AssistantModel.shared.isCollapsed
        let height = collapsed ? storedCollapsedHeight : storedExpandedHeight
        let size = NSSize(width: storedWidth, height: height)

        // 底边锚定：宽和左下角沿用上次的位置，高度按当前是收起还是展开。
        let origin: NSPoint
        if let storedOrigin {
            origin = storedOrigin
        } else {
            let frame = ScreenGeometry.defaultPanelFrame(width: size.width, height: size.height, on: screen)
            origin = frame.origin
        }
        let frame = ScreenGeometry.clamp(NSRect(origin: origin, size: size), on: screen)
        panel.setFrame(frame, display: false)
    }

    private func saveFrame(_ panel: NSPanel) {
        guard !isApplyingProgrammaticFrame else { return }
        let frame = panel.frame
        pendingFrameString = NSStringFromRect(frame)
        storedWidth = frame.width
        storedOrigin = frame.origin
        if AssistantModel.shared.isCollapsed {
            storedCollapsedHeight = min(max(frame.height, Self.minimumCollapsedHeight),
                                        Self.maximumCollapsedHeight)
        } else {
            storedExpandedHeight = min(max(frame.height, Self.minimumExpandedHeight),
                                       Self.maximumExpandedHeight)
        }

        // Moving and custom resizing can emit a callback for every mouse event.
        // Keep the live frame in memory and persist only after the gesture pauses.
        frameSaveTimer?.invalidate()
        frameSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushFrameSave() }
        }
    }

    private func flushFrameSave() {
        frameSaveTimer?.invalidate()
        frameSaveTimer = nil
        guard let pendingFrameString else { return }
        AppSettings.shared.panelFrame = pendingFrameString
        self.pendingFrameString = nil
    }

    /// 启动时把上次的尺寸读回来。
    func restoreStoredFrame() {
        guard let saved = AppSettings.shared.panelFrame else { return }
        let rect = NSRectFromString(saved)
        guard rect.width > 200, rect.height > 100 else { return }
        storedWidth = rect.width
        storedOrigin = rect.origin
        if rect.height <= Self.maximumCollapsedHeight {
            // 180pt was the old default while the standalone mode row was present.
            // Treat that exact legacy default as a migration value so existing users
            // do not keep a large blank strip after the row is removed.
            storedCollapsedHeight = (abs(rect.height - Self.legacyCollapsedHeight) < 1 || abs(rect.height - 140) < 1)
                ? Self.collapsedHeight
                : min(max(rect.height, Self.minimumCollapsedHeight), Self.maximumCollapsedHeight)
        } else if rect.height >= Self.minimumExpandedHeight {
            storedExpandedHeight = min(rect.height, Self.maximumExpandedHeight)
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        if let panel { saveFrame(panel) }
    }

    func windowDidResize(_ notification: Notification) {
        if let panel { saveFrame(panel) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel else { return }
        AssistantModel.shared.setCollapsedSilently(panel.frame.height < Self.minimumExpandedHeight)
        saveFrame(panel)
        flushFrameSave()
    }

    func windowDidResignKey(_ notification: Notification) {
        // 焦点走了：让模型知道该重新读上下文，同时开始自动收起的倒计时。
        AssistantModel.shared.panelDidResignKey()
        refreshIdleTimer()
        broadcastActivity()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshIdleTimer()
        broadcastActivity()
        // 用户点回面板 = 他准备拿现在这一页提问。过期的上下文在这里补采，
        // 而不是他在浏览器里每换一个标签页就自动采一次。
        AssistantModel.shared.panelDidBecomeKey()
    }
}

/// borderless 的窗口默认不能成为 key window，输入框就打不了字，这里放开。
/// 主面板和录制笔记面板共用；Esc 交给各自的 `onCancel`。
final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

extension Notification.Name {
    static let wispPanelDidShow = Notification.Name("wispPanelDidShow")
    /// 面板拿到／失去焦点，或者鼠标进出面板。userInfo["active"] 是 Bool。
    static let wispPanelActivityChanged = Notification.Name("wispPanelActivityChanged")
}

private extension NSRect {
    init?(fromStored string: String) {
        let rect = NSRectFromString(string)
        guard rect.width > 200, rect.height > 80 else { return nil }
        self = rect
    }
}
