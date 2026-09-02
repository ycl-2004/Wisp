import Foundation

/// 通过 AppleScript 向前台浏览器索取当前分页的网址、标题和整页正文。
enum BrowserTextExtractor {

    enum Family {
        case chromium
        case safari
        case arc
    }

    static let supported: [String: Family] = [
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.dev": .chromium,
        "com.google.Chrome.canary": .chromium,
        "com.brave.Browser": .chromium,
        "com.brave.Browser.beta": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.microsoft.edgemac.Beta": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "ru.yandex.desktop.yandex-browser": .chromium,
        "com.operasoftware.Opera": .chromium,
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "company.thebrowser.Browser": .arc,
        "company.thebrowser.dia": .arc,
    ]

    static func family(for bundleID: String?) -> Family? {
        guard let bundleID else { return nil }
        return supported[bundleID]
    }

    struct Result {
        var basicFailed = false
        var url: String?
        var pageTitle: String?
        var pageText: String?
        var selection: String?
        var iframes: [String] = []
        var notes: [CaptureNote] = []
        /// 正文已知不完整：虚拟滚动没采到底，或滚动采集中途失败。
        var pageTextIsPartial = false
        /// 走过滚动采集，而不是单次 innerText。
        var usedScrollCollection = false
        /// 实际滚了多少屏，调试用。
        var scrollSteps = 0
        /// 采集开始时用户所在的滚动位置，收尾时要还原回去。
        var initialScrollTop: Double = 0
    }

    /// 第一步：只取网址与标题。不需要 JS 开关，快，用来给截图选对窗口。
    static func basicInfo(bundleID: String, family: Family, appName: String) -> Result {
        var result = Result()
        switch runAppleScript(basicScript(bundleID: bundleID, family: family), timeout: 6) {
        case .success(let output):
            let parts = output.components(separatedBy: "\n")
            let url = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !url.isEmpty { result.url = url }
            if parts.count > 1 {
                let title = parts.dropFirst().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { result.pageTitle = title }
            }
        case .failure(let error):
            result.notes.append(note(for: error, appName: appName, bundleID: bundleID, stage: .basic))
            result.basicFailed = true
        }
        return result
    }

    /// 第二步：跑注入脚本取整页正文。需要浏览器打开 Apple Events 的 JS 开关。
    ///
    /// 先做一次常规提取；如果这一页看起来是虚拟滚动（飞书文档、Notion 这类，
    /// DOM 里只有可视区域的块），就继续滚动累积，直到到底、超预算或者滚不动为止。
    static func pageContent(bundleID: String, family: Family, appName: String,
                            mode: CaptureMode, pid: pid_t, into result: inout Result) {
        switch runAppleScript(jsScript(bundleID: bundleID, family: family, source: PageTextScript.beginJS),
                              timeout: 12) {
        case .success(let output):
            let raw = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = raw.data(using: .utf8),
                  let page = try? JSONDecoder().decode(PageExtraction.self, from: data) else {
                result.notes.append(.info(String(localized: "已连上 \(appName)，但页面正文的返回内容无法解析，本次只发送截图与网址。")))
                return
            }
            if let text = page.text, !text.isEmpty {
                result.pageText = text
            } else if let error = page.error, !error.isEmpty {
                result.notes.append(.info(String(localized: "页面脚本报错，没读到正文：\(error)")))
            } else {
                result.notes.append(Self.emptyTextNote(url: result.url, appName: appName))
            }
            if let sel = page.selection, !sel.isEmpty { result.selection = sel }
            if let frames = page.iframes, !frames.isEmpty { result.iframes = frames }
            if let title = page.title, !title.isEmpty, result.pageTitle == nil { result.pageTitle = title }
            if let href = page.href, !href.isEmpty, result.url == nil { result.url = href }
            result.initialScrollTop = page.scrollTop ?? 0

            guard mode == .scrollCollect, result.pageText != nil else { return }
            if needsScrollCollection(page: page, url: result.url) {
                scrollCollect(bundleID: bundleID, family: family, appName: appName,
                              pid: pid, into: &result)
            }
        case .failure(let error):
            result.notes.append(note(for: error, appName: appName, bundleID: bundleID, stage: .javascript))
        }
    }

    // MARK: - 滚动采集

