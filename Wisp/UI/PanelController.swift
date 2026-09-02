import AppKit
import SwiftUI

/// 无边框、半透明、贴屏幕上方的悬浮面板。
/// 截图在面板显示之前完成，所以面板永远不会被截进去。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var panel: NSPanel?

    static let width: CGFloat = 850
    static let expandedHeight: CGFloat = 560
    static let collapsedHeight: CGFloat = 106
    private static let minimumCollapsedHeight: CGFloat = 100
    private static let maximumCollapsedHeight: CGFloat = 160
    private static let minimumExpandedHeight: CGFloat = 420
    private static let maximumExpandedHeight: CGFloat = 680

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - 显隐

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
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
            await model.captureContext()
            position(panel)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .wispPanelDidShow, object: nil)
            refreshIdleTimer()
        }
    }

    func hide() {
        guard let panel else { return }
        cancelIdleTimer()
        saveFrame(panel)
        panel.orderOut(nil)
        IslandController.shared.setDimmed(false)
        AssistantModel.shared.panelDidHide()
    }

    // MARK: - 失焦自动收起

    /// 鼠标是否停在面板上。悬停也算「还在用」，不计时。
    private var isPointerInside = false
    private var idleTimer: Timer?

    func setPointerInside(_ inside: Bool) {
        guard isPointerInside != inside else { return }
        isPointerInside = inside
        refreshIdleTimer()
    }

    /// 焦点、悬停、生成状态、设置里的秒数，任何一样变了都重新决定要不要计时。
    func refreshIdleTimer() {
        guard let panel, panel.isVisible else { cancelIdleTimer(); return }
        // 这四种情况都说明人还在用它：设置关了、面板有焦点（在打字或点它）、
        // 鼠标停在上面、回答正在生成。任何一条成立都不能收。
        guard AppSettings.shared.idleDismissSeconds > 0,
              !panel.isKeyWindow,
              !isPointerInside,
              !AssistantModel.shared.isStreaming
        else { cancelIdleTimer(); return }

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
        guard let panel, panel.isVisible,
              AppSettings.shared.idleDismissSeconds > 0,
              !panel.isKeyWindow,
              !isPointerInside,
              !AssistantModel.shared.isStreaming
        else { refreshIdleTimer(); return }
        hide()
    }

    /// 收起／展开：只改高度，宽度和左上角位置不动。
    func setCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard let panel else { return }
        let target = collapsed ? storedCollapsedHeight : storedExpandedHeight
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
                context.duration = 0.18
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
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
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

        let root = ChatView()
            .environmentObject(AssistantModel.shared)
            .environmentObject(ConversationStore.shared)
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = DS.windowCorner
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        self.panel = panel
        return panel
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
        AppSettings.shared.panelFrame = NSStringFromRect(panel.frame)
        storedWidth = panel.frame.width
        storedOrigin = panel.frame.origin
        if AssistantModel.shared.isCollapsed {
            storedCollapsedHeight = min(max(panel.frame.height, Self.minimumCollapsedHeight),
                                        Self.maximumCollapsedHeight)
        } else {
            storedExpandedHeight = min(max(panel.frame.height, Self.minimumExpandedHeight),
                                       Self.maximumExpandedHeight)
        }
    }

    /// 启动时把上次的尺寸读回来。
    func restoreStoredFrame() {
        guard let saved = AppSettings.shared.panelFrame else { return }
        let rect = NSRectFromString(saved)
        guard rect.width > 200, rect.height > 100 else { return }
        storedWidth = rect.width
        storedOrigin = rect.origin
        if rect.height <= Self.maximumCollapsedHeight {
            storedCollapsedHeight = min(max(rect.height, Self.minimumCollapsedHeight),
                                        Self.maximumCollapsedHeight)
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

    func windowDidResignKey(_ notification: Notification) {
        // 焦点走了：让模型知道该重新读上下文，同时开始自动收起的倒计时。
        AssistantModel.shared.panelDidResignKey()
        refreshIdleTimer()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshIdleTimer()
    }
}

/// borderless 的窗口默认不能成为 key window，输入框就打不了字，这里放开。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        PanelController.shared.hide()
    }
}

extension Notification.Name {
    static let wispPanelDidShow = Notification.Name("wispPanelDidShow")
}

private extension NSRect {
    init?(fromStored string: String) {
        let rect = NSRectFromString(string)
        guard rect.width > 200, rect.height > 80 else { return nil }
        self = rect
    }
}
