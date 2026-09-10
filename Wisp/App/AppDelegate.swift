import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let responseQuick = Self("responseQuick")
    static let responseDeep = Self("responseDeep")
    static let toggleListening = Self("toggleListening", default: .init(.r, modifiers: [.control, .option]))
    static let stageListening = Self("stageListening", default: .init(.d, modifiers: [.control, .option]))
    static let analyzeListening = Self("analyzeListening", default: .init(.a, modifiers: [.control, .option]))
    static let stopAndAnalyzeListening = Self("stopAndAnalyzeListening",
                                              default: .init(.return, modifiers: [.control, .option]))
    static let toggleAssistant = Self("toggleAssistant",
                                      default: .init(.space, modifiers: [.control, .option]))
}

final class AppDelegate: NSObject, NSApplicationDelegate {

#if DEBUG && WISP_DIAGNOSTICS
    static let remoteShowNotification = Notification.Name("com.yichenlin.Wisp.show")
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 诊断入口要求 DEBUG 和显式 WISP_DIAGNOSTICS；普通 Debug 也不开放。
        // 日常版本里留着它们等于把已经拿到的
        // 屏幕录制授权借给任何本地进程：`Wisp --dump-context` 就能把当前屏幕
        // 截图和整页正文写到一个固定路径，`--show` 还能被任意 App 远程触发采集。
#if DEBUG && WISP_DIAGNOSTICS
        // 用法：.../MacOS/Wisp --dump-context
        if CommandLine.arguments.contains("--dump-context") {
            runContextDump()
            return
        }

        // 把药丸的三种状态离线渲染成图片，用来在没有录屏权限时检查排版。
        // 用法：.../MacOS/Wisp --render-island ~/Desktop/island.png
        if let index = CommandLine.arguments.firstIndex(of: "--render-island") {
            let path = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1]
                : NSHomeDirectory() + "/Desktop/island.png"
            MainActor.assumeIsolated { IslandRenderer.render(to: path) }
            NSApp.terminate(nil)
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--render-header") {
            let path = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1]
                : NSHomeDirectory() + "/Desktop/header.png"
            MainActor.assumeIsolated { IslandRenderer.renderHeader(to: path) }
            NSApp.terminate(nil)
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--render-settings") {
            let path = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1]
                : NSHomeDirectory() + "/Desktop/settings.png"
            MainActor.assumeIsolated { IslandRenderer.renderSettings(to: path) }
            NSApp.terminate(nil)
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--render-chat") {
            let path = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1]
                : NSHomeDirectory() + "/Desktop/chat.png"
            MainActor.assumeIsolated { IslandRenderer.renderChat(to: path) }
            NSApp.terminate(nil)
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--render-markdown") {
            let path = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1]
                : NSHomeDirectory() + "/Desktop/markdown.png"
            MainActor.assumeIsolated { IslandRenderer.renderMarkdownSample(to: path) }
            NSApp.terminate(nil)
            return
        }

        // 让另一个进程能远程唤起浮窗，方便在没有快捷键的情况下测试。
        // DistributedNotificationCenter 不校验发送方，所以这条通道只在 Debug 存在。
        if CommandLine.arguments.contains("--show") {
            DistributedNotificationCenter.default().postNotificationName(
                Self.remoteShowNotification, object: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Self.remoteShowNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PanelController.shared.show() }
        }
