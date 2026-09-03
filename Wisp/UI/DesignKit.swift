import AppKit
import SwiftUI

/// 界面统一的尺寸、圆角、字号。集中放一处，避免各视图各写各的。
enum DS {
    static let windowCorner: CGFloat = 16
    static let cardCorner: CGFloat = 10
    static let chipCorner: CGFloat = 6

    static let gutter: CGFloat = 12
    static let rowGap: CGFloat = 8
    static let tightGap: CGFloat = 4

    static let headerHeight: CGFloat = 32
    static let metaHeight: CGFloat = 20

    static let body = Font.system(size: 13, weight: .regular)
    static let title = Font.system(size: 12.5, weight: .semibold)
    static let meta = Font.system(size: 11, weight: .regular)
    static let label = Font.system(size: 10, weight: .semibold)
    static let code = Font.system(size: 11.5, design: .monospaced)

    static let hairline = Color.primary.opacity(0.08)
    static let faint = Color.primary.opacity(0.04)
    static let cardBackground = Color.primary.opacity(0.045)
    static let subtleBackground = Color.primary.opacity(0.025)
    static let accentFaint = Color.accentColor.opacity(0.09)

    /// 拟真玻璃边缘微光渐变，让悬浮窗口边缘晶莹通透
    static let specularRim = LinearGradient(
        stops: [
            .init(color: .white.opacity(0.32), location: 0),
            .init(color: .white.opacity(0.08), location: 0.35),
            .init(color: .black.opacity(0.06), location: 0.8),
            .init(color: .black.opacity(0.20), location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

/// 应用图标要走 IconServices 加一次磁盘查找。对话列表每行都要一个，而 body
/// 会因为 hover 反复求值，不缓存的话滚动能明显感觉到发涩。图标在进程生命周期里
/// 基本不变，查不到的也记下来，省得每帧重试一遍。
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage?] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let hit = cache[bundleID] { return hit }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = image
        return image
    }
}

/// 面板背后的毛玻璃。用 behindWindow 才能真正透出下面的应用。
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// 小图标按钮：平时无痕，悬停才浮出底色。
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Color.primary : (hovering ? Color.primary : Color.secondary))
            .frame(width: size + 12, height: size + 12)
            .background(
                RoundedRectangle(cornerRadius: DS.chipCorner, style: .continuous)
                    .fill(hovering ? DS.cardBackground : Color.clear)
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1.0)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// 保留系统 Button 的键盘、辅助功能和触发语义，只补一层克制的按压反馈。
struct PressFeedbackButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// 状态小标签，可点。
struct Chip: View {
    var icon: String?
    var text: String
    var active: Bool
    var enabled: Bool = true
    var action: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(PressFeedbackButtonStyle())
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.55)
            } else {
                label
            }
        }
        .onHover { hovering = action != nil && enabled && $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: active)
    }

    private var label: some View {
        HStack(spacing: 3.5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9.5, weight: .medium))
            }
            Text(text).font(DS.meta)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
        .background(
            RoundedRectangle(cornerRadius: DS.chipCorner, style: .continuous)
                .fill(active ? Color.accentColor.opacity(hovering ? 0.18 : 0.11)
                             : Color.primary.opacity(hovering ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.chipCorner, style: .continuous)
                .strokeBorder(active ? Color.accentColor.opacity(0.25) : DS.hairline, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

/// 顶部与底部的渐隐，让滚动内容不硬切在分隔线上。
struct EdgeFade: View {
    var edge: UnitPoint = .top
    var height: CGFloat = 14

    var body: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.12), Color.black.opacity(0)],
            startPoint: edge,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: height)
        .blendMode(.destinationOut)
        .allowsHitTesting(false)
    }
}

/// 流式打字机光标。用 repeatForever 动画驱动，视图消失时 SwiftUI 自动停掉，
/// 不留后台计时器。关闭「减弱动态效果」时退化成常亮的一条竖线。
struct BlinkingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 2, height: 13)
            .opacity(dimmed ? 0.15 : 0.9)
            .animation(reduceMotion ? nil
                                    : .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                       value: dimmed)
            .onAppear { if !reduceMotion { dimmed = true } }
            .accessibilityHidden(true)
    }
}

/// 思考中的三点脉冲。三个点错开相位做呼吸，比转圈安静。
/// 同样只靠 repeatForever 动画，不挂 Timer：这个视图在菜单栏常驻进程里
/// 会被反复创建，留下的计时器会一直唤醒 CPU。
struct PulsingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4.5, height: 4.5)
                    .opacity(reduceMotion ? 0.65 : (animating ? 0.85 : 0.3))
                    .scaleEffect(reduceMotion ? 1 : (animating ? 1.15 : 0.8))
                    .animation(
                        reduceMotion ? nil
                                     : .easeInOut(duration: 0.5)
                                         .repeatForever(autoreverses: true)
                                         .delay(Double(index) * 0.16),
                        value: animating
                    )
            }
        }
        .onAppear { if !reduceMotion { animating = true } }
        .accessibilityLabel(Text("正在思考"))
    }
}
