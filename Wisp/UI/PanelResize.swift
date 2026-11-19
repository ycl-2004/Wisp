import AppKit
import SwiftUI

/// 无边框面板的缩放。
///
/// AppKit 的 borderless resize 入口可抓的只有一两个像素，而且 contentView 铺满之后
/// 基本抓不到；它还会在窗口外沿安装系统缩放光标。这里由内容之上的透明视图接管：
/// 命中边缘就自己算新 frame，其他位置一律放行，SwiftUI 的点击、悬停、拖动窗口都不受影响。
/// 鼠标指针从不改变：哪里能缩放由内侧那圈蓝色提示线说明。
enum PanelResize {
    /// 边缘可抓的宽度。太小抓不住，太大就会吃掉贴边控件的点击。
    static let grabInset: CGFloat = 6
    /// 右下角把手的边长，四角同样按这个尺寸放宽命中区。保持严格小于 DS.gutter (12)，
    /// 避免覆盖底部发送按钮的边缘点击区。
    static let cornerSize: CGFloat = 11
    /// 内层提示线与面板边缘的距离，不占用实际内容的命中区域。
    static let guideInset: CGFloat = 4

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    /// 视图坐标（左下原点）里这个点抓到了哪几条边。下面两个角落在两条边上。
    ///
    /// 最上面那一条（整条，含两个上角）不缩放，和面板其余空白处一样用来拖动。以前顶边也能缩放，
    /// 用户抓面板最顺手的位置恰好是顶边，结果横着拖纹丝不动、竖着拖改了高度又被收起高度夹回去，
    /// 像是卡住。高度仍然可以从底边和下面两个角调。
    static func edges(at point: NSPoint, in size: NSSize,
                      inset: CGFloat = grabInset, corner: CGFloat = cornerSize) -> Edges {
        guard size.width > 0, size.height > 0,
              point.x >= 0, point.y >= 0, point.x <= size.width, point.y < size.height - inset else { return [] }
        var edges: Edges = []
        if point.x <= inset { edges.insert(.left) }
        if point.x >= size.width - inset { edges.insert(.right) }
        if point.y <= inset { edges.insert(.bottom) }
        // 角上放宽：只有 6 点见方的角很难瞄准，而拖角是最常用的缩放动作。
        if point.x <= corner, point.y <= corner { edges.formUnion([.left, .bottom]) }
        if point.x >= size.width - corner, point.y <= corner { edges.formUnion([.right, .bottom]) }
        return edges
    }

    /// 按住的那几条边跟着鼠标走，对面的边一动不动——包括撞到最大最小尺寸的时候。
    static func frame(from start: NSRect, edges: Edges, translation: NSSize,
                      minSize: NSSize, maxSize: NSSize) -> NSRect {
        var frame = start
        let width = { (value: CGFloat) in min(max(value, minSize.width), maxSize.width) }
        let height = { (value: CGFloat) in min(max(value, minSize.height), maxSize.height) }

        if edges.contains(.right) {
            frame.size.width = width(start.width + translation.width)
        } else if edges.contains(.left) {
            frame.size.width = width(start.width - translation.width)
            frame.origin.x = start.maxX - frame.size.width
        }
        if edges.contains(.bottom) {
            frame.size.height = height(start.height - translation.height)
            frame.origin.y = start.maxY - frame.size.height
        }
        return frame
    }
}

