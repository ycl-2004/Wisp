import AppKit
import SwiftUI

/// 药丸的尺寸只有这一份定义。窗口本身固定不动，只有里面的胶囊会变，
/// 这样内容不会被挤在一个还没长大的窗口里，光标也不会因为窗口忽大忽小而被甩出判定区。
enum IslandLayout {

    enum State {
        case idle
        case hovered
        case generating
    }

    /// 拖动时一律按空闲算：拖的是那颗小圆，不是展开后的长条。
    /// 展开态贴边时根本放不进去，会让人以为「拖不动了」。
    static func state(hovered: Bool, generating: Bool, dragging: Bool = false) -> State {
        if dragging { return .idle }
        if generating { return .generating }
        return hovered ? .hovered : .idle
    }

    // MARK: - 底部药丸

    /// 固定的窗口尺寸，取所有状态里的最大值再留出阴影余量。
    static let bottomWindowSize = CGSize(width: 372, height: 76)
    /// 胶囊距窗口底边的留白，给阴影用。
    static let bottomInset: CGFloat = 12
    /// 空闲小圆的直径。它是位置的锚点：存的、拖的、贴边贴的都是它。
    static let idleDiameter: CGFloat = 40

    /// 小圆中心在窗口内的默认位置（AppKit 坐标，原点左下）。
    /// 窗口比小圆大得多，是为了给展开态留地方；真正代表「药丸在哪」的是这个点。
    static var anchorInWindow: CGPoint {
        CGPoint(x: bottomWindowSize.width / 2, y: bottomInset + idleDiameter / 2)
    }

    static func capsuleSize(_ state: State) -> CGSize {
        switch state {
        case .idle:       return CGSize(width: 40, height: 40)
        case .hovered:    return CGSize(width: 316, height: 44)
        case .generating: return CGSize(width: 340, height: 48)
        }
    }

    /// 胶囊在窗口内的矩形，AppKit 坐标（原点在左下）。用于把窗口其余部分的鼠标事件放行。
    /// `dotCenterX` 是小圆中心在窗口内的 x。展开时优先以它为中心；
    /// 那一侧放不下就往窗口里还有空间的一边让，于是贴左边就朝右长、贴右边就朝左长，
    /// 而不是被窗口边缘切掉。
    static func capsuleRect(_ state: State, dotCenterX: CGFloat) -> CGRect {
        let size = capsuleSize(state)
        let maxX = max(0, bottomWindowSize.width - size.width)
        let x = min(max(dotCenterX - size.width / 2, 0), maxX)
        return CGRect(x: x.rounded(), y: bottomInset, width: size.width, height: size.height)
    }

    static func capsuleRect(_ state: State) -> CGRect {
        capsuleRect(state, dotCenterX: anchorInWindow.x)
    }

    // MARK: - 刘海形态

    static let notchBarHeight: CGFloat = 32
    static let notchExpandedExtra: CGFloat = 30
    static let notchIdleWing: CGFloat = 44
    static let notchHoverWing: CGFloat = 104
    static let noNotchIdleWidth: CGFloat = 92
    static let noNotchHoverWidth: CGFloat = 210

    static func notchWindowSize(notchWidth: CGFloat, hasNotch: Bool) -> CGSize {
        let width = hasNotch ? notchWidth + notchHoverWing * 2 : noNotchHoverWidth
        return CGSize(width: width, height: notchBarHeight + notchExpandedExtra)
    }

    static func notchShapeSize(_ state: State, notchWidth: CGFloat, hasNotch: Bool) -> CGSize {
        let expanded = state != .idle
        let wing = expanded ? notchHoverWing : notchIdleWing
        let width = hasNotch ? notchWidth + wing * 2
                             : (expanded ? noNotchHoverWidth : noNotchIdleWidth)
        let height = notchBarHeight + (expanded ? notchExpandedExtra : 0)
        return CGSize(width: width, height: height)
    }

    /// 刘海形态的形状贴在窗口顶部。
    static func notchShapeRect(_ state: State, notchWidth: CGFloat, hasNotch: Bool) -> CGRect {
        let window = notchWindowSize(notchWidth: notchWidth, hasNotch: hasNotch)
        let size = notchShapeSize(state, notchWidth: notchWidth, hasNotch: hasNotch)
        return CGRect(x: ((window.width - size.width) / 2).rounded(),
                      y: window.height - size.height,
                      width: size.width,
                      height: size.height)
    }
}

/// 窗口是固定的大矩形，但只有胶囊那一块该接收鼠标。
/// 其余部分必须放行，否则会在屏幕上留下一片看不见却挡点击的区域。
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}