    /// 一次采集最多滚多少步。实测一篇 4500 字的飞书文档用掉 26 步。
    static let maxScrollSteps = 60
    /// 整个滚动采集的时间预算。超了就用手上已有的内容收工。
    /// 每步的开销主要是一次 osascript 进程往返（~250ms），60 步约 15 秒封顶。
    static let scrollBudget: TimeInterval = 18
    /// 连续多少步没有新内容就停。
    ///
    /// 这是**主要**的停止信号，不是兜底：虚拟文档边滚边加载，`scrollHeight`
    /// 一直在涨，`atBottom` 实测从头到尾都不会变 true（26 步全程 false），
    /// 只有「没有新内容了」才真正说明到头了。中间偶尔有一屏是纯图片，
    /// 所以要连续几步都没新增才收手。
    static let idleStepsBeforeStop = 4
    /// 每一步往下滚多少像素。留出重叠，避免正好卡在块边界漏内容。
    static let scrollPixelsPerStep: Int32 = -420

    /// 这些站点已知是虚拟滚动，不看密度直接采。
    private static let virtualizedHosts = [
        "feishu.cn", "larksuite.com", "feishu.net", "notion.so", "notion.site",
        "docs.google.com", "yuque.com", "quip.com", "craft.do", "coda.io",
    ]

    /// 判断要不要滚动采集。
    ///
    /// 两个信号：域名在已知的虚拟滚动名单里；或者「正文字数 / 可滚高度」低得反常
    /// ——正常的长文页面 innerText 本来就是全的，密度在 0.15 字/px 以上；
    /// 虚拟滚动只渲染一屏，密度会掉一个数量级。
    static func needsScrollCollection(page: PageExtraction, url: String?) -> Bool {
        let scrollHeight = page.scrollHeight ?? 0
        let clientHeight = page.clientHeight ?? 0
        // 一屏就装得下，没有滚的必要。
        guard scrollHeight > clientHeight + 200 else { return false }

        if let url, let host = URL(string: url)?.host?.lowercased(),
           virtualizedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }

