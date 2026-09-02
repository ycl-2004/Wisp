import AppKit
import Combine
import SwiftUI

/// 常驻的小药丸。默认在底部 Dock 上方居中：
/// 闲置只有一颗图标大小，悬停展开成一条，生成回答时变宽并带停止键。
/// 也可以改成贴刘海的形态。
@MainActor
final class IslandController: NSObject {
    static let shared = IslandController()

    private var panel: NSPanel?
    private var hostingView: PassthroughHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?

    /// 拖动期间的锚点，落盘前先放这儿。
    /// 每帧直接取 NSEvent.mouseLocation，不累加位移：既没有漂移，也不受起手距离影响。
    private var draggingAnchor: NSPoint?

    var isDraggable: Bool { position == .bottom }

    var windowID: CGWindowID? {
        guard let panel else { return nil }
        return CGWindowID(panel.windowNumber)
    }

    private var position: ScreenGeometry.IslandPosition {
        ScreenGeometry.IslandPosition(rawValue: AppSettings.shared.islandPosition) ?? .bottom
    }

    // MARK: - 生命周期

    func start() {
        migrateLegacyAnchorIfNeeded()
        guard AppSettings.shared.showIsland else { return }
        let panel = ensurePanel()
        relayout()
        panel.orderFrontRegardless()

        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            }
        }
    }

    func stop() {
        panel?.orderOut(nil)
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    /// 主面板打开时整条药丸收起来，关掉再回来。
    func setDimmed(_ dimmed: Bool) {
        IslandModel.shared.isDimmed = dimmed
        guard let panel, AppSettings.shared.showIsland else { return }
        if dimmed {
            panel.orderOut(nil)
        } else {
            relayout()
            panel.orderFrontRegardless()
        }
    }

    func applyPositionChange() {
        guard let panel else { return }
        panel.orderOut(nil)
        rebuildContent(on: panel)
        relayout()
        if !IslandModel.shared.isDimmed && AppSettings.shared.showIsland {
            panel.orderFrontRegardless()
        }
    }

    // MARK: - 构造

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: IslandLayout.bottomWindowSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false

        rebuildContent(on: panel)
        self.panel = panel

        let model = IslandModel.shared
        Publishers.CombineLatest(model.$isHovered.removeDuplicates(),
                                 model.$isGenerating.removeDuplicates())
            .sink { [weak self] _, _ in
                MainActor.assumeIsolated { self?.relayout() }
            }
            .store(in: &cancellables)

        return panel
    }

    private func rebuildContent(on panel: NSPanel) {
        let screen = ScreenGeometry.activeScreen ?? NSScreen.main!
        let info = ScreenGeometry.notch(on: screen)
        let root = AnyView(
            IslandView(notchWidth: info.hasNotch ? info.width : 0,
                       hasNotch: info.hasNotch,
                       position: position)
                .environmentObject(IslandModel.shared)
        )
        let hosting = PassthroughHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        hostingView = hosting
    }

    // MARK: - 布局

    /// 窗口尺寸固定不变，变的是小圆在窗口里的位置，以及窗口整体落在哪。
    private func relayout() {
        guard let panel else { return }
        let screen = ScreenGeometry.activeScreen ?? NSScreen.main!
        let info = ScreenGeometry.notch(on: screen)
        let model = IslandModel.shared
        let state = IslandLayout.state(hovered: model.isHovered,
                                       generating: model.isGenerating,
                                       dragging: model.isDragging)

        let frame: NSRect
        let interactive: CGRect

        switch position {
        case .bottom:
            let size = IslandLayout.bottomWindowSize
            let anchor = anchorPoint(on: screen)
            let host = Self.screen(containing: anchor) ?? screen

            // 窗口只是承载物：把它摆成「锚点正好落在小圆的默认位置上」，再夹回屏内。
            var candidate = NSRect(x: anchor.x - IslandLayout.anchorInWindow.x,
                                   y: anchor.y - IslandLayout.anchorInWindow.y,
                                   width: size.width, height: size.height)
            candidate = ScreenGeometry.clamp(candidate, on: host)
            frame = candidate

            // 窗口被屏幕边缘夹住之后，小圆仍然跟着锚点走 —— 这才是它能贴到边的原因。
            // 但不能被窗口切掉，所以留出半径。
            let radius = IslandLayout.idleDiameter / 2
            let dotCenterX = min(max(anchor.x - candidate.minX, radius), size.width - radius)
            if model.dotCenterX != dotCenterX { model.dotCenterX = dotCenterX }
            interactive = IslandLayout.capsuleRect(state, dotCenterX: dotCenterX)

        case .notch:
            let size = IslandLayout.notchWindowSize(notchWidth: info.width, hasNotch: info.hasNotch)
            frame = ScreenGeometry.islandFrame(width: size.width, height: size.height,
                                               on: screen, position: .notch)
            interactive = IslandLayout.notchShapeRect(state,
                                                      notchWidth: info.width,
                                                      hasNotch: info.hasNotch)
        }

        hostingView?.interactiveRect = interactive
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    /// 当前该用哪个锚点：拖动中 > 用户存过的 > 默认底部居中。
    private func anchorPoint(on screen: NSScreen) -> NSPoint {
        if let draggingAnchor { return draggingAnchor }
        if let stored = AppSettings.shared.islandAnchor,
           Self.screen(containing: stored) != nil {
            return stored
        }
        // 存过但那块屏幕已经不在了（副屏拔掉），退回默认位置。
        return Self.defaultAnchor(on: screen)
    }

    static func defaultAnchor(on screen: NSScreen) -> NSPoint {
        let size = IslandLayout.bottomWindowSize
        let frame = ScreenGeometry.islandFrame(width: size.width, height: size.height,
                                               on: screen, position: .bottom)
        return NSPoint(x: frame.midX, y: frame.minY + IslandLayout.anchorInWindow.y)
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// 0.2.0 开发期存的是窗口原点，现在存小圆中心。读到旧值就地换算一次，别让位置丢了。
    private func migrateLegacyAnchorIfNeeded() {
        let settings = AppSettings.shared
        guard settings.islandAnchor == nil, let origin = settings.legacyIslandOrigin else { return }
        settings.islandAnchor = NSPoint(x: origin.x + IslandLayout.anchorInWindow.x,
                                        y: origin.y + IslandLayout.anchorInWindow.y)
        settings.legacyIslandOrigin = nil
    }

    // MARK: - 拖动

    /// 手势每次变化都调这个。小圆直接钉在光标上，所见即所得。
    func dragChanged() {
        guard isDraggable else { return }
        let model = IslandModel.shared
        if !model.isDragging { model.isDragging = true }
        draggingAnchor = NSEvent.mouseLocation
        relayout()
    }

    func dragEnded() {
        guard isDraggable else {
            draggingAnchor = nil
            IslandModel.shared.isDragging = false
            return
        }
        if let anchor = draggingAnchor {
            AppSettings.shared.islandAnchor = anchor
        }
        draggingAnchor = nil
        IslandModel.shared.isDragging = false
        // 松手后如果光标还停在上面，这一次 relayout 会把它重新展开。
        relayout()
    }

    /// 设置里的「回到默认位置」。
    func resetPosition() {
        AppSettings.shared.islandAnchor = nil
        relayout()
    }
}
