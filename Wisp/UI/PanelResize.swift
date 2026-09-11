import AppKit
import SwiftUI

/// 无边框面板的缩放。
///
/// `.resizable` 的 borderless 窗口理论上能从边缘拖，但可抓的只有一两个像素，
/// 而且 contentView 铺满之后基本抓不到——用起来就是「这窗口不能改大小」。
/// 这里在内容之上盖一层只吃边缘几个点的透明视图：命中边缘就自己算新 frame，
/// 其余位置一律放行，SwiftUI 的点击、悬停、拖动窗口都不受影响。
enum PanelResize {
    /// 边缘可抓的宽度。太小抓不住，太大就会吃掉贴边控件的点击。
    static let grabInset: CGFloat = 6
    /// 右下角把手的边长，四角同样按这个尺寸放宽命中区。
    static let cornerSize: CGFloat = 16

    /// Resizing is still handled by the overlay, but its pointer stays an arrow.
    /// This keeps the local-cursor experiment and ordinary Wisp use visually stable.
    static func cursor(for _: Edges) -> NSCursor { .arrow }

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let top = Edges(rawValue: 1 << 2)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    /// 视图坐标（左下原点）里这个点抓到了哪几条边。四角落在两条边上。
    static func edges(at point: NSPoint, in size: NSSize,
                      inset: CGFloat = grabInset, corner: CGFloat = cornerSize) -> Edges {
        guard size.width > 0, size.height > 0,
              point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return [] }
        var edges: Edges = []
        if point.x <= inset { edges.insert(.left) }
        if point.x >= size.width - inset { edges.insert(.right) }
        if point.y <= inset { edges.insert(.bottom) }
        if point.y >= size.height - inset { edges.insert(.top) }
        // 角上放宽：只有 6 点见方的角很难瞄准，而拖角是最常用的缩放动作。
        if point.x <= corner, point.y <= corner { edges.formUnion([.left, .bottom]) }
        if point.x >= size.width - corner, point.y <= corner { edges.formUnion([.right, .bottom]) }
        if point.x <= corner, point.y >= size.height - corner { edges.formUnion([.left, .top]) }
        if point.x >= size.width - corner, point.y >= size.height - corner { edges.formUnion([.right, .top]) }
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
        if edges.contains(.top) {
            frame.size.height = height(start.height + translation.height)
        } else if edges.contains(.bottom) {
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
    private var hoveringCorner = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard superview != nil else { return nil }
        // `hitTest` already receives a point in this view's coordinate system.
        // Converting it from the superview shifts the edge hit box whenever the
        // overlay is not positioned at the superview's origin.
        let local = point
        // The title drag view lives below this overlay. Let it win when the user
        // starts a drag on the title's top edge; otherwise that same gesture is
        // interpreted as a resize and never reaches `performDrag(with:)`.
        if dragAreaFrames().contains(where: { $0.contains(local) }) { return nil }
        return PanelResize.edges(at: local, in: bounds.size).isEmpty ? nil : self
    }

    private func dragAreaFrames() -> [NSRect] {
        guard let superview else { return [] }
        var frames: [NSRect] = []
        var pending = superview.subviews
        while let candidate = pending.popLast() {
            if candidate is WindowDragArea.DragView {
                frames.append(convert(candidate.bounds, from: candidate))
            }
            pending.append(contentsOf: candidate.subviews)
        }
        return frames
    }

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
        activeEdges = []
        // NSWindowDelegate 的 didEndLiveResize 只在系统自己的缩放里发，这里手动补一次，
        // 否则收起／展开的高度记不住。
        window?.delegate?.windowDidEndLiveResize?(Notification(name: NSWindow.didEndLiveResizeNotification))
    }

    // MARK: - 指针与把手

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
        let point = convert(event.locationInWindow, from: nil)
        let edges = PanelResize.edges(at: point, in: bounds.size)
        PanelResize.cursor(for: edges).set()
        let corner = edges.contains(.right) && edges.contains(.bottom)
        if corner != hoveringCorner {
            hoveringCorner = corner
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        if hoveringCorner {
            hoveringCorner = false
            needsDisplay = true
        }
    }

    /// 右下角三条斜线。平时几乎看不见，鼠标靠近才亮一点——面板是拿来看别的东西的，
    /// 一个常年发亮的把手会一直在余光里晃。
    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = hoveringCorner ? 0.45 : 0.16
        NSColor.secondaryLabelColor.withAlphaComponent(alpha).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.lineCapStyle = .round
        // 端点都留在窗口圆角以内，否则三条线会悬在圆弧外面。
        for offset in stride(from: CGFloat(12), through: 20, by: 4) {
            path.move(to: NSPoint(x: bounds.maxX - offset, y: bounds.minY + 6))
            path.line(to: NSPoint(x: bounds.maxX - 6, y: bounds.minY + offset))
        }
        path.stroke()
    }
}

/// 让一块 SwiftUI 区域变成能拖着走窗口的「标题栏」。
///
/// 面板是 borderless 的，`isMovableByWindowBackground` 只在点到真正的空背景时才算数：
/// 收起时面板大半是背景，随便拖哪儿都能动；一展开，中间就被消息列表占满，
/// 用户去拖那里等于在拖一个 ScrollView，窗口纹丝不动。这层贴在头部标题那一段的背景上，
/// 按钮仍然在它上面照常收自己的点击，点到标题和空白处就开始拖窗口。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        // The panel is intentionally non-activating. Accept the first press so a
        // drag works from another app or Space instead of requiring a click first.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // performDrag 自己接管这一次拖动，窗口移完会照常发 windowDidMove，位置就存下来了。
            window?.performDrag(with: event)
        }
    }
}