        let chars = Double(page.text?.count ?? 0)
        guard scrollHeight > 0 else { return false }
        return chars / scrollHeight < 0.15
    }

    /// 把页面滚一遍并累积正文，最后取全文并复位。
    ///
    /// 优先用 `ScrollDriver` 发系统级滚轮事件——这是唯一能驱动飞书这类虚拟列表的
    /// 办法。拿不到辅助功能权限时退回 JS 改 `scrollTop`：对普通的懒加载页面仍然
    /// 有效，对飞书无效，此时会如实标成「正文不完整」。
    private static func scrollCollect(bundleID: String, family: Family, appName: String,
                                      pid: pid_t, into result: inout Result) {
        let useRealScroll = ScrollDriver.isTrusted
        guard useRealScroll, let windowRect = ScrollDriver.frontWindowRect(pid: pid) else {
            if !useRealScroll {
                result.notes.append(.blocking(String(localized: "这一页需要滚动才能读全，但 Wisp 还没有「辅助功能」权限，只能退回效果有限的脚本滚动。请到「系统设置 → 隐私与安全性 → 辅助功能」勾选 Wisp。")))
            }
            scrollCollectViaScript(bundleID: bundleID, family: family, appName: appName, into: &result)
            return
        }

        let point = ScrollDriver.contentPoint(in: windowRect)
        let startTop = result.initialScrollTop
        let absorbSource = jsScript(bundleID: bundleID, family: family, source: PageTextScript.absorbJS)
        let deadline = Date().addingTimeInterval(scrollBudget)
        var idleStreak = 0
        var stepsTaken = 0
        var ranOutOfBudget = false

        // 指针在采集期间停在正文上，结束后放回原处。不激活目标应用，
        // 滚轮事件按指针所在窗口派发，不需要抢焦点。
        ScrollDriver.withCursorParked(at: point) {
            for _ in 0..<maxScrollSteps {
                if Date() >= deadline { ranOutOfBudget = true; break }

                guard case .success(let output) = runAppleScript(absorbSource, timeout: 6),
                      let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                      let step = try? JSONDecoder().decode(PageScrollStep.self, from: data),
                      step.error == nil else { break }

                stepsTaken += 1
                idleStreak = (step.added ?? 0) > 0 ? 0 : idleStreak + 1
                if idleStreak >= idleStepsBeforeStop { break }

                ScrollDriver.scroll(pixels: scrollPixelsPerStep, at: point)
                // 给虚拟列表补渲染的时间。osascript 起进程本身还有 ~200ms，
                // 所以这里不用等满一帧以上。
                usleep(90_000)
            }
            // 把页面还原到用户采集前所在的位置。虚拟列表不认 scrollTop，
            // 只能先滚到顶再滚回去。
            ScrollDriver.restore(toScrollTop: startTop, at: point)
        }

        finalize(bundleID: bundleID, family: family, stepsTaken: stepsTaken,
                 ranOutOfBudget: ranOutOfBudget, realScroll: true, into: &result)
    }

    /// 退路：用 JS 改 `scrollTop` 驱动。对普通懒加载页面有效。
    private static func scrollCollectViaScript(bundleID: String, family: Family, appName: String,
                                               into result: inout Result) {
        let deadline = Date().addingTimeInterval(scrollBudget)
        let stepSource = jsScript(bundleID: bundleID, family: family, source: PageTextScript.stepJS)
        var idleStreak = 0
        var stepsTaken = 0
        var ranOutOfBudget = false

        for _ in 0..<maxScrollSteps {
            if Date() >= deadline { ranOutOfBudget = true; break }
            guard case .success(let output) = runAppleScript(stepSource, timeout: 6),
                  let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let step = try? JSONDecoder().decode(PageScrollStep.self, from: data),
                  step.error == nil else { break }

            stepsTaken += 1
            idleStreak = (step.added ?? 0) > 0 ? 0 : idleStreak + 1
            if step.atBottom == true { break }
            if idleStreak >= idleStepsBeforeStop { break }
        }

        finalize(bundleID: bundleID, family: family, stepsTaken: stepsTaken,
                 ranOutOfBudget: ranOutOfBudget, realScroll: false, into: &result)
    }

    /// 取回累积的全文，判断到底读全了没有，并写进 result。
    private static func finalize(bundleID: String, family: Family, stepsTaken: Int,
                                 ranOutOfBudget: Bool, realScroll: Bool, into result: inout Result) {
        guard case .success(let output) = runAppleScript(
                jsScript(bundleID: bundleID, family: family, source: PageTextScript.finishJS), timeout: 8),
              let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let final = try? JSONDecoder().decode(PageScrollFinish.self, from: data),
              let text = final.text, !text.isEmpty else {
            result.notes.append(.info(String(localized: "这一页需要滚动才能读全，采集过程中断了，正文可能只有可视区域的一屏。")))
            result.pageTextIsPartial = true
            return
        }

        let before = result.pageText?.count ?? 0
        let grew = text.count - before
        result.pageText = text
        result.scrollSteps = final.steps ?? stepsTaken
        result.usedScrollCollection = true

        // 判断有没有读到头，只看「还有没有新内容」。
        //
        // 不能用 atBottom：虚拟文档边滚边加载，scrollHeight 一路在涨，实测采集
        // 一篇 4500 字的飞书文档全程 26 步，atBottom 一次都没有变成 true。
        // 真正到头的标志是连续若干步一个字都没多，也就是这里的 ranOutOfBudget 为假、
        // 且步数没有顶到上限。
        let stoppedBecauseNothingNew = !ranOutOfBudget && stepsTaken < maxScrollSteps
        result.pageTextIsPartial = !stoppedBecauseNothingNew

        if !realScroll && grew < 40 {
            // 脚本滚动模式下一个字都没多 —— 这个页面的虚拟列表不认程序化滚动。
            result.pageTextIsPartial = true
            result.notes.append(.info(String(localized: "这一页的正文是按需渲染的，脚本滚动没能让它加载出更多内容，只读到 \(text.count) 字。到设置里把采集模式切成「允许滑动采集」可以读全。")))
            return
        }

        if stoppedBecauseNothingNew {
            if grew > 0 {
                result.notes.append(.info(String(localized: "这一页按需渲染，已滚动采集 \(stepsTaken) 屏读到文末，正文从 \(before) 字补到 \(text.count) 字。")))
            }
        } else {
            let reason = ranOutOfBudget
                ? String(localized: "超过时间预算")
                : String(localized: "达到滚动上限")
            result.notes.append(.info(String(localized: "这一页按需渲染，\(reason)，滚了 \(stepsTaken) 屏采到 \(text.count) 字，可能还没到文末。")))
        }
    }

    // MARK: - AppleScript 文本

    private static func basicScript(bundleID: String, family: Family) -> String {
        let app = PageTextScript.appleScriptLiteral(bundleID)
        switch family {
        case .chromium:
            return """
            with timeout of 5 seconds
              tell application id \(app)
                set theTab to active tab of front window
                return (URL of theTab) & linefeed & (title of theTab)
              end tell
            end timeout
            """
        case .safari:
            return """
            with timeout of 5 seconds
              tell application id \(app)
                set theTab to current tab of front window
                return (URL of theTab) & linefeed & (name of theTab)
              end tell
            end timeout
            """
        case .arc:
            return """
            with timeout of 5 seconds
              tell application id \(app)
                tell front window
                  set theURL to URL of active tab
                  set theTitle to title of active tab
                end tell
                return theURL & linefeed & theTitle
              end tell
            end timeout
            """
        }
    }

    private static func jsScript(bundleID: String, family: Family, source: String) -> String {
        let app = PageTextScript.appleScriptLiteral(bundleID)
        let js = PageTextScript.appleScriptLiteral(source)
        switch family {
        case .chromium:
            return """
            with timeout of 8 seconds
              tell application id \(app)
                return execute front window's active tab javascript \(js)
              end tell
            end timeout
            """
        case .safari:
            return """
            with timeout of 8 seconds
              tell application id \(app)
                return do JavaScript \(js) in current tab of front window
              end tell
            end timeout
            """
        case .arc:
            return """
            with timeout of 8 seconds
              tell application id \(app)
                tell front window
                  return execute active tab javascript \(js)
                end tell
              end tell
            end timeout
            """
        }
    }

    // MARK: - 执行

    struct ScriptError: Error {
        var message: String
        var code: Int?
        var timedOut: Bool = false
    }

    /// 用 osascript 子进程执行，可硬超时，且不阻塞主线程。
    static func runAppleScript(_ source: String, timeout: TimeInterval = 10) -> Result2 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure(ScriptError(message: error.localizedDescription))
        }

        stdinPipe.fileHandleForWriting.write(Data(source.utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = group.wait(timeout: .now() + 1)
            return .failure(ScriptError(message: String(localized: "脚本超时"), timedOut: true))
        }
        _ = group.wait(timeout: .now() + 2)
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return .success(String(data: outData, encoding: .utf8) ?? "")
        }
        let message = String(data: errData, encoding: .utf8) ?? String(localized: "未知错误")
        return .failure(ScriptError(message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                                    code: errorCode(in: message)))
    }

    enum Result2 {
        case success(String)
        case failure(ScriptError)
    }

    private static func errorCode(in message: String) -> Int? {
        guard let range = message.range(of: #"\(-?\d+\)"#, options: .regularExpression) else { return nil }
        return Int(message[range].dropFirst().dropLast())
    }

    private enum Stage { case basic, javascript }

    /// 脚本跑通但正文是空的，多半是浏览器内部页面或空白页。
    static func emptyTextNote(url: String?, appName: String) -> CaptureNote {
        let internalPrefixes = ["chrome://", "chrome-extension://", "edge://", "brave://",
                                "vivaldi://", "about:", "devtools://", "view-source:"]
        if let url, internalPrefixes.contains(where: { url.hasPrefix($0) }) {
            return .info(String(localized: "当前是 \(appName) 的内部页面（\(url)），读不到正文，本次只有截图。"))
        }
        return .info(String(localized: "脚本跑通了，但这个页面没有可提取的文字，本次只有截图。"))
    }

    private static func note(for error: ScriptError, appName: String, bundleID: String, stage: Stage) -> CaptureNote {
        let text = error.message
        if error.timedOut {
            return .info(String(localized: "\(appName) 没有在限定时间内回应，本次没有读到页面文字。页面可能正忙。"))
        }
        if error.code == -1743 || text.contains("Not authorized") || text.contains("not allowed") {
            return .blocking(String(localized: "系统还没允许 Wisp 控制 \(appName)。请到「系统设置 → 隐私与安全性 → 自动化」勾选 Wisp 下的 \(appName)。"))
        }
        if text.contains("JavaScript") || text.contains("javascript") {
            switch stage {
            case .javascript:
                if ChromeProfileInspector.supportsInspection(bundleID: bundleID) {
                    return .blocking(ChromeProfileInspector.javaScriptDisabledHint(bundleID: bundleID, appName: appName))
                }
                return .blocking(String(localized: "\(appName) 没有开启「Allow JavaScript from Apple Events」，本次只读到网址，没有整页文字。Safari 在「Develop」菜单里打开一次即可。"))
            case .basic:
                return .info(String(localized: "读取 \(appName) 当前分页失败：\(text)"))
            }
        }
        if error.code == -1728 || text.contains("Can’t get") || text.contains("Can't get") {
            return .info(String(localized: "\(appName) 当前没有可读取的分页窗口。"))
        }
        return .info(String(localized: "读取 \(appName) 失败：\(text)"))
    }
}
