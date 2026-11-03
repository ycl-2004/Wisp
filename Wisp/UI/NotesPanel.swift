import AppKit
import SwiftUI

/// 录制演示时的提词笔记：一个独立的小浮窗，写讲稿要点和备用台词。
/// 与主面板完全隔离——不参与上下文采集，不进对话记录，也没有发送动作。
///
/// 隐私行为（有意与主面板一致）：窗口走 `ScreenPrivacy.apply(to:)`。
/// 「共享时隐藏」开着时，笔记留在讲者自己的屏幕上、但不进共享和录屏画面，
/// 这正是提词器的用法；关着时它和其它 Wisp 窗口一样会出现在共享里。
@MainActor
final class NotesPanelController: NSObject, NSWindowDelegate {
    static let shared = NotesPanelController()

    private var panel: NSPanel?
    private var frameSaveTimer: Timer?
    private var pendingFrameString: String?

    static let defaultSize = CGSize(width: 320, height: 260)
    static let minimumSize = CGSize(width: 220, height: 140)

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        ensurePanel().orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        // 与主面板相同的取向：无边框、不抢焦点的浮窗。系统缩放关掉，
        // 缩放交给 PanelResizeOverlay（和主面板同一套几何）。
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = Self.minimumSize
        panel.delegate = self
        ScreenPrivacy.apply(to: panel)

        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        let hosting = NSHostingView(rootView: NotesView())
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let resize = PanelResizeOverlay(frame: container.bounds)
        resize.autoresizingMask = [.width, .height]
        container.addSubview(resize)
        panel.contentView = container

        panel.setFrame(restoredFrame() ?? defaultFrame(), display: false)
        self.panel = panel
        return panel
    }

    /// 默认停在当前屏幕右上角、菜单栏下面一点，避开底部中央的主面板。
    private func defaultFrame() -> NSRect {
        guard let screen = ScreenGeometry.activeScreen ?? NSScreen.main else {
            return NSRect(origin: .zero, size: Self.defaultSize)
        }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.maxX - Self.defaultSize.width - 16,
                             y: visible.maxY - Self.defaultSize.height - 12)
        return ScreenGeometry.clamp(NSRect(origin: origin, size: Self.defaultSize), on: screen)
    }

    private func restoredFrame() -> NSRect? {
        guard let saved = AppSettings.shared.notesPanelFrame else { return nil }
        let rect = NSRectFromString(saved)
        guard rect.width >= Self.minimumSize.width,
              rect.height >= Self.minimumSize.height else { return nil }
        return rect
    }

    // MARK: - 位置与尺寸落盘（与 PanelController 相同的 0.2 秒去抖）

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }
    func windowDidEndLiveResize(_ notification: Notification) { flushFrameSave() }

    private func scheduleFrameSave() {
        guard let panel else { return }
        pendingFrameString = NSStringFromRect(panel.frame)
        frameSaveTimer?.invalidate()
        frameSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushFrameSave() }
        }
    }

    private func flushFrameSave() {
        frameSaveTimer?.invalidate()
        frameSaveTimer = nil
        guard let pendingFrameString else { return }
        AppSettings.shared.notesPanelFrame = pendingFrameString
        self.pendingFrameString = nil
    }
}

/// 笔记正文：纯文本，边写边存（UserDefaults），没有单独的保存动作，也没有富文本和同步。
struct NotesView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow)

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("录制笔记")
                        .font(DS.title)
                    Spacer(minLength: 0)
                    Button { NotesPanelController.shared.hide() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle(size: 9))
                    .help("关闭笔记面板")
                    .accessibilityLabel(Text("关闭笔记面板"))
                }
                .padding(.horizontal, DS.gutter)
                .padding(.top, 8)
                .padding(.bottom, 4)

                TextEditor(text: Binding(
                    get: { settings.notesText },
                    set: { settings.notesText = $0 }
                ))
                .font(DS.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, DS.gutter - 5)
                .padding(.bottom, 8)
                .overlay(alignment: .topLeading) {
                    if settings.notesText.isEmpty {
                        Text("演示时要讲的要点写在这里…")
                            .font(DS.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, DS.gutter)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.windowCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.windowCorner, style: .continuous)
                .strokeBorder(DS.specularRim, lineWidth: 0.75)
        )
    }
}
