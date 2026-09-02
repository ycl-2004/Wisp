import Foundation

/// 走本地 `claude`。Claude Code 自己负责登录、模型额度和会话；Wisp 只调用它的 CLI，
/// 所以这里和 Codex、AGY 一样归在「Agent CLI」分组下。
///
/// 三个 CLI provider 里只有它能逐字流式：`--output-format stream-json`
/// 配 `--include-partial-messages` 会一段段吐 `text_delta`，答案边生成边显示，
/// 而 Codex 和 AGY 都只能等整段答完再一次性返回。
///
/// 截图和纯文本走同一条 headless 通道。Claude Code 的 headless 输入只收文本，
/// 但它会用 Read 工具读 prompt 里点名的图片文件——前提是那个文件在它的
/// workspace 里，见 `stream(messages:config:)` 对工作目录的处理。
struct ClaudeCodeCLIProvider: ChatProvider {
    /// 实测一次带截图的请求要 16–21 秒，比 AGY 慢，所以上限给得和它一样宽。
    static let wallClockTimeout: TimeInterval = 300

    /// 按估算 token 记的上限。
    ///
    /// Claude Code 的胃口比 AGY 大得多：默认 60,000 字上限的单轮请求实测
    /// 走到约 18 万 token 也没有截断，埋在正文正中间的句子照样读得出来，
    /// 而 AGY 在 71,400 token 处就开始悄悄丢内容。所以这里不必像
    /// `AgyCLIProvider.promptBudget` 那样收得紧，150,000 只是给 20 万上下文
    /// 留出它自身开销的余量，防止把窗口撑爆，正常用不到。
    static let promptBudget = 150_000

    /// GUI 应用拿不到登录 shell 的 PATH，常见安装位置都要主动扫。
    static let searchPaths = [
        "/opt/homebrew/bin/claude",
        NSHomeDirectory() + "/.local/bin/claude",
        "/usr/local/bin/claude",
        NSHomeDirectory() + "/.claude/local/claude",
    ]

    private static var candidatePaths: [String] {
        var paths = searchPaths
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths += path.split(separator: ":").map { String($0) + "/claude" }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    static var detectedPath: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func resolvePath(_ configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) { return trimmed }
        return detectedPath
    }

    /// Claude Code 没有列模型的命令，只能给固定几项。
    /// 用别名而不是完整模型名：别名跟着「最新」走，Claude Code 更新后不用改这里。
    static let presets: [ModelCatalog.Preset] = [
        .init(slug: "sonnet", title: "Sonnet",
              note: String(localized: "日常主力，读截图和长正文都够快")),
        .init(slug: "opus", title: "Opus",
              note: String(localized: "最强的一档，慢一些，留给硬问题")),
        .init(slug: "haiku", title: "Haiku",
              note: String(localized: "最快最省，适合看一眼截图就答")),
        .init(slug: "fable", title: "Fable",
              note: String(localized: "偏写作与长文组织")),
    ]

