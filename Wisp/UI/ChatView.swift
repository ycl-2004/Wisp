import AppKit
import SwiftUI

struct ChatView: View {
    @EnvironmentObject var model: AssistantModel
    @EnvironmentObject var store: ConversationStore
    @State private var focusRequest = 0
    @State private var inputHeight = ChatInput.defaultHeight

    /// 到轮次上限或对话数上限时不让继续输入。
    private var inputDisabled: Bool {
        if let conversation = store.active { return store.isAtTurnLimit(conversation) }
        return !store.canCreateNew
    }

    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow)
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.windowCorner, style: .continuous))
        // specularRim 本身就是上亮下暗，再叠一层纯黑描边只会让边框发闷。
        .overlay(
            RoundedRectangle(cornerRadius: DS.windowCorner, style: .continuous)
                .strokeBorder(DS.specularRim, lineWidth: 0.75)
        )
        .onHover { inside in
            PanelController.shared.setPointerInside(inside)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wispPanelDidShow)) { _ in
            focusRequest += 1
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ContextHeaderView()

            if !model.isCollapsed {
                Group {
                    if model.showsConversationList {
                        ConversationListView()
                    } else {
                        messageList
                    }
                }
                .transition(.opacity)
            }

            composer
        }
        // 挂在这里而不是对话列表上：面板收起时列表根本没上屏，
        // 挂在列表上的话满额时点新建不会有任何反应。
        .alert("腾出位置新建对话？", isPresented: $model.confirmsEviction) {
            Button("删掉最旧的并新建", role: .destructive) { model.evictOldestAndCreate() }
            Button("取消", role: .cancel) { model.confirmsEviction = false }
        } message: {
            Text("「\(model.evictionCandidateTitle ?? "")」是最久没更新的那个，它会被永久删除，无法撤销。")
        }
    }

    // MARK: - 消息

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let conversation = store.active, !conversation.messages.isEmpty {
                        let messages = conversation.messages
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            let isLast = (index == messages.count - 1)
                            MessageRow(message: message, isLast: isLast).id(message.id)
                        }
                    } else {
                        ChatEmptyStateView()
                    }

                    // 上次读盘出过问题就摆在最显眼的地方，不静默吞掉。
                    if let issue = store.loadIssue {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(issue.message)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("知道了") { store.dismissLoadIssue() }
                        }
                        .font(DS.meta)
                    }

                    if let error = model.errorText {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(DS.meta)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Color.clear.frame(height: 2).id("bottom")
                }
                .padding(.horizontal, DS.gutter)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)
            .onChange(of: store.active?.messages.last?.text) {
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.activeID) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
        .mask(
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.95),
                .init(color: .black.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - 输入

    private var composer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let limit = model.turnLimitMessage ?? (store.active == nil ? model.conversationLimitMessage : nil) {
                Text(limit)
                    .font(DS.meta)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .bottom, spacing: 6) {
                ChatInput(text: $model.input,
                          placeholder: String(localized: "问点什么…  Return 发送，Shift+Return 换行"),
                          isEnabled: !inputDisabled,
                          onSubmit: { model.send() },
                          onEscape: { PanelController.shared.hide() },
                          focusRequest: $focusRequest,
                          measuredHeight: $inputHeight)
                    .frame(height: inputHeight)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                            .strokeBorder(DS.hairline, lineWidth: 0.5)
                    )

                sendButton
            }
        }
        .padding(.horizontal, DS.gutter)
        .padding(.vertical, 9)
        .background(alignment: .top) {
            if !model.isCollapsed {
                Rectangle().fill(DS.hairline).frame(height: 0.5)
            }
        }
    }

    /// 当前在用哪家、哪个模型。放在发送键的提示里，不占版面。
    private var providerLabel: String {
        let settings = AppSettings.shared
        switch ProviderKind.current {
        case .openAICompatible:
            return settings.model.isEmpty ? "云端接口" : settings.model
        case .ollama:
            return settings.ollamaModel.isEmpty ? String(localized: "Ollama（未选模型）") : "Ollama · \(settings.ollamaModel)"
        case .codexCLI:
            let cli = settings.cliProvider.title
            let model: String
            switch settings.cliProvider {
            case .codex:      model = settings.codexModel
            case .agy:        model = settings.agyModel
            case .claudeCode: model = settings.claudeCodeModel
            }
            return model.isEmpty ? cli : "\(cli) · \(model)"
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if model.isStreaming {
            Button { model.stopStreaming() } label: {
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 27, height: 27)
                    .background(Circle().fill(Color.secondary))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("停止（⌘.）")
        } else {
            Button { model.send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(model.canSend ? Color.white : Color.secondary)
                    .frame(width: 27, height: 27)
                    .background(
                        Circle().fill(model.canSend ? Color.accentColor : Color.primary.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("发送（⌘↩）· \(providerLabel)")
            .animation(.easeOut(duration: 0.12), value: model.canSend)
        }
    }
}

// MARK: - 空状态（智能上下文与建议问题）

/// 也被 IslandRenderer 拿去离线出图，所以不是 private。
struct ChatEmptyStateView: View {
    @EnvironmentObject var model: AssistantModel

    private var appName: String {
        model.packet?.appName ?? String(localized: "当前应用")
    }

    private var isBrowser: Bool {
        guard let bundleID = model.packet?.bundleID?.lowercased() else { return false }
        return bundleID.contains("chrome") || bundleID.contains("safari") ||
               bundleID.contains("arc") || bundleID.contains("edge") ||
               bundleID.contains("firefox") || bundleID.contains("brave")
    }

    private var isDevTool: Bool {
        guard let bundleID = model.packet?.bundleID?.lowercased() else { return false }
        return bundleID.contains("xcode") || bundleID.contains("vscode") ||
               bundleID.contains("terminal") || bundleID.contains("iterm") ||
               bundleID.contains("warp") || bundleID.contains("cursor")
    }

    private var suggestions: [Suggestion] {
        if isBrowser {
            return [
                Suggestion(icon: "list.bullet.rectangle", title: "提炼本页核心结论",
                           prompt: String(localized: "请提炼当前网页的核心要点和关键结论，分条列出。")),
                Suggestion(icon: "tablecells", title: "提取关键数据",
                           prompt: String(localized: "请从当前页面中提取关键事实、数据或步骤清单。")),
                Suggestion(icon: "character.bubble", title: "翻译并梳理逻辑",
                           prompt: String(localized: "请简述并翻译当前页面的主要脉络，用清晰中文说明。")),
            ]
        } else if isDevTool {
            return [
                Suggestion(icon: "curlybraces", title: "解释当前代码或报错",
                           prompt: String(localized: "请分析当前窗口中的代码或报错信息，指出其核心原因。")),
                Suggestion(icon: "ladybug", title: "找出潜在问题",
                           prompt: String(localized: "请检查当前代码是否存在潜在缺陷或边缘情况，并给出修复方案。")),
                Suggestion(icon: "wand.and.stars", title: "重构优化建议",
                           prompt: String(localized: "针对当前窗口里的实现，提供更简洁、高性能的重构建议。")),
            ]
        } else {
            return [
                Suggestion(icon: "list.bullet.rectangle", title: "梳理当前屏幕内容",
                           prompt: String(localized: "请梳理当前窗口呈现的核心内容，帮我快速把握重点。")),
                Suggestion(icon: "checklist", title: "总结要点与待办",
                           prompt: String(localized: "从当前屏幕中提取重要信息，整理成清晰的要点与待办事项。")),
            ]
        }
    }

    private var canUseSuggestions: Bool {
        model.canStartQuestion && model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("问点关于「\(appName)」的事")
                        .font(.system(size: 13, weight: .medium))
                    Text("Wisp 会在发送时读取当前窗口的截图与正文上下文，直接提问即可。")
                        .font(DS.meta)
                        .foregroundStyle(.secondary)
                }
            }

            // 快捷问题建议胶囊
            VStack(alignment: .leading, spacing: 6) {
                Text("建议提问：")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 6) {
                    ForEach(suggestions) { item in
                        SuggestionChip(icon: item.icon, title: item.title) {
                            model.input = item.prompt
                            model.send()
                        }
                        // 不覆盖用户已经写好的草稿；不可用时明确压暗，而不是点了才发现内容丢了。
                        .disabled(!canUseSuggestions)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 4)
    }
}

private struct Suggestion: Identifiable {
    let icon: String
    let title: LocalizedStringKey
    let prompt: String
    var id: String { prompt }
}

/// 空状态里的建议胶囊。hover 时描边和底色一起跟上，让它看起来确实可以点；
/// 发不出去的时候整体压暗，而不是点了没反应。
private struct SuggestionChip: View {
    let icon: String
    let title: LocalizedStringKey
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(DS.meta)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.primary.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.chipCorner, style: .continuous)
                    .fill(hovering ? DS.accentFaint : DS.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.chipCorner, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.30) : DS.hairline,
                                  lineWidth: 0.5)
            )
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = isEnabled && $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - 单条消息

