import AppKit
import Foundation

/// 编排一次上下文采集：确定前台应用 → 并行做截图与浏览器取文 → 合成 ContextPacket。
enum ContextCapture {

    /// `excludingWindowIDs` 传入 Wisp 自己的窗口，双保险防止把浮窗截进去。
    /// `fallbackApp` 用于浮窗已经抢到焦点后再次刷新的情况：此时前台应用是 Wisp 自己。
    static func capture(excludingWindowIDs: [CGWindowID] = [],
                        fallbackApp: NSRunningApplication? = nil) async -> ContextPacket {
        let settings = AppSettings.shared
        let ownBundleID = Bundle.main.bundleIdentifier

        var resolved = NSWorkspace.shared.frontmostApplication
        if resolved == nil || resolved?.bundleIdentifier == ownBundleID {
            resolved = fallbackApp
        }
        guard let app = resolved, app.bundleIdentifier != ownBundleID else {
            var packet = ContextPacket(appName: String(localized: "未知应用"), bundleID: nil)
            packet.notes.append(String(localized: "无法确定要读取哪个应用。请切换到目标应用后再按一次快捷键。"))
            return packet
        }

        let appName = app.localizedName ?? String(localized: "未知应用")
        let bundleID = app.bundleIdentifier

        if settings.isExcluded(bundleID: bundleID) {
            return .excluded(appName: appName, bundleID: bundleID)
        }

        var packet = ContextPacket(appName: appName, bundleID: bundleID)

        // 第一步：先问浏览器当前分页是什么。快，而且能给截图指出该截哪个窗口。
        // 下面的并发闭包会捕获它，所以必须是 let：捕获 var 在 Swift 6 里是错误。
        let family = BrowserTextExtractor.family(for: bundleID)
        let browser: BrowserTextExtractor.Result?
        if let bundleID, let family {
            browser = await runOffMain {
                BrowserTextExtractor.basicInfo(bundleID: bundleID, family: family, appName: appName)
            }
        } else {
            browser = nil
        }

        // 第二步：截图与整页正文并行。
        async let shotResult = ScreenCapturer.capture(pid: app.processIdentifier,
                                                      excludingWindowIDs: excludingWindowIDs,
                                                      titleHint: browser?.pageTitle)
        async let contentResult: BrowserTextExtractor.Result? = {
            guard let bundleID, let family, let basic = browser, !basic.basicFailed else { return browser }
            return await runOffMain {
                // 可变副本留在这个闭包里，不跨并发边界。
                var current = basic
                BrowserTextExtractor.pageContent(bundleID: bundleID, family: family,
                                                 appName: appName, into: &current)
                return current
            }
        }()

        switch await shotResult {
        case .success(let shot):
            packet.screenshotJPEG = shot.jpeg
            packet.screenshotPixelSize = shot.pixelSize
            packet.windowTitle = shot.windowTitle
        case .failure(let error):
            switch error {
            case .noPermission:
                packet.notes.append(String(localized: "还没有屏幕录制权限，本次没有截图。请到「系统设置 → 隐私与安全性 → 屏幕录制」勾选 Wisp。"))
            case .noWindow:
                packet.notes.append(String(localized: "找不到可截取的窗口。"))
            case .failed(let message):
                packet.notes.append(String(localized: "截图失败：\(message)"))
            }
        }

        if let result = await contentResult {
            packet.url = result.url
            packet.pageTitle = result.pageTitle
            packet.selectedText = result.selection
            packet.iframeURLs = result.iframes
            packet.notes.append(contentsOf: result.notes)

            if let text = result.pageText {
                packet.pageTextTotalChars = text.count
                packet.pageText = truncate(text, limit: settings.pageTextLimit)
            }
            if !result.iframes.isEmpty {
                packet.notes.append(String(localized: "页面含 \(result.iframes.count) 个跨域嵌入框架，其内部文字读不到，只能靠截图判断。"))
            }
        } else if family == nil {
            packet.notes.append(String(localized: "\(appName) 不是支持的浏览器，读不到整页文字，只能靠截图。"))
        }

        return packet
    }

    /// AppleScript 走子进程，放到后台队列跑，别卡住主线程。
    private static func runOffMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// 超长正文保留头 75% 与尾 25%，中间标注省略了多少字。
    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let headCount = Int(Double(limit) * 0.75)
        let tailCount = limit - headCount
        let head = String(text.prefix(headCount))
        let tail = String(text.suffix(tailCount))
        let omitted = text.count - headCount - tailCount
        return head + String(localized: "\n\n[…… 中间省略 \(omitted) 字 ……]\n\n") + tail
    }

    // MARK: - 调试

    /// 把最近一次采集写到 ~/Library/Application Support/Wisp/debug/
    static func dumpForDebug(_ packet: ContextPacket) {
        let dir = AppSettings.supportDirectory.appendingPathComponent("debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var json: [String: Any] = [
            "appName": packet.appName,
            "bundleID": packet.bundleID ?? "",
            "windowTitle": packet.windowTitle ?? "",
            "url": packet.url ?? "",
            "pageTitle": packet.pageTitle ?? "",
            "pageTextChars": packet.pageText?.count ?? 0,
            "pageTextTotalChars": packet.pageTextTotalChars ?? 0,
            "selectedText": packet.selectedText ?? "",
            "iframeURLs": packet.iframeURLs,
            "notes": packet.notes,
            "hasScreenshot": packet.hasScreenshot,
            "capturedAt": ISO8601DateFormatter().string(from: packet.capturedAt),
        ]
        json["pageText"] = packet.pageText ?? ""

        if let data = try? JSONSerialization.data(withJSONObject: json,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: dir.appendingPathComponent("last-context.json"))
        }
        if let jpeg = packet.screenshotJPEG {
            try? jpeg.write(to: dir.appendingPathComponent("last-screenshot.jpg"))
        }
    }
}
