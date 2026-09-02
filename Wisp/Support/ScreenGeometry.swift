import AppKit

/// 刘海与屏幕几何。没有刘海的机器（或外接显示器）退回居中胶囊。
enum ScreenGeometry {

    struct Notch {
        var screen: NSScreen
        /// 刘海本身的矩形，屏幕坐标。没有刘海时为 nil。
        var rect: CGRect?
        var hasNotch: Bool { rect != nil }
        var width: CGFloat { rect?.width ?? 0 }
        var height: CGFloat { rect?.height ?? screen.frame.maxY - screen.visibleFrame.maxY }
    }

    /// 鼠标所在的屏幕，找不到就用主屏。
    static var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    static func notch(on screen: NSScreen) -> Notch {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else {
            return Notch(screen: screen, rect: nil)
        }
        let rect = CGRect(x: left.maxX,
                          y: screen.frame.maxY - screen.safeAreaInsets.top,
                          width: right.minX - left.maxX,
                          height: screen.safeAreaInsets.top)
        return Notch(screen: screen, rect: rect)
    }

    enum IslandPosition: String {
        case bottom
        case notch
    }

    /// 灵动岛窗口应该放的位置。
    /// - bottom：底部居中，压在 Dock 上方一点，Vida 用的就是这种。
    /// - notch：贴住屏幕最上沿，横向以刘海为中心。
    static func islandFrame(width: CGFloat,
                            height: CGFloat,
                            on screen: NSScreen,
                            position: IslandPosition) -> NSRect {
        switch position {
        case .bottom:
            let x = screen.frame.midX - width / 2
            let y = screen.visibleFrame.minY + 12
            return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)

        case .notch:
            let info = notch(on: screen)
            let x = (info.rect?.midX ?? screen.frame.midX) - width / 2
            let y = info.hasNotch
                ? screen.frame.maxY - height
                : screen.visibleFrame.maxY - height - 6
            return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
        }
    }

    /// 主面板的默认位置：底部居中，给灵动岛让出下面那一截，向上展开。
    static func defaultPanelFrame(width: CGFloat, height: CGFloat, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let x = visible.midX - width / 2
        let y = visible.minY + 16
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    /// 把窗口夹回屏幕可见区域内，别让向上展开时顶出屏幕。
    static func clamp(_ frame: NSRect, on screen: NSScreen) -> NSRect {
        var result = frame
        let visible = screen.visibleFrame
        result.size.height = min(result.height, visible.height - 8)
        if result.maxY > visible.maxY { result.origin.y = visible.maxY - result.height }
        if result.minY < visible.minY { result.origin.y = visible.minY }
        if result.maxX > visible.maxX { result.origin.x = visible.maxX - result.width }
        if result.minX < visible.minX { result.origin.x = visible.minX }
        return result
    }
}
