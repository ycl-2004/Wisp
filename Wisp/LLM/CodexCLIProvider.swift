import Foundation

/// 复用本地 Codex 登录，通过 app-server 的 stdio JSON-RPC 接收文字增量。
/// 每轮使用独立的临时目录和 ephemeral thread，不连接用户正在运行的服务。
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

        /// 启动与取消共用锁，避免取消后才启动一个无人管理的进程。
        func start(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !settled else { throw ProviderError.cancelled }
            self.process = process
            try process.run()
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

    // MARK: - App-server streaming

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

                    var imagePaths: [String] = []
                    for (index, data) in imageData.enumerated() {
                        let file = directory.appendingPathComponent("screen-\(index).jpg")
                        try data.write(to: file)
                        imagePaths.append(file.path)
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.arguments = ["app-server", "--listen", "stdio://"]
                    process.currentDirectoryURL = directory
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

                    defer {
                        try? stdin.fileHandleForWriting.close()
                        // app-server 是长驻进程，turn/completed 后必须主动收掉。
                        Self.shutdown(process)
                        stderrHandle.readabilityHandler = nil
                        box.finish()
                    }
                    try box.start(process)

                    var session = AppServerSession(prompt: prompt, imagePaths: imagePaths,
                                                   directory: directory.path, model: config.model, responseMode: config.responseMode)
                    func send(_ message: [String: Any]) throws {
                        var data = try JSONSerialization.data(withJSONObject: message)
                        data.append(0x0A)
                        try stdin.fileHandleForWriting.write(contentsOf: data)
                    }
                    try send(AppServerSession.initializeRequest)
                    var lines = CLIJSONLines()
                    let handle = stdout.fileHandleForReading
                    while !session.completed {
                        let chunk = handle.availableData
                        for object in try lines.append(chunk, endOfFile: chunk.isEmpty) {
                            let update = try session.receive(object)
                            for message in update.requests { try send(message) }
                            for text in update.text { continuation.yield(text) }
                        }
                        if chunk.isEmpty { break }
                    }

                    // 循环是被杀退出的还是自己跑完的，结论完全不同。
                    if let reason = box.reason {
                        throw reason == .timedOut
                            ? ProviderError.codexTimedOut(Int(Self.wallClockTimeout))
                            : ProviderError.cancelled
                    }
                    if !session.completed || !session.hasText {
                        throw ProviderError.codexFailed(Self.condense(stderrBuffer.text),
                                                        status: process.isRunning ? -1 : process.terminationStatus)
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

    /// Source: https://developers.openai.com/codex/app-server
    /// Requests are sequenced after their responses; legacy codex/event notifications are ignored.
    struct AppServerSession {
        let prompt: String
        let imagePaths: [String]
        let directory: String
        let model: String
        let responseMode: ResponseMode
        private var reasoningEffort: String?
        private(set) var threadID: String?
        private(set) var completed = false
        private var initialized = false
        private var serviceTier = "default"
        private var retriedWithoutFast = false
        private var textByItem: [String: String] = [:]
        var hasText: Bool { textByItem.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

        init(prompt: String, imagePaths: [String], directory: String, model: String, responseMode: ResponseMode = .standard) {
            self.prompt = prompt
            self.imagePaths = imagePaths
            self.directory = directory
            self.model = model
            self.responseMode = responseMode
        }

        static var initializeRequest: [String: Any] {
            ["id": 0, "method": "initialize", "params": [
                "clientInfo": ["name": "wisp", "title": "Wisp", "version": "0.4.0"]
            ]]
        }

        mutating func receive(_ object: [String: Any]) throws -> (requests: [[String: Any]], text: [String]) {
            if let error = object["error"] as? [String: Any] {
                let detail = error["message"] as? String ?? "App-server error"
                if let retry = fallbackRequest(for: detail) { return ([retry], []) }
                throw ProviderError.codexFailed(detail, status: -1)
            }
            if let method = object["method"] as? String {
                // Wisp has no approval UI. Never silently approve tools or leave a request hanging.
                if object["id"] != nil {
                    throw ProviderError.codexFailed("Unsupported app-server request: \(method)", status: -1)
                }
                guard !completed, let params = object["params"] as? [String: Any],
                      let threadID, params["threadId"] as? String == threadID else { return ([], []) }
                switch method {
                case "item/agentMessage/delta":
                    guard let id = params["itemId"] as? String,
                          let delta = params["delta"] as? String, !delta.isEmpty else { return ([], []) }
                    let separator = textByItem[id] == nil && hasText ? "\n\n" : ""
                    textByItem[id, default: ""] += delta
                    return ([], [separator + delta])
                case "item/completed":
                    guard let item = params["item"] as? [String: Any],
                          item["type"] as? String == "agentMessage",
                          let id = item["id"] as? String, let text = item["text"] as? String else { return ([], []) }
                    let previous = textByItem[id] ?? ""
                    guard text.hasPrefix(previous) else {
                        throw ProviderError.codexFailed("App-server final text differs from streamed text", status: -1)
                    }
                    let suffix = String(text.dropFirst(previous.count))
                    let separator = textByItem[id] == nil && hasText ? "\n\n" : ""
                    textByItem[id] = text
                    return ([], suffix.isEmpty ? [] : [separator + suffix])
                case "turn/completed":
                    guard let turn = params["turn"] as? [String: Any], turn["status"] as? String == "completed" else {
                        let turn = params["turn"] as? [String: Any]
                        let error = turn?["error"] as? [String: Any]
                        let detail = error?["message"] as? String ?? "Codex turn did not complete"
                        if let retry = fallbackRequest(for: detail) { return ([retry], []) }
                        throw ProviderError.codexFailed(detail, status: -1)
                    }
                    completed = true
                case "error":
                    if params["willRetry"] as? Bool != true {
                        let error = params["error"] as? [String: Any]
                        let detail = error?["message"] as? String ?? "Codex turn failed"
                        if let retry = fallbackRequest(for: detail) { return ([retry], []) }
                        throw ProviderError.codexFailed(detail, status: -1)
                    }
                default: break
                }
                return ([], [])
            }
            guard let id = object["id"] as? Int, let result = object["result"] as? [String: Any] else { return ([], []) }
            if id == 0 && !initialized {
                initialized = true
                return ([["method": "initialized"], ["id": 3, "method": "model/list",
                          "params": ["includeHidden": true]]], [])
            }
            if id == 3 && threadID == nil {
                let models = result["data"] as? [[String: Any]] ?? []
                let selectedName = model.trimmingCharacters(in: .whitespacesAndNewlines)
                let selected = models.first {
                    selectedName.isEmpty ? $0["isDefault"] as? Bool == true
                        : ($0["model"] as? String == selectedName || $0["id"] as? String == selectedName)
                }
                if selected == nil, let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                    return ([["id": 3, "method": "model/list", "params": ["includeHidden": true, "cursor": cursor]]], [])
                }
                let efforts = (selected?["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                    .compactMap { $0["reasoningEffort"] as? String }
                let requested = responseMode == .quick ? "low" : "high"
                if responseMode != .standard, efforts.contains(requested) { reasoningEffort = requested }
                let tiers = selected?["serviceTiers"] as? [[String: Any]] ?? []
                if let fast = tiers.first(where: { ($0["name"] as? String)?.lowercased() == "fast" }),
                   let tier = fast["id"] as? String {
                    // Use the CLI's advertised ID (currently "priority"), not a guessed alias.
                    serviceTier = tier
                }
                return ([threadStartRequest], [])
            }
            if id == 1 && threadID == nil {
                guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                    throw ProviderError.codexFailed("Missing app-server thread ID", status: -1)
                }
                threadID = id
                var input: [[String: Any]] = [["type": "text", "text": prompt]]
                input += imagePaths.map { ["type": "localImage", "path": $0] }
                var params: [String: Any] = ["threadId": id, "input": input]
                if let reasoningEffort { params["effort"] = reasoningEffort }
                return ([["id": 2, "method": "turn/start", "params": params]], [])
            }
            return ([], [])
        }

        private var threadStartRequest: [String: Any] {
            var params: [String: Any] = ["cwd": directory, "ephemeral": true,
                                         "sandbox": "read-only", "approvalPolicy": "never",
                                         "serviceTier": serviceTier]
            let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { params["model"] = name }
            return ["id": 1, "method": "thread/start", "params": params]
        }

        /// Retry a rejected speed tier once, before any text was delivered. Other errors stay errors.
        /// A fresh ephemeral thread keeps late notifications from the failed turn out of the answer.
        private mutating func fallbackRequest(for detail: String) -> [String: Any]? {
            let message = detail.lowercased()
            guard serviceTier != "default", !retriedWithoutFast, textByItem.isEmpty,
                  ["fast", "priority", "service_tier", "service tier", "servicetier"].contains(where: message.contains)
            else { return nil }
            retriedWithoutFast = true
            serviceTier = "default"
            threadID = nil
            return threadStartRequest
        }
    }

    private static func shutdown(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }

    /// 段落之间的分隔。两个 CLI provider 拼出来的 prompt 要长一个样。
    static let sectionSeparator = "\n\n---\n\n"

    /// 把 messages 摊平成正文段落，外加要附上的图片。
    ///
    /// 收尾那两段由调用方自己补。Codex 用 `localImage` 把截图作为附件递进去，
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

/// Frame bytes before decoding UTF-8: pipe reads can split a character or a JSON line.
struct CLIJSONLines {
    private var buffer = Data()

    mutating func append(_ data: Data, endOfFile: Bool = false) throws -> [[String: Any]] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[..<newline]))
            buffer.removeSubrange(...newline)
        }
        if endOfFile && !buffer.isEmpty {
            lines.append(buffer)
            buffer = Data()
        }
        return try lines.compactMap { line in
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return nil }
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw ProviderError.network("Invalid CLI JSON event")
            }
            return object
        }
    }
}