    func stream(messages: [[String: Any]], config: ProviderConfig) -> AsyncThrowingStream<String, Error> {
        let flattened = CodexCLIProvider.flattenBody(messages)

        return AsyncThrowingStream { continuation in
            let box = RunBox()
            let stderrBuffer = DrainBuffer()

            let work = Task.detached(priority: .userInitiated) {
                var workDirectory: URL?
                do {
                    guard let binary = Self.resolvePath(config.cliPath) else {
                        throw ProviderError.claudeCodeNotFound
                    }

                    // 工作目录必须指到截图所在的地方。Claude Code 只允许读
                    // workspace（和 --add-dir）里的文件，落在别处的截图会被
                    // 直接拒掉——它不会报错，而是照常作答并说「读取权限被拒绝」，
                    // 于是这一轮就成了纯文本问答，用户还看不出截图没送到。
                    let directory = try CLITemporaryDirectory.create(prefix: "Wisp-claude")
                    workDirectory = directory

                    var imagePaths: [String] = []
                    for (index, data) in flattened.images.enumerated() {
                        let file = directory.appendingPathComponent("screen-\(index).jpg")
                        try data.write(to: file)
                        imagePaths.append(file.path)
                    }

                    let prompt = CLIPrompt.compose(sections: flattened.sections,
                                                   imagePaths: imagePaths,
                                                   budget: Self.promptBudget)

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.currentDirectoryURL = directory
                    process.arguments = Self.commandArguments(prompt: prompt, model: config.model)

                    let stdout = Pipe(), stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    let stderrHandle = stderr.fileHandleForReading
                    stderrHandle.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                        } else {
                            stderrBuffer.append(chunk)
                        }
                    }

                    guard box.adopt(process) else { throw ProviderError.cancelled }
                    do {
                        try process.run()
                    } catch {
                        stderrHandle.readabilityHandler = nil
                        box.finish()
                        throw ProviderError.network(error.localizedDescription)
                    }

                    // NDJSON：一行一个事件，边读边把 text_delta 吐给上层。
                    var streamed = ""
                    var outcome: Outcome?
                    var buffer = Data()
                    let handle = stdout.fileHandleForReading

                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        buffer.append(chunk)
                        while let range = buffer.firstRange(of: Data("\n".utf8)) {
                            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                            guard let line = String(data: lineData, encoding: .utf8),
                                  !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                            switch Self.event(in: line) {
                            case .text(let delta):
                                streamed += delta
                                continuation.yield(delta)
                            case .finished(let result):
                                outcome = result
                            case .none:
                                break
                            }
                        }
                    }
                    // NDJSON 通常以换行收尾，但不要把“最后一行没有换行”误判成
                    // 缺失 result。那会把一条完整回答错误标成失败。
                    if let line = String(data: buffer, encoding: .utf8),
                       !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        switch Self.event(in: line) {
                        case .text(let delta):
                            streamed += delta
                            continuation.yield(delta)
                        case .finished(let result):
                            outcome = result
                        case .none:
                            break
                        }
                    }

                    process.waitUntilExit()
                    stderrHandle.readabilityHandler = nil
                    box.finish()

                    if let reason = box.reason {
                        throw reason == .timedOut
                            ? ProviderError.claudeCodeTimedOut(Int(Self.wallClockTimeout))
                            : ProviderError.cancelled
                    }

