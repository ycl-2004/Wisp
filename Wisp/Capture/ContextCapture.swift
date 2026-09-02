import AppKit
import Foundation

/// 编排一次上下文采集：确定前台应用 → 并行做截图与浏览器取文 → 合成 ContextPacket。
enum ContextCapture {

    /// 第二阶段要用到的东西。第一阶段查好，交给第二阶段接着跑。
    struct PendingText {
        let bundleID: String
        let family: BrowserTextExtractor.Family
        let appName: String
        let pid: pid_t
        let mode: CaptureMode
        let basic: BrowserTextExtractor.Result
    }

    /// 只说明「现在是哪个窗口」：应用名、窗口标题、网址、页面标题。
    struct HeaderInfo {
        var appName: String
        var bundleID: String?
        var windowTitle: String?
        var url: String?
        var pageTitle: String?
    }

    /// 前台应用最上层窗口的标题。
    ///
    /// 走 `CGWindowList` 直接读，不起子进程，便宜到可以每秒轮询。用途是发现
    /// 「用户在浏览器里换了标签页」——那不会触发任何系统通知，但窗口标题会变。
    /// 需要录屏权限才能读到 `kCGWindowName`，而 Wisp 为了截图本来就要这个权限。
    static func frontWindowTitle(pid: pid_t) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        // 列表是从前到后排的，第一个正常层级的窗口就是最上面那个。
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let name = window[kCGWindowName as String] as? String,
                  !name.isEmpty else { continue }
            return name
        }
        return nil
    }

    /// 轻量跟随：只问「这是哪个窗口、哪个网址」。
    ///
    /// 不截图，也不注入读正文的脚本——只用浏览器那条不需要 JS 开关的
    /// `basicInfo`，所以很快，面板开着时可以反复调用。让头部的应用名和链接
    /// 跟着当前窗口走，用户就不必每换一个标签页就手动点一次刷新。
    static func captureHeader(fallbackApp: NSRunningApplication? = nil) async -> HeaderInfo? {
        let ownBundleID = Bundle.main.bundleIdentifier
        var resolved = NSWorkspace.shared.frontmostApplication
        if resolved == nil || resolved?.bundleIdentifier == ownBundleID {
            resolved = fallbackApp
        }
        guard let app = resolved, app.bundleIdentifier != ownBundleID else { return nil }

        let bundleID = app.bundleIdentifier
        guard !AppSettings.shared.isExcluded(bundleID: bundleID) else { return nil }

        let appName = app.localizedName ?? String(localized: "未知应用")
        var info = HeaderInfo(appName: appName, bundleID: bundleID,
                              windowTitle: frontWindowTitle(pid: app.processIdentifier))

        if let bundleID, let family = BrowserTextExtractor.family(for: bundleID) {
            let basic = await runOffMain {
                BrowserTextExtractor.basicInfo(bundleID: bundleID, family: family, appName: appName)
            }
            info.url = basic.url
            info.pageTitle = basic.pageTitle
        }
        return info
    }

    /// 第一阶段：确定目标应用 → 截图 → 问浏览器要网址和标题。
    ///
    /// 刻意不注入读正文的脚本，所以这一阶段很快。面板必须等它跑完才能显示
    /// （否则浮窗会被截进画面里），但也**只**该等它这么久：读正文动辄几秒，
    /// 滑动采集更久，那些要留到面板出现之后再做，不然用户按下快捷键会看到
    /// 屏幕先自己动起来、面板迟迟不出现。
    ///
    /// `excludingWindowIDs` 传入 Wisp 自己的窗口，双保险防止把浮窗截进去。
    /// `fallbackApp` 用于浮窗已经抢到焦点后再次刷新的情况：此时前台应用是 Wisp 自己。
    static func captureShot(excludingWindowIDs: [CGWindowID] = [],
                            fallbackApp: NSRunningApplication? = nil) async -> (ContextPacket, PendingText?) {
        let settings = AppSettings.shared
        let ownBundleID = Bundle.main.bundleIdentifier

        var resolved = NSWorkspace.shared.frontmostApplication
        if resolved == nil || resolved?.bundleIdentifier == ownBundleID {
            resolved = fallbackApp
        }
        guard let app = resolved, app.bundleIdentifier != ownBundleID else {
            var packet = ContextPacket(appName: String(localized: "未知应用"), bundleID: nil)
            packet.notes.append(.info(String(localized: "无法确定要读取哪个应用。请切换到目标应用后再按一次快捷键。")))
            return (packet, nil)
        }

        let appName = app.localizedName ?? String(localized: "未知应用")
        let bundleID = app.bundleIdentifier

        if settings.isExcluded(bundleID: bundleID) {
            return (.excluded(appName: appName, bundleID: bundleID), nil)
        }

        var packet = ContextPacket(appName: appName, bundleID: bundleID)
        let mode = settings.captureMode

        // 先问浏览器当前分页是什么。快，而且能给截图指出该截哪个窗口。
        let family = BrowserTextExtractor.family(for: bundleID)
        let browser: BrowserTextExtractor.Result?
        if let bundleID, let family {
            browser = await runOffMain {
                BrowserTextExtractor.basicInfo(bundleID: bundleID, family: family, appName: appName)
            }
        } else {
            browser = nil
        }

        switch await ScreenCapturer.capture(pid: app.processIdentifier,
                                            excludingWindowIDs: excludingWindowIDs,
                                            titleHint: browser?.pageTitle) {
        case .success(let shot):
            packet.screenshotJPEG = shot.jpeg
            packet.screenshotPixelSize = shot.pixelSize
            packet.windowTitle = shot.windowTitle
        case .failure(let error):
            switch error {
            case .noPermission:
                packet.notes.append(.blocking(String(localized: "还没有屏幕录制权限，本次没有截图。请到「系统设置 → 隐私与安全性 → 屏幕录制」勾选 Wisp。")))
            case .noWindow:
                packet.notes.append(.info(String(localized: "找不到可截取的窗口。")))
            case .failed(let message):
                packet.notes.append(.info(String(localized: "截图失败：\(message)")))
            }
        }

        if let browser {
            packet.url = browser.url
            packet.pageTitle = browser.pageTitle
            packet.notes.append(contentsOf: browser.notes)
        } else if family == nil {
            packet.notes.append(.info(String(localized: "\(appName) 不是支持的浏览器，读不到整页文字，只能靠截图。")))
        }

        guard mode.readsPageText, let bundleID, let family,
              let basic = browser, !basic.basicFailed else {
            if !mode.readsPageText {
                packet.notes.append(.info(String(localized: "当前是「纯截图」采集模式，本次没有读取页面正文。")))
            }
            return (packet, nil)
        }

        return (packet, PendingText(bundleID: bundleID, family: family, appName: appName,
                                    pid: app.processIdentifier, mode: mode, basic: basic))
    }

    /// 第二阶段：注入脚本读整页正文，必要时滚动采集。面板已经显示之后再调用。
    static func captureText(_ pending: PendingText, into packet: inout ContextPacket) async {
        let settings = AppSettings.shared
        let result = await runOffMain {
            // 可变副本留在这个闭包里，不跨并发边界。
            var current = pending.basic
            BrowserTextExtractor.pageContent(bundleID: pending.bundleID, family: pending.family,
                                             appName: pending.appName, mode: pending.mode,
                                             pid: pending.pid, into: &current)
            return current
        }

        packet.url = result.url ?? packet.url
        packet.pageTitle = result.pageTitle ?? packet.pageTitle
        packet.selectedText = result.selection
        packet.iframeURLs = result.iframes
        // 第一阶段已经把 basic 的说明收进去了，这里只补第二阶段新增的那些。
        packet.notes.append(contentsOf: result.notes.filter { !packet.notes.contains($0) })

        packet.pageTextIsPartial = result.pageTextIsPartial
        packet.usedScrollCollection = result.usedScrollCollection
        if let text = result.pageText {
            packet.pageTextTotalChars = text.count
            packet.pageText = truncate(text, limit: settings.pageTextLimit)
        }
        if !result.iframes.isEmpty {
            packet.notes.append(.info(String(localized: "页面含 \(result.iframes.count) 个跨域嵌入框架，其内部文字读不到，只能靠截图判断。")))
        }
    }

    /// 两个阶段一次跑完。手动刷新走这条。
    static func capture(excludingWindowIDs: [CGWindowID] = [],
                        fallbackApp: NSRunningApplication? = nil) async -> ContextPacket {
        var (packet, pending) = await captureShot(excludingWindowIDs: excludingWindowIDs,
                                                  fallbackApp: fallbackApp)
        if let pending {
            await captureText(pending, into: &packet)
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
    ///
    /// 切点吸附到最近的段落边界（往回最多找 400 字），别把句子劈成两半——
    /// 模型看到半截句子容易顺着编下去。省略标记里同时给出断点前后各一小段原文，
    /// 这样模型能明确知道「缺的是哪一段」，而不是只知道「缺了 N 字」。
    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let headTarget = Int(Double(limit) * 0.75)
        let tailTarget = limit - headTarget

        let head = String(text.prefix(headTarget))
        let headCut = snapBackward(head) ?? head
        let tailRaw = String(text.suffix(tailTarget))
        let tailCut = snapForward(tailRaw) ?? tailRaw

        let omitted = text.count - headCut.count - tailCut.count
        guard omitted > 0 else { return text }

        let marker = String(localized: "\n\n[…… 此处省略正文中间 \(omitted) 字。上一段结束于「\(tailSample(headCut))」，下一段开始于「\(headSample(tailCut))」。回答时若需要这部分内容，请说明并让用户滚动到对应位置 ……]\n\n")
        return headCut + marker + tailCut
    }

    /// 从尾部往回找段落边界，最多回退 400 字；找不到就原样返回。
    private static func snapBackward(_ s: String) -> String? {
        let window = 400
        let chars = Array(s)
        let lower = max(0, chars.count - window)
        var i = chars.count - 1
        while i > lower {
            if chars[i] == "\n" { return String(chars[0..<i]) }
            i -= 1
        }
        return nil
    }

    /// 从头部往后找段落边界，最多前进 400 字；找不到就原样返回。
    private static func snapForward(_ s: String) -> String? {
        let window = 400
        let chars = Array(s)
        let upper = min(chars.count, window)
        var i = 0
        while i < upper {
            if chars[i] == "\n" { return String(chars[(i + 1)...]) }
            i += 1
        }
        return nil
    }

    private static func tailSample(_ s: String, _ n: Int = 24) -> String {
        String(s.suffix(n)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func headSample(_ s: String, _ n: Int = 24) -> String {
        String(s.prefix(n)).trimmingCharacters(in: .whitespacesAndNewlines)
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
            "pageTextIsPartial": packet.pageTextIsPartial,
            "usedScrollCollection": packet.usedScrollCollection,
            "selectedText": packet.selectedText ?? "",
            "iframeURLs": packet.iframeURLs,
            "notes": packet.notes.map(\.text),
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
