import AppKit
import SwiftUI

/// 两行头部：第一行是当前在读哪个页面，第二行是这次会发送什么 + 轮次计数。
/// 目标是把原来那一大块信息压到 52pt 以内，并且不用手动点刷新。
struct ContextHeaderView: View {
    @EnvironmentObject var model: AssistantModel
    @EnvironmentObject var store: ConversationStore
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            metaRow
            if model.showsNotes, !notes.isEmpty {
                notesBlock
            }
        }
        .padding(.horizontal, DS.gutter)
        .padding(.top, 7)
        .padding(.bottom, 5)
        .background(alignment: .bottom) {
            Rectangle().fill(DS.hairline).frame(height: 0.5)
        }
    }

    // MARK: - 第一行

    private var titleRow: some View {
        HStack(spacing: 6) {
            Button {
                model.showsConversationList.toggle()
            } label: {
                Image(systemName: model.showsConversationList
                      ? "chevron.left"
                      : "bubble.left.and.bubble.right")
            }
            .buttonStyle(IconButtonStyle())
            .help(model.showsConversationList
                  ? "回到当前对话"
                  : "对话记录（\(store.conversations.count)/\(store.maxConversations)），可切换和删除")

            appIcon

            Text(model.packet?.appName ?? "读取中…")
                .font(DS.title)
                .lineLimit(1)
                .fixedSize()

            if let subtitle {
                Text(subtitle)
                    .font(DS.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 2)

            if model.isCapturing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16)
            }

            Button { model.refreshContext() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButtonStyle())
                .help("重新读取当前屏幕（\(model.contextAge)）")
                .disabled(model.isCapturing)

            Button { model.newConversation() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(IconButtonStyle())
                .disabled(!store.canCreateNew)
                .help(store.canCreateNew ? "新建对话" : "已达对话数上限，请先删除一个")

            Button {
                withAnimation(.easeOut(duration: 0.18)) { model.setCollapsed(!model.isCollapsed) }
            } label: {
                Image(systemName: model.isCollapsed ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(IconButtonStyle())
            .help(model.isCollapsed ? "展开" : "收起")
        }
        .frame(height: DS.headerHeight - 8)
    }

    private var appIcon: some View {
        Group {
            if let bundleID = model.packet?.bundleID,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.tertiary)
            }
        }
        .frame(width: 15, height: 15)
    }

    private var subtitle: String? {
        guard let packet = model.packet else { return nil }
        if packet.isExcluded { return "已排除" }
        if let url = packet.url, !url.isEmpty { return shortURL(url) }
        if let title = packet.windowTitle, !title.isEmpty { return title }
        return nil
    }

    private func shortURL(_ raw: String) -> String {
        guard let components = URLComponents(string: raw), let host = components.host else { return raw }
        let path = components.path == "/" ? "" : components.path
        return host.replacingOccurrences(of: "www.", with: "") + path
    }

    // MARK: - 第二行

    private var metaRow: some View {
        HStack(spacing: 5) {
            Chip(icon: "camera.viewfinder",
                 text: screenshotChipText,
                 active: model.packet?.hasScreenshot == true && settings.sendScreenshot,
                 enabled: model.packet?.hasScreenshot == true) {
                model.toggleScreenshot()
            }
            .help("点一下切换这次要不要附截图")

            Chip(icon: "doc.plaintext",
                 text: pageTextChipText,
                 active: model.packet?.hasPageText == true,
                 enabled: false)

            if !notes.isEmpty {
                Chip(icon: hasBlockingNote ? "exclamationmark.triangle" : "info.circle",
                     text: "\(notes.count)",
                     active: hasBlockingNote) {
                    withAnimation(.easeOut(duration: 0.14)) { model.showsNotes.toggle() }
                }
                .help("查看这次采集的说明")
            }

            Spacer(minLength: 4)

            ModelSwitcher()

            Text(counters)
                .font(DS.meta)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .help("本对话 \(store.active?.userTurnCount ?? 0)/\(store.maxUserTurns) 轮 · 共 \(store.conversations.count)/\(store.maxConversations) 个对话")
        }
        .frame(height: DS.metaHeight)
    }

    private var counters: String {
        let turns = store.active?.userTurnCount ?? 0
        return "\(turns)/\(store.maxUserTurns) · \(store.conversations.count)/\(store.maxConversations)"
    }

    private var screenshotChipText: String {
        guard let packet = model.packet else { return "截图" }
        if packet.isExcluded { return "已停用" }
        guard packet.hasScreenshot else { return "无截图" }
        return settings.sendScreenshot ? "截图" : "截图 关"
    }

    private var pageTextChipText: String {
        guard let packet = model.packet else { return "正文" }
        if packet.isExcluded { return "正文 停用" }
        guard let text = packet.pageText, !text.isEmpty else {
            return BrowserTextExtractor.family(for: packet.bundleID) == nil ? "无整页正文" : "正文 未取到"
        }
        return packet.isTruncated ? "正文 \(text.count) 字 · 截断" : "正文 \(text.count) 字"
    }

    // MARK: - 说明

    private var notes: [String] { model.packet?.notes ?? [] }

    /// 需要用户去动手才能解决的问题，这类默认要显眼一点。
    private var hasBlockingNote: Bool {
        notes.contains { $0.contains("权限") || $0.contains("Allow JavaScript") }
    }

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                Text(note)
                    .font(DS.meta)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous).fill(DS.faint))
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}
