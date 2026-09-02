import AppKit
import SwiftUI

/// 界面统一的尺寸、圆角、字号。集中放一处，避免各视图各写各的。
enum DS {
    static let windowCorner: CGFloat = 14
    static let cardCorner: CGFloat = 8
    static let chipCorner: CGFloat = 5

    static let gutter: CGFloat = 12
    static let rowGap: CGFloat = 8
    static let tightGap: CGFloat = 4

    static let headerHeight: CGFloat = 32
    static let metaHeight: CGFloat = 20

    static let body = Font.system(size: 13)
    static let title = Font.system(size: 12, weight: .medium)
    static let meta = Font.system(size: 10.5)
    static let label = Font.system(size: 10, weight: .medium)

    static let hairline = Color.primary.opacity(0.10)
    static let faint = Color.primary.opacity(0.05)
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
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
            .frame(width: size + 12, height: size + 12)
            .background(
                RoundedRectangle(cornerRadius: DS.chipCorner, style: .continuous)
                    .fill(hovering ? DS.faint : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
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
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .medium))
            }
            Text(text).font(DS.meta)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
        .background(
            RoundedRectangle(cornerRadius: DS.chipCorner, style: .continuous)
                .fill(active ? Color.accentColor.opacity(hovering ? 0.20 : 0.13)
                             : Color.primary.opacity(hovering ? 0.10 : 0.06))
        )
        .contentShape(Rectangle())
        .onHover { hovering = enabled && $0 }
        .onTapGesture { if enabled { action?() } }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: active)
    }
}

/// 顶部与底部的渐隐，让滚动内容不硬切在分隔线上。
struct EdgeFade: View {
    var edge: UnitPoint = .top
    var height: CGFloat = 14

    var body: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.10), Color.black.opacity(0)],
            startPoint: edge,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: height)
        .blendMode(.destinationOut)
        .allowsHitTesting(false)
    }
}
