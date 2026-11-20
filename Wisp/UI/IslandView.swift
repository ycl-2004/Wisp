import AppKit
import KeyboardShortcuts
import SwiftUI

/// 底部药丸。窗口固定不动，只有胶囊本身改变尺寸，所以内容永远有足够的宽度可画。
struct IslandView: View {
    @EnvironmentObject var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var settings = AppSettings.shared

    let notchWidth: CGFloat
    let hasNotch: Bool
    let position: ScreenGeometry.IslandPosition

    @State private var phase: CGFloat = 0

    /// KeyboardShortcuts 把标准组合直接存进 UserDefaults，不经过 AppSettings，
    /// 所以标准模式改键后要靠这条通知来重算。名字是库内部约定：万一将来对不上，
    /// 最坏情况只是药丸上的提示等到下次重建才更新，不影响唤起本身。
    private static let shortcutDidChange = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")

    @State private var shortcutRevision = 0

    /// 另外三种模式的键都存在 AppSettings 里，`settings` 是 @ObservedObject，
    /// 改动会自己触发重算，这里不需要额外的缓存或监听。
    private var shortcutLabel: String {
        switch settings.shortcutTrigger {
        case .standard:
            if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleAssistant) {
                return "\(shortcut)"
            }
            return "⌃⌥Space"
        case .enhancedSingle:
            return settings.advancedShortcut?.symbolicName(tapCount: 1) ?? "⌃⌥Space"
        case .doubleTap:
            return settings.advancedShortcut?.symbolicName(tapCount: 2) ?? "⌃⌃"
        case .tripleTap:
            return settings.advancedShortcut?.symbolicName(tapCount: 3) ?? "⌃⌃⌃"
        }
    }

    private var state: IslandLayout.State {
        IslandLayout.state(hovered: model.isHovered,
                           generating: model.isGenerating,
                           dragging: model.isDragging)
    }

    var body: some View {
        Group {
            if position == .notch {
                notchBody
            } else {
                bottomBody
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: state)
        // 只是把 body 顶一下，让 shortcutLabel 重新读一次 UserDefaults。
        .onReceive(NotificationCenter.default.publisher(for: Self.shortcutDidChange)) { _ in
            shortcutRevision &+= 1
        }
    }

    // MARK: - 底部

    private var bottomBody: some View {
        let window = IslandLayout.bottomWindowSize
        // 胶囊不再永远居中：位置由小圆的锚点决定，贴边时朝有空间的一侧展开。
        let rect = IslandLayout.capsuleRect(state, dotCenterX: model.dotCenterX)
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: window.width, height: window.height)
            ZStack {
                capsuleBackground
                content.frame(width: rect.width, height: rect.height)
            }
            .frame(width: rect.width, height: rect.height)
            .contentShape(Capsule())
            .onHover { hovering in model.setHovered(hovering) }
            .onTapGesture { PanelController.shared.show() }
            .accessibilityElement()
            .accessibilityLabel(Text("唤起助手"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { PanelController.shared.show() }
            .contextMenu { islandMenu }
            // 起手距离 4pt：点击照常打开面板，真的拖了才移动窗口。
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in IslandController.shared.dragChanged() }
                    .onEnded { _ in IslandController.shared.dragEnded() }
            )
            // IslandLayout 用 AppKit 坐标（原点左下），SwiftUI 是左上，这里换算一次。
            .offset(x: rect.minX, y: window.height - rect.maxY)
        }
        .frame(width: window.width, height: window.height)
    }

    /// 底部和刘海两种形态共用的右键菜单。
    /// 退出放最后、单独隔开，跟系统菜单的习惯一致：菜单栏图标关掉以后，
    /// 这里和设置「通用」页是仅剩的两个看得见的退出入口。
    @ViewBuilder
    private var islandMenu: some View {
        Button("唤起助手") { PanelController.shared.show() }
        // 先把面板亮出来：新对话要看得见，满额时「顶掉哪一个」的确认框也挂在面板上。
        Button("新建对话") { PanelController.shared.show { AssistantModel.shared.newConversation() } }
        Button("刷新上下文") { AssistantModel.shared.refreshContext() }
        Divider()
        Button(settings.sendScreenshot ? "不附带截图" : "附带截图") {
            AssistantModel.shared.toggleScreenshot()
        }
        Divider()
        Button("设置…") { SettingsWindowPresenter.open(using: openSettings) }
        Divider()
        QuitWispButton()
    }

    private var capsuleBackground: some View {
        ZStack {
            Capsule().fill(.regularMaterial)

            if model.isGenerating {
                Capsule().fill(Color.accentColor.opacity(0.10))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.accentColor.opacity(0.10),
                                Color.cyan.opacity(0.26),
                                Color.white.opacity(0.22),
                                Color.accentColor.opacity(0.12),
                                .clear,
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .scaleEffect(x: 0.48, y: 1.15)
                    .offset(x: phase)
                    .blur(radius: 12)
                    .clipShape(Capsule())
                    .transition(.opacity)

                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.75)
            }

            Capsule().strokeBorder(DS.specularRim, lineWidth: 0.75)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .onAppear { updateGeneratingAnimation() }
        .onChange(of: model.isGenerating) { _, _ in updateGeneratingAnimation() }
        .onChange(of: reduceMotion) { _, _ in updateGeneratingAnimation() }
    }

    private func updateGeneratingAnimation() {
        guard model.isGenerating, !reduceMotion else {
            withAnimation(.none) { phase = 0 }
            return
        }
        phase = -150
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: true)) { phase = 150 }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:       idleContent
        case .hovered:    hoverContent
        case .generating: generatingContent
        }
    }

    /// 闲置：一颗静止的标记，不跟着切应用闪。颜色说明当前能读到什么。
    private var idleContent: some View {
        Image(systemName: "sparkle.magnifyingglass")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(idleTint)
    }

    private var idleTint: Color {
        if model.isExcluded { return .orange }
        return model.canReadPageText ? .accentColor : .secondary
    }

    private var hoverContent: some View {
        HStack(spacing: 7) {
            appIcon(size: 16)
            Text(model.appName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(2)
            Text(model.hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4)
            Text(shortcutLabel)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .padding(.horizontal, 13)
    }

    private var generatingContent: some View {
        HStack(spacing: 8) {
            Text("生成中…")
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.75))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 6)
            Button { AssistantModel.shared.stopStreaming() } label: {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.85)).frame(width: 24, height: 24)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 8, height: 8)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("停止生成"))
            .help("停止生成")
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
    }

    private func appIcon(size: CGFloat) -> some View {
        Group {
            if let image = model.appIcon {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "macwindow").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .opacity(model.isExcluded ? 0.45 : 1)
    }

    // MARK: - 刘海形态

    private var notchBody: some View {
        let size = IslandLayout.notchShapeSize(state, notchWidth: notchWidth, hasNotch: hasNotch)
        let expanded = state != .idle
        return VStack {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: hasNotch ? 12 : 15, style: .continuous)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: hasNotch ? 12 : 15, style: .continuous)
                            .strokeBorder(Color.white.opacity(expanded ? 0.14 : 0.07), lineWidth: 0.5)
                    )

                VStack(spacing: 0) {
                    notchTopRow(expanded: expanded)
                    if expanded { notchDetailRow }
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onHover { hovering in model.setHovered(hovering) }
            .onTapGesture { PanelController.shared.show() }
            .accessibilityElement()
            .accessibilityLabel(Text("唤起助手"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { PanelController.shared.show() }
            // 刘海形态以前没有右键菜单，切过来之后连设置和退出都找不到。
            .contextMenu { islandMenu }
            Spacer(minLength: 0)
        }
        .frame(width: IslandLayout.notchWindowSize(notchWidth: notchWidth, hasNotch: hasNotch).width,
               height: IslandLayout.notchWindowSize(notchWidth: notchWidth, hasNotch: hasNotch).height)
    }

    private func notchTopRow(expanded: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                appIcon(size: 14)
                if expanded && !hasNotch {
                    Text(model.appName).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            Color.clear.frame(width: hasNotch ? notchWidth : 6)

            HStack(spacing: 5) {
                if expanded && hasNotch {
                    Text(model.appName).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                }
                Circle().fill(idleTint).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(height: IslandLayout.notchBarHeight)
        .padding(.horizontal, expanded ? 12 : 9)
    }

    private var notchDetailRow: some View {
        HStack(spacing: 6) {
            Text(model.isGenerating ? "生成中…" : model.hint)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 6)
            if model.isGenerating {
                Button { AssistantModel.shared.stopStreaming() } label: {
                    Text("停止").font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("停止生成"))
            } else {
                Text(shortcutLabel)
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
        .padding(.top, 2)
        .frame(height: IslandLayout.notchExpandedExtra)
    }
}
