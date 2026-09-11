import AppKit
import SwiftUI

/// 标题与共享快捷控制两行；录音时第二行让位给语音，采集详情使用弹窗。
struct ContextHeaderView: View {
    @EnvironmentObject var model: AssistantModel
    @EnvironmentObject var store: ConversationStore
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var listening = ListeningModel.shared
    @ObservedObject private var pushToTalk = PushToTalk.shared
    @AppStorage("settingsTab") private var settingsTab: SettingsView.Tab = .model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            metaRow
        }
        .padding(.horizontal, DS.gutter)
        .padding(.top, 7)
        .padding(.bottom, 5)
        .background(alignment: .bottom) {
            if !model.isCollapsed {
                Rectangle().fill(DS.hairline).frame(height: 0.5)
            }
        }
    }

    // MARK: - 第一行

    private var titleRow: some View {
        HStack(spacing: 6) {
            Button {
                model.toggleConversationList()
            } label: {
                Image(systemName: model.showsConversationList
                      ? "chevron.left"
                      : "bubble.left.and.bubble.right")
            }
            .buttonStyle(IconButtonStyle())
            .help(model.showsConversationList
                  ? "回到当前对话"
                  : "对话记录（\(store.conversations.count)/\(store.maxConversations)），可切换和删除")

            // 图标到右边控件之间这一段是这个无边框面板的标题栏：拖它可以把窗口挪走。
            HStack(spacing: 6) {
                appIcon
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))

                Text(model.packet?.appName ?? model.targetApp?.localizedName ?? "Wisp")
                    .font(DS.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if let subtitle {
                    HStack(spacing: 4) {
                        Text(verbatim: "·").font(DS.meta).foregroundStyle(.tertiary)
                        Text(subtitle)
                            .font(DS.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 2)
            }
            .background(WindowDragArea())
            .help("拖这里可以移动面板")

            if model.isCapturing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16)
            } else if model.packet != nil {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(model.contextAge(relativeTo: context.date))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }

            Button { model.refreshContext() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButtonStyle())
                .help("重新读取当前屏幕（\(model.contextAge)）")
                .disabled(model.isCapturing)

            Button { model.newConversation() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(IconButtonStyle())
                .help(store.canCreateNew ? "新建对话" : "已达上限，可移除最早的对话后新建")

            // Keep settings reachable even when macOS crowds out an enabled menu item.
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle())
                .help("设置")

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
            if let icon = AppIconCache.icon(forBundleID: model.packet?.bundleID) {
                Image(nsImage: icon).resizable()
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
        GeometryReader { geometry in
            if listening.isActive || pushToTalk.isActive {
                ListeningView()
            } else {
                metaContent(modelWidth: min(200, max(60, geometry.size.width - 250)))
            }
        }
        .frame(height: 30)
    }

    private func metaContent(modelWidth: CGFloat) -> some View {
        HStack(spacing: DS.tightGap) {
            ListeningView()
                .fixedSize()

            Button {
                model.toggleScreenshot()
            } label: {
                Image(systemName: settings.sendScreenshot ? "camera.fill" : "camera")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(settings.sendScreenshot ? Color.blue : Color.secondary)
                    .frame(width: 26, height: 24)
                    .background(RoundedRectangle(cornerRadius: DS.chipCorner)
                        .fill(settings.sendScreenshot ? Color.blue.opacity(0.14) : .clear))
            }
            .buttonStyle(.plain)
            .help(screenshotChipText)
            .accessibilityLabel("附带截图")
            .accessibilityValue(settings.sendScreenshot ? "On" : "Off")
            .fixedSize()

            if !notes.isEmpty || model.packet?.hasPageText == true {
                Button { model.showsNotes.toggle() } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(hasBlockingNote ? Color.orange : Color.secondary)
                }
                .buttonStyle(IconButtonStyle())
                .help("采集详情")
                .accessibilityLabel("采集详情")
                .popover(isPresented: $model.showsNotes) {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.packet?.hasPageText == true { Text(pageTextChipText) }
                        if !notes.isEmpty { notesBlock }
                    }
                    .font(DS.meta)
                    .padding(12)
                    .frame(width: 300, alignment: .leading)
                    .background(ScreenPrivacyWindow())
                }
            }

            Spacer(minLength: 4)

            ModelSwitcher(width: modelWidth)
            Text(counters)
                .font(DS.meta.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            if listening.isEnabled {
                Button {
                    settingsTab = .audio
                    openSettings()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(IconButtonStyle())
                .help("音频设置…")
                .accessibilityLabel("音频设置…")
            }
        }
    }

    private var counters: String {
        let turns = store.active?.userTurnCount ?? 0
        return "\(turns)/\(store.maxUserTurns) · \(store.conversations.count)/\(store.maxConversations)"
    }

    private var screenshotChipText: String {
        guard let packet = model.packet else { return String(localized: "截图") }
        if packet.isExcluded { return String(localized: "已停用") }
        guard packet.hasScreenshot else { return String(localized: "无截图") }
        guard settings.sendScreenshot else { return String(localized: "截图 关") }
        return packet.screenshotScope == .screen ? String(localized: "截图 · 整个屏幕") : String(localized: "截图")
    }

    private var pageTextChipText: String {
        guard let packet = model.packet else { return String(localized: "正文") }
        if packet.isExcluded { return String(localized: "正文 停用") }
        guard let text = packet.pageText, !text.isEmpty else {
            return BrowserTextExtractor.family(for: packet.bundleID) == nil
                ? String(localized: "无整页正文")
                : String(localized: "正文 未取到")
        }
        return packet.isTruncated
            ? String(localized: "正文 \(text.count) 字 · 截断")
            : String(localized: "正文 \(text.count) 字")
    }

    // MARK: - 说明

    private var notes: [CaptureNote] { model.packet?.notes ?? [] }

    /// 需要用户去动手才能解决的问题，这类默认要显眼一点。
    private var hasBlockingNote: Bool {
        notes.contains(where: \.needsUserAction)
    }

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                Text(note.text)
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
