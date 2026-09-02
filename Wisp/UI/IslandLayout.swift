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

    static func state(hovered: Bool, generating: Bool) -> State {
        if generating { return .generating }
        return hovered ? .hovered : .idle
    }

    // MARK: - 底部药丸

    /// 固定的窗口尺寸，取所有状态里的最大值再留出阴影余量。
    static let bottomWindowSize = CGSize(width: 372, height: 76)
    /// 胶囊距窗口底边的留白，给阴影用。
    static let bottomInset: CGFloat = 12

    static func capsuleSize(_ state: State) -> CGSize {
        switch state {
        case .idle:       return CGSize(width: 40, height: 40)
        case .hovered:    return CGSize(width: 316, height: 44)
        case .generating: return CGSize(width: 340, height: 48)
        }
    }

    /// 胶囊在窗口内的矩形，AppKit 坐标（原点在左下）。用于把窗口其余部分的鼠标事件放行。
    static func capsuleRect(_ state: State) -> CGRect {
        let size = capsuleSize(state)
        return CGRect(x: ((bottomWindowSize.width - size.width) / 2).rounded(),
                      y: bottomInset,
                      width: size.width,
                      height: size.height)
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
