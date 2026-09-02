import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleAssistant = Self("toggleAssistant",
                                      default: .init(.space, modifiers: [.control, .option]))
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    static let remoteShowNotification = Notification.Name("com.yichenlin.Wisp.show")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 诊断入口：直接跑一次采集，把结果写到 debug 文件夹后退出。
        // 用法：~/Applications/Wisp.app/Contents/MacOS/Wisp --dump-context
        if CommandLine.arguments.contains("--dump-context") {
            runContextDump()
            return
        }

        // 把药丸的三种状态离线渲染成图片，用来在没有录屏权限时检查排版。
        // 用法：... /MacOS/Wisp --render-island ~/Desktop/island.png
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
        // 用法：~/Applications/Wisp.app/Contents/MacOS/Wisp --show
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
            \(packet.notes.map { "  - " + $0 }.joined(separator: "\n"))
            写入：\(dir.path)

            """.utf8))
            NSApp.terminate(nil)
        }
    }
}