private struct MessageRow: View {
    let message: Message
    var isLast: Bool = false
    @EnvironmentObject var model: AssistantModel
    @State private var showsContext = false
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Group {
            if message.role == .user {
                userCard
            } else {
                assistantCard
            }
        }
        .onHover { hovering = $0 }
    }

    // 用户消息：精美轻量卡片
    private var userCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Text(message.text)
                .font(DS.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 0.5)
        )
    }

    // 助手消息：通栏 Markdown
    private var assistantCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if showsContext, let context = message.context {
                ScrollView {
                    Text(PromptBuilder.contextBlock(context, full: true))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                        .fill(DS.faint)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                        .strokeBorder(DS.hairline, lineWidth: 0.5)
                )
            }

            if message.text.isEmpty && message.role == .assistant {
                HStack(spacing: 7) {
                    PulsingDots()
                    Text("正在思考…")
                        .font(DS.meta)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                MarkdownText(raw: message.text, showsCaret: isLast && model.isStreaming)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1)
                .fill(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: 2, height: 11)

            Text(message.role == .user ? "你" : "助手")
                .font(DS.label)
                .foregroundStyle(message.role == .user ? Color.accentColor : Color.secondary)

            if message.sentScreenshot {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .help("这一轮附了截图")
            }

            Spacer(minLength: 0)

            if message.context != nil {
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { showsContext.toggle() }
                } label: {
                    Text(showsContext ? "隐藏上下文" : "上下文").font(.system(size: 9.5))
                }
                .buttonStyle(PressFeedbackButtonStyle())
                .foregroundStyle(.tertiary)
                .opacity(hovering || showsContext ? 1 : 0.52)
                .help(showsContext ? "隐藏上下文" : "上下文")
            }

            if message.role == .assistant, !message.text.isEmpty {
                Button {
                    model.copyToPasteboard(message.text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        if copied {
                            Text("已复制").font(.system(size: 9))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(copied ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.accentColor : Color.secondary.opacity(0.7))
                .contentShape(Rectangle())
                .accessibilityLabel(Text("复制回答"))
                .help("复制回答")
            }
        }
        .frame(minHeight: 16)
    }
}