#endif

        // 0.2.x 只存一份 API Key，不分服务商。升上来时把它记到当时实际在用的那家名下，
        // 否则设置页按新账号名去读会读成空，用户会以为 Key 丢了。
        KeychainStore.migrateLegacyKeyIfNeeded {
            AppSettings.shared.adoptLegacyCloudConfig()
        }

        // 首次启动时把屏幕录制授权框弹出来，别等到用户第一次按快捷键才发现没权限。
        if !Permissions.hasScreenRecording {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Permissions.requestScreenRecording()
            }
        }

        MainActor.assumeIsolated {
            // 先于任何窗口显示：晚一轮 runloop 就够被录进去一帧。
            ScreenPrivacy.start()
            PanelController.shared.restoreStoredFrame()
            IslandController.shared.start()
            // 菜单栏图标关着的时候，启动完成后什么都不显示等于「打开了但找不到」。
            // 这时候先把面板亮出来，设置也能从它的齿轮进。
            if !AppSettings.shared.showsMenuBarIcon { PanelController.shared.show() }
        }

        // 启动更新检查默认关闭，用户可以在设置里主动开启。
        // 只请求一次版本号，不带任何标识信息，也不自动下载。
        if AppSettings.shared.checkForUpdates {
            Task { @MainActor in
                if case .available(let latest) = await UpdateChecker.check() {
                    UpdateNotice.shared.availableVersion = latest
                }
            }
        }

        KeyboardShortcuts.onKeyUp(for: .toggleAssistant) {
            guard AppSettings.shared.shortcutTrigger == .standard else { return }
            Task { @MainActor in
                PanelController.shared.toggle()
            }
        }

        for (name, mode) in [(KeyboardShortcuts.Name.responseQuick, ResponseMode.quick),
                             (.responseDeep, .deep)] {
            KeyboardShortcuts.onKeyUp(for: name) {
                Task { @MainActor in AppSettings.shared.responseMode = mode }
            }
        }

        onListeningShortcut(.toggleListening) { $0.toggleFromUser() }
        onListeningShortcut(.stageListening) { $0.stageRecentSpeech() }
        onListeningShortcut(.analyzeListening) { $0.analyzeRecentSpeech() }
        onListeningShortcut(.stopAndAnalyzeListening) { $0.stopAndAnalyze() }

        AdvancedShortcutMonitor.shared.configure {
            Task { @MainActor in
                PanelController.shared.toggle()
            }
        }

        // SwiftUI 的 Menu 每次打开都重建菜单项，所以每次都要重新贴一遍快捷键提示。
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { notif in
            guard let menu = notif.object as? NSMenu else { return }
            MainActor.assumeIsolated { Self.annotateSummonItem(menu) }
        }
    }

    /// 在「唤起助手」那一项右侧补上当前的快捷键。
    ///
    /// 只有标准组合能交给 `keyEquivalent`：它一个格子只放得下一个字符，
    /// 表达不了「连按两次 Control」，硬塞进去既会把 F13 显示成 F，
    /// 也会给菜单登记一个用户没设过的按键。所以另外三种模式改走 attributedTitle，
    /// 纯粹当说明文字画上去，不参与按键匹配。
    @MainActor
    private static func annotateSummonItem(_ menu: NSMenu) {
        let title = String(localized: "唤起助手")
        guard let item = menu.items.first(where: { $0.title.hasPrefix(title) }) else { return }

        let settings = AppSettings.shared
        guard settings.shortcutTrigger != .standard else {
            item.attributedTitle = nil
            item.title = title
            if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleAssistant) {
                item.setShortcut(shortcut)
            } else {
                item.keyEquivalent = " "
                item.keyEquivalentModifierMask = [.control, .option]
            }
            return
        }

        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []

        let tapCount = settings.shortcutTrigger.tapCount ?? 1
        let hint = settings.advancedShortcut?.symbolicName(tapCount: tapCount)
            ?? String(localized: "未设置")

        let attributed = NSMutableAttributedString(string: title)
        attributed.append(NSAttributedString(
            string: "   " + hint,
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            ]
        ))
        item.attributedTitle = attributed
    }

    /// 语音的快捷键统一从这里注册：总开关关掉之后，面板上没有任何东西能提示
    /// 正在录音，快捷键就不该还能悄悄把它开起来。
    private func onListeningShortcut(_ name: KeyboardShortcuts.Name,
                                     _ action: @escaping @MainActor (ListeningModel) -> Void) {
        KeyboardShortcuts.onKeyUp(for: name) {
            Task { @MainActor in
                let listening = ListeningModel.shared
                guard listening.isEnabled else { return }
                action(listening)
            }
        }
    }

    /// 菜单栏图标是这个没有 Dock 图标的应用唯一看得见的入口。用户在访达或聚焦里
    /// 再点一次 Wisp（图标被关掉、被菜单栏挤掉、或者只是没找到），至少要有反应。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { PanelController.shared.show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            ListeningModel.shared.terminate()
            ConversationStore.shared.flush()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

#if DEBUG && WISP_DIAGNOSTICS
    private func runContextDump() {
        Task { @MainActor in
            let packet = await ContextCapture.capture()
            ContextCapture.dumpForDebug(packet)
            let dir = AppSettings.supportDirectory.appendingPathComponent("debug", isDirectory: true)
            FileHandle.standardOutput.write(Data("""
            应用：\(packet.appName)  (\(packet.bundleID ?? "-"))
            窗口标题：\(packet.windowTitle ?? "-")
            网址：\(packet.url ?? "-")
            页面标题：\(packet.pageTitle ?? "-")
            整页文字：\(packet.pageText?.count ?? 0) 字（原文 \(packet.pageTextTotalChars ?? 0) 字）
            选中文字：\(packet.selectedText ?? "-")
            跨域框架：\(packet.iframeURLs)
            截图：\(packet.hasScreenshot ? "有 \(Int(packet.screenshotPixelSize?.width ?? 0))x\(Int(packet.screenshotPixelSize?.height ?? 0))" : "无")
            说明：
            \(packet.notes.map { "  - " + $0.text }.joined(separator: "\n"))
            写入：\(dir.path)

            """.utf8))
            NSApp.terminate(nil)
        }
    }
#endif
}
