import AppKit
import SwiftUI

struct ChatView: View {
    @EnvironmentObject var model: AssistantModel
    @EnvironmentObject var store: ConversationStore
    @State private var focusRequest = 0

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
        .overlay(
            RoundedRectangle(cornerRadius: DS.windowCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
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
    }

    // MARK: - 消息

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let conversation = store.active, !conversation.messages.isEmpty {
                        ForEach(conversation.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                    } else {
                        emptyState
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
                .init(color: .black, location: 0.94),
                .init(color: .black.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("问点关于当前屏幕的事").font(.system(size: 13, weight: .medium))
            Text("头部那两行就是这次会发送的内容。浏览器里会连整页正文一起发，不只是看得见的那一屏。")
                .font(DS.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("当前用 \(providerLabel)")
                .font(DS.meta)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
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
                          focusRequest: $focusRequest)
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
            Rectangle().fill(DS.hairline).frame(height: 0.5)
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
            return settings.codexModel.isEmpty ? "Codex CLI" : "Codex CLI · \(settings.codexModel)"
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if model.isStreaming {
            Button { model.stopStreaming() } label: {
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.secondary))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("停止（⌘.）")
        } else {
            Button { model.send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(model.canSend ? Color.white : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(model.canSend ? Color.accentColor : Color.primary.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("发送（⌘↩）· \(providerLabel)")
            .animation(.easeOut(duration: 0.12), value: model.canSend)
        }
    }
}

// MARK: - 单条消息

private struct MessageRow: View {
    let message: Message
    @EnvironmentObject var model: AssistantModel
    @State private var showsContext = false
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header

            if showsContext, let context = message.context {
                ScrollView {
                    Text(PromptBuilder.contextBlock(context, full: true))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(7)
                }
                .frame(maxHeight: 180)
                .background(RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous).fill(DS.faint))
            }

            if message.text.isEmpty && message.role == .assistant {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("思考中…").font(DS.meta).foregroundStyle(.secondary)
                }
            } else if message.role == .assistant {
                MarkdownText(raw: message.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(message.text)
                    .font(DS.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onHover { hovering = $0 }
    }

    /// 用一条竖线和一个小标签区分角色，不用整块底色，长时间看不累。
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

            if hovering {
                if message.context != nil {
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) { showsContext.toggle() }
                    } label: {
                        Text(showsContext ? "隐藏上下文" : "上下文").font(.system(size: 9.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
                if message.role == .assistant, !message.text.isEmpty {
                    Button {
                        model.copyToPasteboard(message.text)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("复制回答")
                }
            }
        }
        .frame(height: 12)
    }
}
