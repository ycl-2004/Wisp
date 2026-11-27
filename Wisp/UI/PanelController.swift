import AppKit
import SwiftUI

/// 无边框、半透明、贴屏幕上方的悬浮面板。
/// 截图在面板显示之前完成，所以面板永远不会被截进去。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var panel: NSPanel?
    private var presentationGeneration = UUID()

    static let width: CGFloat = 620
    static let expandedHeight: CGFloat = 560
    /// One header row plus the composer.
    static let collapsedHeight: CGFloat = 82
    /// AppKit's resizable style installs its own frame cursors around the window.
    /// Resizing is handled by `PanelResizeOverlay`, so keep the system style non-resizable.
    static let panelStyleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    private static let minimumCollapsedHeight: CGFloat = 82
    /// Defaults of earlier layouts (a separate mode row, then a second header row): a stored height
    /// equal to one of them is the old default, not a choice, and becomes the current one.
    private static let legacyCollapsedHeights: [CGFloat] = [180, 140, 110]
    private static let maximumCollapsedHeight: CGFloat = 240
    private static let minimumExpandedHeight: CGFloat = 280
    private static let maximumExpandedHeight: CGFloat = 1000

    var isVisible: Bool { panel?.isVisible == true }

    /// The panel's level: above regular app windows, below the Settings window while it is in use.
    static let level: NSWindow.Level = .floating
    /// While the panel asks something (first-run setup, a confirmation alert) it has to be answered
    /// first, so it rises above the Settings window.
    static let askingLevel = NSWindow.Level(rawValue: SettingsWindowPresenter.windowLevel.rawValue + 1)

    /// First-run setup waiting while the user is in another app (granting a permission in System
    /// Settings, usually) steps back to an ordinary window so it does not cover that app.
    /// Confirmation alerts stay on top: they are answered on the spot.
    static func level(sheetAttached: Bool, onboarding: Bool, inUse: Bool) -> NSWindow.Level {
        guard sheetAttached else { return level }
        return onboarding && !inUse ? .normal : askingLevel
    }

    /// Called by `WindowLevelCoordinator` whenever the window in use changes.
    func updateLevel() {
        guard let panel else { return }
        Self.updateLevel(of: panel, sheetAttached: panel.attachedSheet != nil)
    }

    private static func updateLevel(of window: NSWindow, sheetAttached: Bool) {
        let target = level(sheetAttached: sheetAttached, onboarding: AssistantModel.shared.showsOnboarding,
                           inUse: window.ownsKeyWindow)
        WindowLevelCoordinator.apply(target, to: window)
    }

    // MARK: - 显隐

    func toggle() {
        isVisible ? hide() : show()
    }

    /// `then` runs once the panel is on screen with this capture done, so an action started from a
    /// shortcut in another app reads that app rather than a stale context.
    func show(then: (@MainActor () -> Void)? = nil) {
        presentationGeneration = UUID()
        let generation = presentationGeneration
        let model = AssistantModel.shared
        // 必须在激活自己之前记住目标应用。
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            model.targetApp = front
        }
        let panel = ensurePanel()
        var excluded = [CGWindowID(panel.windowNumber)]
        if let islandID = IslandController.shared.windowID { excluded.append(islandID) }
        model.ownWindowIDs = excluded
        IslandController.shared.setDimmed(true)

        // 每次唤起都回到输入尺寸，发送时再自动展开。
        model.setCollapsedSilently(true)
        isPointerInside = false
        Task {
            // 只等第一阶段：截图必须赶在浮窗出现之前，否则浮窗会进画面。
            await model.captureShot()
            // Hide or a newer show can arrive while capture is suspended. An old
            // completion must not reopen a dismissed window or run its send action.
            guard self.presentationGeneration == generation else { return }
            position(panel)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .wispPanelDidShow, object: nil)
            refreshIdleTimer()
            // 面板开着期间让头部跟着当前窗口走（只更新应用名和链接）。
            model.startFollowingFrontWindow()
            // 正文**不**在这里读：留到用户按下发送时。
            then?()
        }
    }

    func hide() {
        presentationGeneration = UUID()
        PushToTalk.shared.cancel()
        // Captions live in this panel; they never keep listening once it is gone.
        LiveCaptions.shared.stop()
        guard let panel else { return }
        cancelIdleTimer()
        saveFrame(panel)
        flushFrameSave()
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
    /// 鼠标停在上面、回答正在生成、字幕开着或按住说话、正在采集。任何一条成立都不能收。
    ///
    /// 还有一条：用户正待在**要读的那个应用**里。在 Chrome 里翻标签页找资料
    /// 恰恰说明他在准备提问，这时候把面板收掉最讨嫌。只有他跑去第三个
    /// 不相干的应用、也就是真的走开了，倒计时才有意义。
    private func isIdle(_ panel: NSPanel) -> Bool {
        AppSettings.shared.idleDismissSeconds > 0
            && !panel.isKeyWindow
            && panel.attachedSheet == nil
            && !(panel.childWindows?.contains(where: \.isKeyWindow) == true)
            && !isPointerInside
            && !AssistantModel.shared.isStreaming
            && !AssistantModel.shared.isPreparingResponse
            && !AssistantModel.shared.showsOnboarding
            && !AssistantModel.shared.confirmsEviction
            && !PushToTalk.shared.isActive
            && !LiveCaptions.shared.showsStrip
            && !AssistantModel.shared.isCapturing
            && !isWorkingInCapturedApp
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

    /// 收起／展开：只改高度，宽度和底边位置不动。
    func setCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard panel != nil else { return }
        let target = collapsed ? currentCollapsedHeight : storedExpandedHeight
        setPanelHeight(target, animated: animated)
    }

    /// Keep the collapsed panel tight to the composer as a multiline question grows.
    /// The stored value is updated even while expanded so the next show starts at the
    /// one-line height after the draft is cleared.
    func updateCollapsedHeight(forInputHeight inputHeight: CGFloat, animated: Bool = true) {
        storedCollapsedHeight = Self.collapsedHeight(forInputHeight: inputHeight)
        applyCollapsedHeight(animated: animated)
    }

    /// Make room in the collapsed panel when a caption, microphone or error row appears.
    func rowsChanged() {
        applyCollapsedHeight(animated: true)
        refreshIdleTimer()
    }

    /// Transient rows are added to the base height and are never part of the saved size.
    static var extraRowsHeight: CGFloat {
        (LiveCaptions.shared.showsStrip ? CaptionBar.height : 0) + (PushToTalk.shared.isActive ? PushToTalkRow.height : 0)
            + (AssistantModel.shared.panelError == nil ? 0 : ChatView.errorRowHeight)
    }

    private var currentCollapsedHeight: CGFloat { storedCollapsedHeight + Self.extraRowsHeight }

    private func applyCollapsedHeight(animated: Bool) {
        guard isVisible, AssistantModel.shared.isCollapsed else { return }
        setPanelHeight(currentCollapsedHeight, animated: animated)
    }

    /// The collapsed height follows the measured composer height one point for one,
    /// while keeping a predictable one-line minimum and a bounded multiline maximum,
    /// plus the rows that show under the header while in use.
    static func collapsedHeight(forInputHeight inputHeight: CGFloat) -> CGFloat {
        let delta = max(0, inputHeight - ChatInput.defaultHeight)
        return min(max(Self.collapsedHeight + delta, Self.minimumCollapsedHeight),
                   Self.maximumCollapsedHeight)
    }

    /// The same frame at another height, with its bottom edge where it was: the input box stays
    /// put and the panel opens upward.
    static func frame(_ frame: NSRect, resizedTo height: CGFloat) -> NSRect {
        NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
    }

    private func setPanelHeight(_ target: CGFloat, animated: Bool) {
        guard let panel else { return }
        var frame = panel.frame
        guard abs(frame.height - target) > 0.5 else { return }
        // 底边不动，向上展开。输入框位置保持稳定，内容从上方长出来。
        frame = Self.frame(frame, resizedTo: target)
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
    /// The panel's bottom-left corner, the point that stays put across collapsing and expanding.
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
        panel.onCancel = { PanelController.shared.hide() }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
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
        let height = AssistantModel.shared.isCollapsed ? currentCollapsedHeight : storedExpandedHeight
        let size = NSSize(width: storedWidth, height: height)
        let frame = ScreenGeometry.panelFrame(size: size, savedOrigin: storedOrigin,
                                              displays: NSScreen.screens.map { ($0.frame, $0.visibleFrame) },
                                              fallback: screen.visibleFrame)
        panel.setFrame(frame, display: false)
    }

    private func saveFrame(_ panel: NSPanel) {
        guard !isApplyingProgrammaticFrame else { return }
        var frame = panel.frame
        storedWidth = frame.width
        storedOrigin = frame.origin
        if AssistantModel.shared.isCollapsed {
            storedCollapsedHeight = min(max(frame.height - Self.extraRowsHeight, Self.minimumCollapsedHeight),
                                        Self.maximumCollapsedHeight)
            frame.size.height = storedCollapsedHeight
        } else {
            storedExpandedHeight = min(max(frame.height, Self.minimumExpandedHeight),
                                       Self.maximumExpandedHeight)
        }
        pendingFrameString = NSStringFromRect(frame)

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
        guard rect.width > 200, rect.height >= Self.minimumCollapsedHeight - 1 else { return }
        storedWidth = rect.width
        storedOrigin = rect.origin
        if rect.height <= Self.maximumCollapsedHeight {
            storedCollapsedHeight = Self.legacyCollapsedHeights.contains { abs(rect.height - $0) < 1 }
                ? Self.collapsedHeight
                : min(max(rect.height, Self.minimumCollapsedHeight), Self.maximumCollapsedHeight)
        } else if rect.height >= Self.minimumExpandedHeight {
            storedExpandedHeight = min(rect.height, Self.maximumExpandedHeight)
        }
    }

    /// 恢复出厂设置后清掉内存里缓存的面板位置与尺寸，避免下次关闭面板又写回旧值。
    func resetStoredFrame() {
        frameSaveTimer?.invalidate()
        frameSaveTimer = nil
        pendingFrameString = nil
        storedCollapsedHeight = Self.collapsedHeight
        storedExpandedHeight = Self.expandedHeight
        storedWidth = Self.width
        storedOrigin = nil
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
        AssistantModel.shared.setCollapsedSilently((panel.frame.height - Self.extraRowsHeight) < Self.minimumExpandedHeight)
        saveFrame(panel)
        flushFrameSave()
    }

    // SwiftUI 的 .sheet 和 .alert 在 macOS 上都挂成这个窗口的 sheet。挂上之前就把层级定好，
    // sheet 一出现就在该在的那一层。
    func windowWillBeginSheet(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Self.updateLevel(of: window, sheetAttached: true)
    }

    func windowDidEndSheet(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Self.updateLevel(of: window, sheetAttached: window.attachedSheet != nil)
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
/// Esc 交给 `onCancel`。
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

/// Wisp's panel and Settings window pick their level from which window is in use, so it is
/// re-checked after every key-window or app activation change. The check runs on the next turn
/// of the main queue: AppKit settles the new key window after posting these notifications.
@MainActor
enum WindowLevelCoordinator {
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                          NSApplication.didBecomeActiveNotification,
                                          NSApplication.didResignActiveNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { refresh() } }
            }
        }
    }

    static func refresh() {
        PanelController.shared.updateLevel()
        SettingsWindowPresenter.updateLevel()
    }

    /// A sheet is moved along with its window, so it never ends up under the window it belongs to.
    static func apply(_ level: NSWindow.Level, to window: NSWindow) {
        if window.level != level { window.level = level }
        if let sheet = window.attachedSheet, sheet.level != level { sheet.level = level }
    }
}

extension NSWindow {
    /// This window, or a sheet or popover hanging off it, is the key window.
    var ownsKeyWindow: Bool {
        var candidate = NSApp.keyWindow
        while let window = candidate {
            if window === self { return true }
            candidate = window.sheetParent ?? window.parent
        }
        return false
    }
}
