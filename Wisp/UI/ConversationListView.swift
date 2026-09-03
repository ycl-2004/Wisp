import AppKit
import SwiftUI

/// 对话列表：搜索、切换、删除。删除是永久的，必须二次确认。
struct ConversationListView: View {
    @EnvironmentObject var model: AssistantModel
    @EnvironmentObject var store: ConversationStore
    @State private var pendingDelete: Conversation?
    @State private var searchText = ""

    private var filteredConversations: [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.conversations }
        return store.conversations.filter { conversation in
            conversation.displayTitle.lowercased().contains(query) ||
            conversation.messages.contains { $0.text.lowercased().contains(query) }
        }
    }

    var body: some View {
        // 过滤要扫每条对话的全文，body 里只算一次，别在 isEmpty 和 ForEach 各算一遍。
        let filtered = filteredConversations

        VStack(alignment: .leading, spacing: 0) {
            // 一条对话都没有的时候摆个搜索框只是占地方。
            if !store.conversations.isEmpty {
                searchBar
            }

            if let message = model.conversationLimitMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(DS.meta)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if let candidate = model.evictionCandidateTitle {
                        Button("删掉「\(candidate)」并新建") { model.confirmsEviction = true }
                            .font(DS.meta)
                    }
                }
                .padding(.horizontal, DS.gutter)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }

            if store.conversations.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("还没有历史对话。直接在下方提问就会自动建立。")
                        .font(DS.meta)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(DS.gutter)
            } else if filtered.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("未找到匹配「\(searchText)」的对话")
                        .font(DS.meta)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(DS.gutter)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filtered) { conversation in
                            Row(conversation: conversation,
                                isActive: conversation.id == store.activeID,
                                onSelect: { model.select(conversation.id) },
                                onDelete: { pendingDelete = conversation })
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
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
            Text("「\(pendingDelete?.displayTitle ?? "")」的全部消息会从本机删除，无法撤销，也没有回收站。")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("搜索对话标题或内容…", text: $searchText)
                .textFieldStyle(.plain)
                .font(DS.meta)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("清除"))
                .help("清除")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DS.chipCorner, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.chipCorner, style: .continuous)
                .strokeBorder(DS.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, DS.gutter)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private struct Row: View {
        let conversation: Conversation
        let isActive: Bool
        let onSelect: () -> Void
        let onDelete: () -> Void
        @State private var hovering = false
        @FocusState private var deleteFocused: Bool

        var body: some View {
            let icon = AppIconCache.icon(
                forBundleID: conversation.messages.first { $0.context?.bundleID != nil }?.context?.bundleID
            )

            ZStack(alignment: .trailing) {
                Button(action: onSelect) {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isActive ? Color.accentColor : Color.clear)
                            .frame(width: 2, height: 22)

                        if let icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 15, height: 15)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        } else {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .frame(width: 15, height: 15)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.displayTitle)
                                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text("\(conversation.userTurnCount) 轮")
                                Text(verbatim: "·")
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    Text(relativeTimeString(from: conversation.updatedAt,
                                                            relativeTo: context.date))
                                }
                            }
                            .font(DS.meta)
                            .foregroundStyle(.tertiary)
                        }

                        Spacer(minLength: 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .padding(.trailing, 34)
                    .background(rowBackground)
                    .overlay(rowBorder)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressFeedbackButtonStyle(pressedScale: 0.995))

                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(IconButtonStyle(size: 10))
                .focused($deleteFocused)
                .opacity(hovering || deleteFocused ? 1 : 0)
                .allowsHitTesting(hovering || deleteFocused)
                .padding(.trailing, 6)
                .accessibilityLabel(Text("永久删除"))
                .help("永久删除")
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var rowBackground: some View {
            RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.11)
                               : (hovering ? DS.cardBackground : Color.clear))
        }

        private var rowBorder: some View {
            RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.20) : Color.clear,
                              lineWidth: 0.5)
        }

        /// 两个 formatter 的构造都很贵，而列表每行都要问一次时间，必须缓存成 static。
        /// 用系统的相对时间格式器而不是自己拼字符串，这样英文界面下不会蹦出中文。
        private static let relative: RelativeDateTimeFormatter = {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return f
        }()

        private static let absolute: DateFormatter = {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("MMdd HHmm")
            return f
        }()

        private func relativeTimeString(from date: Date, relativeTo now: Date) -> String {
            let seconds = now.timeIntervalSince(date)
            if seconds < 60 { return String(localized: "刚刚") }
            if seconds < 172_800 { return Self.relative.localizedString(for: date, relativeTo: now) }
            return Self.absolute.string(from: date)
        }
    }
}
