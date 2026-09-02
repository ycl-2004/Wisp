import Foundation

/// 走本地 `codex exec`。好处是复用你已经登录的 Codex，不用另配 API Key；
/// 代价是它每次都会带上一大段固定上下文（实测约两万 token），而且没有逐字流式，
/// 回答是一次性返回的。
struct CodexCLIProvider: ChatProvider {

    /// 一次调用的硬上限。codex 卡住不出声时，读循环阻塞在 availableData 上叫不醒，
    /// 唯一可靠的解法是从外面把进程杀掉，让管道立刻 EOF。
    static let wallClockTimeout: TimeInterval = 240

    /// GUI 应用拿不到登录 shell 的 PATH，只能自己找。
    static let searchPaths = [
        NSHomeDirectory() + "/.local/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        NSHomeDirectory() + "/.codex/packages/standalone/current/bin/codex",
    ]

    static var detectedPath: String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func resolvePath(_ configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) { return trimmed }
        return detectedPath
    }

    // MARK: - 子进程的跨线程句柄

    /// 读循环跑在 detached task 里、阻塞在 availableData 上，Task.isCancelled 它看不见。
    /// 所以取消和超时都不去「通知」那个循环，而是直接杀进程：管道一 EOF，循环自然退出。
    private final class RunBox: @unchecked Sendable {
        enum Stop { case cancelled, timedOut }

        private let lock = NSLock()
        private var process: Process?
        private var stopReason: Stop?
        private var settled = false

        /// 返回 false 表示进程还没起来就已经被取消，调用方应当立刻收手。
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
            // finish() 之后就不再受理：这一轮已经有结论了。
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

        /// 进程自己正常收尾，之后 stop() 就不该再动手。
        func finish() {
            lock.lock(); settled = true; process = nil; lock.unlock()
        }

        var reason: Stop? {
            lock.lock(); defer { lock.unlock() }
            return stopReason
        }
    }

    /// 后台把 stderr 抽干。只读 stdout 的话，codex 往 stderr 写满管道缓冲区就会卡死，
    /// 而它启动时正好会刷一批 skill 扫描的告警。
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

    // MARK: - 流式（实为一次性返回）

    func stream(messages: [[String: Any]], config: ProviderConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let box = RunBox()
            let stderrBuffer = DrainBuffer()

            let work = Task.detached {
                var workDirectory: URL?
                do {
                    guard let binary = Self.resolvePath(config.cliPath) else {
                        throw ProviderError.codexNotFound
                    }

                    let (prompt, imageData) = Self.flatten(messages)
                    let directory = try CLITemporaryDirectory.create(prefix: "Wisp-codex")
                    workDirectory = directory

                    var arguments = [
                        "exec", "--json",
                        "--skip-git-repo-check",
                        "--ephemeral",
                        "--sandbox", "read-only",
                        "--cd", directory.path,
                    ]
                    if !config.model.trimmingCharacters(in: .whitespaces).isEmpty {
                        arguments.append(contentsOf: ["--model", config.model])
                    }
                    for (index, data) in imageData.enumerated() {
                        let file = directory.appendingPathComponent("screen-\(index).jpg")
                        try data.write(to: file)
                        arguments.append(contentsOf: ["--image", file.path])
                    }
                    arguments.append("-")

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.arguments = arguments
                    var environment = ProcessInfo.processInfo.environment
                    environment["CODEX_HOME"] = environment["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
                    process.environment = environment

                    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                    process.standardInput = stdin
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

                    // 交给 RunBox 之后，取消和超时才有办法够到这个进程。
                    guard box.adopt(process) else { throw ProviderError.cancelled }

                    do {
                        try process.run()
                    } catch {
                        stderrHandle.readabilityHandler = nil
                        box.finish()
                        throw ProviderError.network(error.localizedDescription)
                    }

                    stdin.fileHandleForWriting.write(Data(prompt.utf8))
                    try? stdin.fileHandleForWriting.close()

                    var delivered = false
                    var buffer = Data()
                    let handle = stdout.fileHandleForReading

                    // 进程被 stop() 杀掉时，availableData 会立刻返回空，循环随之退出。
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        buffer.append(chunk)
                        while let range = buffer.firstRange(of: Data("\n".utf8)) {
                            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                            guard let line = String(data: lineData, encoding: .utf8),
                                  !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                            if let text = Self.assistantText(in: line) {
                                delivered = true
                                continuation.yield(text)
                            }
                        }
                    }

                    process.waitUntilExit()
                    stderrHandle.readabilityHandler = nil
                    box.finish()

                    // 循环是被杀退出的还是自己跑完的，结论完全不同。
                    if let reason = box.reason {
                        throw reason == .timedOut
                            ? ProviderError.codexTimedOut(Int(Self.wallClockTimeout))
                            : ProviderError.cancelled
                    }
                    if !delivered {
                        throw ProviderError.codexFailed(Self.condense(stderrBuffer.text),
                                                        status: process.terminationStatus)
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
                // 卡在 240 秒线上收尾的那种：读循环已经退出但 finish() 还没跑到，
                // 这时进程其实早没了，不能算超时。
                box.stop(.timedOut, onlyIfRunning: true)
            }

            continuation.onTermination = { _ in
                watchdog.cancel()
                // 先杀进程再取消 task：反过来的话读循环仍然阻塞着，取消是空的。
                box.stop(.cancelled)
                work.cancel()
            }
        }
    }

    func validate(config: ProviderConfig) async throws {
        guard let binary = Self.resolvePath(config.cliPath) else { throw ProviderError.codexNotFound }
        // `codex --version` 也可能挂住，同样给它一个上限；两条管道都由 CLICommand
        // 抽干，免得哪天 codex 在这里也刷一批 skill 扫描告警就把自己堵死。
        guard let result = await CLICommand.run(binary, ["--version"], timeout: 15) else {
            throw ProviderError.codexNotFound
        }
        if result.timedOut { throw ProviderError.codexTimedOut(15) }
        guard result.status == 0 else {
            throw ProviderError.codexFailed(String(localized: "`codex --version` 返回 \(result.status)"),
                                            status: result.status)
        }
    }

    // MARK: - 事件解析

    /// 这个版本的 codex 只在回答完成时发一条 agent_message，没有逐字增量。
    static func assistantText(in line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // 未来若出现增量事件，也一并接住。
        if let delta = object["delta"] as? [String: Any], let text = delta["text"] as? String {
            return text.isEmpty ? nil : text
        }
        guard let item = object["item"] as? [String: Any] else { return nil }
        guard let type = item["type"] as? String else { return nil }
        if type == "agent_message", let text = item["text"] as? String, !text.isEmpty {
            return text
        }
        return nil
    }

    /// 段落之间的分隔。两个 CLI provider 拼出来的 prompt 要长一个样。
    static let sectionSeparator = "\n\n---\n\n"

    /// 把 messages 摊平成正文段落，外加要附上的图片。
    ///
    /// 收尾那两段由调用方自己补。Codex 用 `--image` 把截图作为附件递进去，
    /// 全程不需要碰文件系统；AGY 的 headless 输入只收文本，截图得先落盘再报路径，
    /// 于是两边对「能不能读文件」的说法正好相反，不能共用一份。
    static func flattenBody(_ messages: [[String: Any]]) -> (sections: [String], images: [Data]) {
        var lines: [String] = []
        var images: [Data] = []

        for message in messages {
            let role = message["role"] as? String ?? "user"
            var parts: [String] = []
            if let text = message["content"] as? String {
                parts.append(text)
            } else if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    if let text = block["text"] as? String { parts.append(text) }
                    if block["type"] as? String == "image_url",
                       let holder = block["image_url"] as? [String: Any],
                       let url = holder["url"] as? String,
                       let comma = url.firstIndex(of: ","),
                       let data = Data(base64Encoded: String(url[url.index(after: comma)...])) {
                        images.append(data)
                    }
                }
            }
            let body = parts.joined(separator: "\n\n")
            guard !body.isEmpty else { continue }
            switch role {
            case "system":    lines.append(body)
            case "assistant": lines.append(String(localized: "【上一轮你的回答】\n") + body)
            default:          lines.append(String(localized: "【用户】\n") + body)
            }
        }

        return (lines, images)
    }

    /// Codex 的完整 prompt：截图作为附件递进去，全程不碰文件系统。
    static func flatten(_ messages: [[String: Any]]) -> (prompt: String, images: [Data]) {
        var (sections, images) = flattenBody(messages)
        if !images.isEmpty {
            sections.append(String(localized: "附件里是当前屏幕的截图，请结合它回答。"))
        }
        sections.append(String(localized: "只回答问题本身，不要执行任何命令，不要读写文件。"))
        return (sections.joined(separator: sectionSeparator), images)
    }

    private static func condense(_ text: String) -> String {
        let meaningful = text.components(separatedBy: "\n")
            .filter { !$0.contains("failed to scan skill path") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return String(meaningful.suffix(4).joined(separator: "\n").prefix(400))
    }
}
