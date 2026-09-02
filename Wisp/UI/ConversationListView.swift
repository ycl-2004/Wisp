import SwiftUI

/// 对话列表：切换、删除。删除是永久的，必须二次确认。
struct ConversationListView: View {
    @EnvironmentObject var model: AssistantModel
    @EnvironmentObject var store: ConversationStore
    @State private var pendingDelete: Conversation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = model.conversationLimitMessage {
                Text(message)
                    .font(DS.meta)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.gutter)
                    .padding(.top, 8)
            }

            if store.conversations.isEmpty {
                Text("还没有对话。直接在下面提问就会自动建一个。")
                    .font(DS.meta)
                    .foregroundStyle(.secondary)
                    .padding(DS.gutter)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.conversations) { conversation in
                            Row(conversation: conversation,
                                isActive: conversation.id == store.activeID,
                                onSelect: { model.select(conversation.id) },
                                onDelete: { pendingDelete = conversation })
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxHeight: .infinity)
        .alert("永久删除这个对话？",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let target = pendingDelete { model.delete(target.id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("「\(pendingDelete?.title ?? "")」的全部消息会从本机删除，无法撤销，也没有回收站。")
        }
    }

    private struct Row: View {
        let conversation: Conversation
        let isActive: Bool
        let onSelect: () -> Void
        let onDelete: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .frame(width: 2, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title)
                        .font(.system(size: 12, weight: isActive ? .medium : .regular))
                        .lineLimit(1)
                    Text("\(conversation.userTurnCount) 轮 · \(Self.formatter.string(from: conversation.updatedAt))")
                        .font(DS.meta)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(.system(size: 10))
                    }
                    .buttonStyle(IconButtonStyle(size: 10))
                    .help("永久删除")
                }
            }
            .padding(.vertical, 5)
            .padding(.trailing, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.10)
                                   : (hovering ? DS.faint : Color.clear))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onSelect)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            return f
        }()
    }
}
