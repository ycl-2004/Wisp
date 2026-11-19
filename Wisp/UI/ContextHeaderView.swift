import AppKit
import SwiftUI

/// 一行头部：对话记录、正在看的应用、截图开关、模型、设置、展开。
/// 不常用的东西收进别处：新建对话和计数在对话记录里，读取时间在标题的提示里，
/// 采集详情只在需要用户处理时出现。
struct ContextHeaderView: View {
    @EnvironmentObject var model: AssistantModel
    @EnvironmentObject var store: ConversationStore
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var captions = LiveCaptions.shared

    var body: some View {
        GeometryReader { geometry in
            // The captions button takes its own width (26) plus one gap (6) when voice is on.
            row(modelWidth: min(170, max(70, geometry.size.width - (captions.isEnabled ? 302 : 270))))
        }
        .frame(height: DS.headerHeight - 4)
        .padding(.horizontal, DS.gutter)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(alignment: .bottom) {
            if !model.isCollapsed {
                Rectangle().fill(DS.hairline).frame(height: 0.5)
            }
        }
    }

    private func row(modelWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Button {
                model.toggleConversationList()
            } label: {
                Image(systemName: model.showsConversationList
                      ? "chevron.left"
                      : "bubble.left.and.bubble.right")
            }
            .buttonStyle(IconButtonStyle())
            .help(model.showsConversationList ? "回到当前对话" : "对话记录")

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
            .help(titleHelp)

            if model.isCapturing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16)
            }

            if hasBlockingNote { notesButton }

            Button {
                model.toggleScreenshot()
            } label: {
                toggleChip(settings.sendScreenshot ? "camera.fill" : "camera", isOn: settings.sendScreenshot)
            }
            .buttonStyle(.plain)
            .help(screenshotChipText)
            .accessibilityLabel("附带截图")
            .accessibilityValue(settings.sendScreenshot ? "On" : "Off")
            .fixedSize()

            // Turning voice on in Settings shows this; captions themselves start here, from the
            // shortcut or from the menu bar.
            if captions.isEnabled {
                Button {
                    captions.toggleFromUser()
                } label: {
                    toggleChip(captions.isActive ? "captions.bubble.fill" : "captions.bubble", isOn: captions.isActive)
                }
                .buttonStyle(.plain)
                .help(captions.isActive ? "关闭字幕" : "打开字幕")
                .accessibilityLabel("实时字幕")
                .accessibilityValue(captions.isActive ? "On" : "Off")
                .fixedSize()
            }

            ModelSwitcher(width: modelWidth)

            // Keep settings reachable even when macOS crowds out an enabled menu item.
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle())
                .help("设置")

            Button {
                withAnimation(.easeOut(duration: 0.18)) { model.setCollapsed(!model.isCollapsed) }
            } label: {
                // The panel opens upward from its input box, so the arrow points the way it moves.
                Image(systemName: model.isCollapsed ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(IconButtonStyle())
            .help(model.isCollapsed ? "展开" : "收起")
        }
    }

    /// An icon that is tinted and backed while its switch is on.
    private func toggleChip(_ symbol: String, isOn: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isOn ? Color.blue : Color.secondary)
            .frame(width: 26, height: 22)
            .background(RoundedRectangle(cornerRadius: DS.chipCorner)
                .fill(isOn ? Color.blue.opacity(0.14) : .clear))
    }

    /// 标题的提示：这份上下文是什么时候读的、正文读到了多少。还没读过就没有提示。
    private var titleHelp: String {
        guard model.packet != nil else { return "" }
        return String(localized: "读取于：\(model.contextAge) · \(pageTextChipText)")
    }

    /// 只在需要用户动手时出现（比如去开权限）；平常的采集说明不占位置。
    private var notesButton: some View {
        Button { model.showsNotes.toggle() } label: {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Color.orange)
        }
        .buttonStyle(IconButtonStyle())
        .help("采集详情")
        .accessibilityLabel("采集详情")
        .popover(isPresented: $model.showsNotes) {
            VStack(alignment: .leading, spacing: 8) {
                if model.packet?.hasPageText == true { Text(pageTextChipText) }
                notesBlock
            }
            .font(DS.meta)
            .padding(12)
            .frame(width: 300, alignment: .leading)
            .background(ScreenPrivacyWindow())
        }
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
