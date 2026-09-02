import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleAssistant = Self("toggleAssistant",
                                      default: .init(.space, modifiers: [.control, .option]))
}

final class AppDelegate: NSObject, NSApplicationDelegate {

#if DEBUG
    static let remoteShowNotification = Notification.Name("com.yichenlin.Wisp.show")
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 诊断入口只编进 Debug 版。发布版里留着它们等于把已经拿到的
        // 屏幕录制授权借给任何本地进程：`Wisp --dump-context` 就能把当前屏幕
        // 截图和整页正文写到一个固定路径，`--show` 还能被任意 App 远程触发采集。
#if DEBUG
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

        // 首次启动时把屏幕录制授权框弹出来，别等到用户第一次按快捷键才发现没权限。
        if !Permissions.hasScreenRecording {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Permissions.requestScreenRecording()
            }
        }

        MainActor.assumeIsolated {
            PanelController.shared.restoreStoredFrame()
            IslandController.shared.start()
        }

        // 启动时看一眼有没有新版本。默认开着，设置里可以关。
        // 只请求一次版本号，不带任何标识信息，也不自动下载。
        if AppSettings.shared.checkForUpdates {
            Task { @MainActor in
                if case .available(let latest) = await UpdateChecker.check() {
                    UpdateNotice.shared.availableVersion = latest
                }
            }
        }

        KeyboardShortcuts.onKeyUp(for: .toggleAssistant) {
            Task { @MainActor in
                PanelController.shared.toggle()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            ConversationStore.shared.flush()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

#if DEBUG
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