                    // 收尾那条 result 事件和 0 退出码缺一不可。前面流出去的可能
                    // 只是半截，不能因为有 text_delta 就把崩溃误记成成功。
                    guard Self.isSuccessfulCompletion(outcome: outcome,
                                                      status: process.terminationStatus) else {
                        let outcomeDetail = outcome?.text ?? ""
                        let detail = outcomeDetail.isEmpty ? stderrBuffer.text : outcomeDetail
                        throw ProviderError.claudeCodeFailed(
                            Self.condense(detail),
                            status: process.terminationStatus)
                    }
                    if streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // 没有增量但有终值：补发一次，别让用户对着空白发呆。
                        if let text = outcome?.text, !text.isEmpty {
                            continuation.yield(text)
                        } else {
                            throw ProviderError.claudeCodeFailed(Self.condense(stderrBuffer.text),
                                                                 status: process.terminationStatus)
                        }
                    }
                    continuation.finish()
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch {
                    continuation.finish(throwing: ProviderError.network(error.localizedDescription))
                }
                // 无论走哪条路都要清掉临时目录，里面有这一轮的屏幕截图。
                if let workDirectory { CLITemporaryDirectory.remove(workDirectory) }
            }

            let watchdog = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(Self.wallClockTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                box.stop(.timedOut, onlyIfRunning: true)
            }

            continuation.onTermination = { _ in
                watchdog.cancel()
                box.stop(.cancelled)
                work.cancel()
            }
        }
    }

    /// `claude auth status` 比 `--version` 值钱：它同时回答「装了没」和「登录没」，
    /// 而且不花模型额度、0.2 秒就返回。没登录的话测试连接必须当场说清楚，
    /// 否则用户要等到第一次提问才发现。
    func validate(config: ProviderConfig) async throws {
        guard let binary = Self.resolvePath(config.cliPath) else {
            throw ProviderError.claudeCodeNotFound
        }
        guard let result = await CLICommand.run(binary, ["auth", "status"], timeout: 15) else {
            throw ProviderError.claudeCodeNotFound
        }
        if result.timedOut { throw ProviderError.claudeCodeTimedOut(15) }
        switch Self.authenticationState(status: result.status, stdout: result.stdout) {
        case .signedOut:
            throw ProviderError.claudeCodeSignedOut
        case .failed:
            throw ProviderError.claudeCodeFailed(Self.condense(result.stderr), status: result.status)
        case .signedIn:
            return
        }
    }

    // MARK: - 事件解析

    /// `--allowedTools` 只免去确认，并不会移除其它工具。真正的边界由
    /// `--restricted`（文件仅限工作目录、忽略用户/项目配置）和
    /// `--tools Read`（只暴露 Read）共同建立。会话也不落到 Claude Code 的历史里。
    static func commandArguments(prompt: String, model: String) -> [String] {
        var arguments = [
            "-p", prompt,
            // stream-json 在 --print 下必须配 --verbose，否则直接报错退出。
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--restricted",
            "--tools", "Read",
            "--allowedTools", "Read",
            "--no-session-persistence",
        ]
        if !model.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        return arguments
    }

    enum AuthenticationState: Equatable {
        case signedIn
        case signedOut
        case failed
    }

    /// 官方约定未登录时退出码为 1，因此必须先于通用非零错误处理。
    /// 退出码为 0 但 JSON 暂时换格式时仍放行，避免 CLI 升级造成误报。
    static func authenticationState(status: Int32, stdout: String) -> AuthenticationState {
        if status == 1 { return .signedOut }
        guard status == 0 else { return .failed }
        guard let data = stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else {
            return .signedIn
        }
        return loggedIn ? .signedIn : .signedOut
    }

    struct Outcome {
        let isError: Bool
        let text: String
    }

    static func isSuccessfulCompletion(outcome: Outcome?, status: Int32) -> Bool {
        status == 0 && outcome?.isError == false
    }

    enum Event {
        case text(String)
        case finished(Outcome)
        case none
    }

    /// 只认两种事件：正文增量，和收尾的那条 result。
    ///
    /// `content_block_delta` 里除了 `text_delta` 还有 `thinking_delta`、
    /// `signature_delta`、`input_json_delta`——思考过程和工具调用参数都不该
    /// 出现在答案里，全部跳过。
    static func event(in line: String) -> Event {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return .none }

        if type == "stream_event",
           let event = object["event"] as? [String: Any],
           (event["type"] as? String) == "content_block_delta",
           let delta = event["delta"] as? [String: Any],
           (delta["type"] as? String) == "text_delta",
           let text = delta["text"] as? String,
           !text.isEmpty {
            return .text(text)
        }

        if type == "result" {
            let isError = (object["is_error"] as? Bool) ?? false
                || (object["subtype"] as? String) != "success"
            let text = (object["result"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .finished(Outcome(isError: isError, text: text))
        }

        return .none
    }

    private static func condense(_ text: String) -> String {
        let meaningful = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return String(meaningful.suffix(4).joined(separator: "\n").prefix(400))
    }

    // MARK: - 子进程的跨线程句柄

    /// 读循环阻塞在 availableData 上，Task.isCancelled 它看不见。取消和超时都不去
    /// 「通知」那个循环，而是直接杀进程：管道一 EOF，循环自然退出。
    private final class RunBox: @unchecked Sendable {
        enum Stop { case cancelled, timedOut }

        private let lock = NSLock()
        private var process: Process?
        private var stopReason: Stop?
        private var settled = false

        func adopt(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !settled else { return false }
            self.process = process
            return true
        }

        /// - Parameter onlyIfRunning: 看门狗专用。进程已经自己退出了就什么都不做，
        ///   否则答案明明已经流完，却还要挨一句「超时」。
        func stop(_ reason: Stop, onlyIfRunning: Bool = false) {
            lock.lock()
            guard !settled else { lock.unlock(); return }
            if onlyIfRunning, process?.isRunning != true { lock.unlock(); return }
            stopReason = reason
            let target = process
            settled = true
            process = nil
            lock.unlock()

            guard let target, target.isRunning else { return }
            target.terminate()
            // SIGTERM 不一定收得住，补一刀兜底。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if target.isRunning { kill(target.processIdentifier, SIGKILL) }
            }
        }

        func finish() {
            lock.lock(); settled = true; process = nil; lock.unlock()
        }

        var reason: Stop? {
            lock.lock(); defer { lock.unlock() }
            return stopReason
        }
    }

    private final class DrainBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk); lock.unlock()
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