/// 盖在面板内容之上的缩放层。命中边缘才接管事件，其余位置返回 nil 让内容照常收事件。
final class PanelResizeOverlay: NSView {
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero
    private var activeEdges: PanelResize.Edges = []
    private var hoveringEdges: PanelResize.Edges = []
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard superview != nil else { return nil }
        // `hitTest` already receives a point in this view's coordinate system.
        // Converting it from the superview shifts the edge hit box whenever the
        // overlay is not positioned at the superview's origin.
        return PanelResize.edges(at: point, in: bounds.size).isEmpty ? nil : self
    }

    // The panel is non-activating: the first press from another app must already resize.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
        activeEdges = PanelResize.edges(at: convert(event.locationInWindow, from: nil), in: bounds.size)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, !activeEdges.isEmpty else { return }
        // 用屏幕坐标算位移：窗口自己正在移动，窗口内坐标会跟着漂。
        let mouse = NSEvent.mouseLocation
        let translation = NSSize(width: mouse.x - startMouse.x, height: mouse.y - startMouse.y)
        let frame = PanelResize.frame(from: startFrame, edges: activeEdges, translation: translation,
                                      minSize: window.minSize, maxSize: window.maxSize)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard !activeEdges.isEmpty else { return }
        activeEdges = []
        // NSWindowDelegate 的 didEndLiveResize 只在系统自己的缩放里发，这里手动补一次，
        // 否则收起／展开的高度记不住。
        window?.delegate?.windowDidEndLiveResize?(Notification(name: NSWindow.didEndLiveResizeNotification))
    }

    // MARK: - 悬停提示

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let edges = PanelResize.edges(at: convert(event.locationInWindow, from: nil), in: bounds.size)
        if edges != hoveringEdges {
            hoveringEdges = edges
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !hoveringEdges.isEmpty {
            hoveringEdges = []
            needsDisplay = true
        }
    }

    /// 画在内容内侧的轻量缩放提示：整圈圆角细线标出可抓的边，边中间的小标记
    /// 让用户一眼知道拖哪里。提示不改变 hitTest，也不会挡住 SwiftUI 控件。
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > PanelResize.guideInset * 2,
              bounds.height > PanelResize.guideInset * 2 else { return }

        let guide = bounds.insetBy(dx: PanelResize.guideInset, dy: PanelResize.guideInset)
        let active = !hoveringEdges.isEmpty
        let lineColor = NSColor.systemBlue.withAlphaComponent(active ? 0.48 : 0.22)
        lineColor.setStroke()
        let radius = max(0, DS.windowCorner - PanelResize.guideInset)
        let border = NSBezierPath(roundedRect: guide, xRadius: radius, yRadius: radius)
        border.lineWidth = active ? 1.0 : 0.7
        border.lineCapStyle = .round
        border.stroke()

        let markerColor = NSColor.systemBlue.withAlphaComponent(active ? 0.60 : 0.28)
        markerColor.setStroke()
        let marker = NSBezierPath()
        marker.lineWidth = active ? 1.6 : 1.2
        marker.lineCapStyle = .round

        // Each edge gets a short centered dash. The dashes stay inside the panel,
        // so they describe the gesture without creating a second outer frame.
        // The top one is a move grabber: that edge moves the panel instead of resizing it.
        let halfMarker: CGFloat = 11
        marker.move(to: NSPoint(x: guide.midX - halfMarker, y: guide.minY))
        marker.line(to: NSPoint(x: guide.midX + halfMarker, y: guide.minY))
        marker.move(to: NSPoint(x: guide.midX - halfMarker, y: guide.maxY))
        marker.line(to: NSPoint(x: guide.midX + halfMarker, y: guide.maxY))
        marker.move(to: NSPoint(x: guide.minX, y: guide.midY - halfMarker))
        marker.line(to: NSPoint(x: guide.minX, y: guide.midY + halfMarker))
        marker.move(to: NSPoint(x: guide.maxX, y: guide.midY - halfMarker))
        marker.line(to: NSPoint(x: guide.maxX, y: guide.midY + halfMarker))

        marker.stroke()
    }
}

/// 面板上凡是不是控件的地方，按住都能拖着整个窗口走。
///
/// 手势挂在整块内容上：按钮、菜单、输入框、可选中的文字各有自己的手势或 AppKit 视图，优先级
/// 比它高，照常收自己的点击；其余位置（留白、间隙、标题文字）都落到这个手势上。新加的控件
/// 不需要登记。
///
/// 窗口是自己跟着鼠标挪的，不交给系统。实测（2026-11-18，macOS 27.2，触控板）：在这种无边框、
/// 不激活的面板上，`NSWindow.performDrag(with:)` 和 SwiftUI 的 `WindowDragGesture` 都只打出
/// 「Window move completed without beginning」，窗口不动；`isMovableByWindowBackground` 只在点到
/// 空背景时有效，压着文字和图标的地方不行。所以之前标题拖不动、只有零碎的缝隙能拖。
extension View {
    func dragsPanel() -> some View { modifier(PanelDrag()) }
}

private struct PanelDrag: ViewModifier {
    @State private var move = PanelMove()

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // 起手距离 3 点：点一下不算拖。
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { _ in move.changed() }
                .onEnded { _ in move.ended() })
            // The panel is non-activating: a drag has to work on the first press from another app.
            // https://developer.apple.com/documentation/swiftui/view/allowswindowactivationevents(_:)
            .allowsWindowActivationEvents(true)
    }
}

/// One drag of a window: it follows the mouse by the distance the mouse has travelled, and stays
/// inside the visible area of the screen the mouse is on, so it cannot be lost off screen.
@MainActor
final class PanelMove {
    private var start: (window: NSWindow, frame: NSRect, mouse: NSPoint)?

    /// The window is the one the current mouse event belongs to. Screen coordinates are used
    /// because the window itself is moving, which would drag window coordinates along.
    func changed(mouse: NSPoint = NSEvent.mouseLocation, window: NSWindow? = nil) {
        if start == nil, let window = window ?? NSApp.currentEvent?.window { start = (window, window.frame, mouse) }
        guard let start else { return }
        var frame = start.frame
        frame.origin.x += mouse.x - start.mouse.x
        frame.origin.y += mouse.y - start.mouse.y
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? start.window.screen {
            frame = ScreenGeometry.clamp(frame, on: screen)
        }
        // A move posts `windowDidMove`, which is where the panel's position is saved.
        start.window.setFrameOrigin(frame.origin)
    }

    func ended() { start = nil }
}
