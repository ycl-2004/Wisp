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
        var notes: [String] = []
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
    static func pageContent(bundleID: String, family: Family, appName: String, into result: inout Result) {
        switch runAppleScript(jsScript(bundleID: bundleID, family: family), timeout: 12) {
        case .success(let output):
            let raw = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = raw.data(using: .utf8),
                  let page = try? JSONDecoder().decode(PageExtraction.self, from: data) else {
                result.notes.append(String(localized: "已连上 \(appName)，但页面正文的返回内容无法解析，本次只发送截图与网址。"))
                return
            }
            if let text = page.text, !text.isEmpty {
                result.pageText = text
            } else if let error = page.error, !error.isEmpty {
                result.notes.append(String(localized: "页面脚本报错，没读到正文：\(error)"))
            } else {
                result.notes.append(Self.emptyTextNote(url: result.url, appName: appName))
            }
            if let sel = page.selection, !sel.isEmpty { result.selection = sel }
            if let frames = page.iframes, !frames.isEmpty { result.iframes = frames }
            if let title = page.title, !title.isEmpty, result.pageTitle == nil { result.pageTitle = title }
            if let href = page.href, !href.isEmpty, result.url == nil { result.url = href }
        case .failure(let error):
            result.notes.append(note(for: error, appName: appName, bundleID: bundleID, stage: .javascript))
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

    private static func jsScript(bundleID: String, family: Family) -> String {
        let app = PageTextScript.appleScriptLiteral(bundleID)
        let js = PageTextScript.appleScriptLiteral(PageTextScript.js)
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
    static func emptyTextNote(url: String?, appName: String) -> String {
        let internalPrefixes = ["chrome://", "chrome-extension://", "edge://", "brave://",
                                "vivaldi://", "about:", "devtools://", "view-source:"]
        if let url, internalPrefixes.contains(where: { url.hasPrefix($0) }) {
            return String(localized: "当前是 \(appName) 的内部页面（\(url)），读不到正文，本次只有截图。")
        }
        return String(localized: "脚本跑通了，但这个页面没有可提取的文字，本次只有截图。")
    }

    private static func note(for error: ScriptError, appName: String, bundleID: String, stage: Stage) -> String {
        let text = error.message
        if error.timedOut {
            return String(localized: "\(appName) 没有在限定时间内回应，本次没有读到页面文字。页面可能正忙。")
        }
        if error.code == -1743 || text.contains("Not authorized") || text.contains("not allowed") {
            return String(localized: "系统还没允许 Wisp 控制 \(appName)。请到「系统设置 → 隐私与安全性 → 自动化」勾选 Wisp 下的 \(appName)。")
        }
        if text.contains("JavaScript") || text.contains("javascript") {
            switch stage {
            case .javascript:
                if ChromeProfileInspector.supportsInspection(bundleID: bundleID) {
                    return ChromeProfileInspector.javaScriptDisabledHint(bundleID: bundleID, appName: appName)
                }
                return String(localized: "\(appName) 没有开启「Allow JavaScript from Apple Events」，本次只读到网址，没有整页文字。Safari 在「Develop」菜单里打开一次即可。")
            case .basic:
                return String(localized: "读取 \(appName) 当前分页失败：\(text)")
            }
        }
        if error.code == -1728 || text.contains("Can’t get") || text.contains("Can't get") {
            return String(localized: "\(appName) 当前没有可读取的分页窗口。")
        }
        return String(localized: "读取 \(appName) 失败：\(text)")
    }
}
