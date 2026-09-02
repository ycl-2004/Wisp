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

    var windowID: CGWindowID? {
        guard let panel else { return nil }
        return CGWindowID(panel.windowNumber)
    }

    private var position: ScreenGeometry.IslandPosition {
        ScreenGeometry.IslandPosition(rawValue: AppSettings.shared.islandPosition) ?? .bottom
    }

    // MARK: - 生命周期

    func start() {
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

    /// 窗口尺寸固定，不随状态变化。只更新位置和可点击区域。
    private func relayout() {
        guard let panel else { return }
        let screen = ScreenGeometry.activeScreen ?? NSScreen.main!
        let info = ScreenGeometry.notch(on: screen)
        let model = IslandModel.shared
        let state = IslandLayout.state(hovered: model.isHovered, generating: model.isGenerating)

        let windowSize: CGSize
        let interactive: CGRect
        switch position {
        case .bottom:
            windowSize = IslandLayout.bottomWindowSize
            interactive = IslandLayout.capsuleRect(state)
        case .notch:
            windowSize = IslandLayout.notchWindowSize(notchWidth: info.width, hasNotch: info.hasNotch)
            interactive = IslandLayout.notchShapeRect(state,
                                                      notchWidth: info.width,
                                                      hasNotch: info.hasNotch)
        }

        hostingView?.interactiveRect = interactive

        let frame = ScreenGeometry.islandFrame(width: windowSize.width, height: windowSize.height,
                                               on: screen, position: position)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }
}
