import Foundation

/// 走本地 `agy`。AGY 自己负责登录、模型额度和会话；Wisp 只调用它的 CLI，
/// 所以这里属于「Agent CLI」分组，而不是云端 API。
///
/// 截图和纯文本走同一条 headless 通道。AGY 的 headless 输入只收文本，
/// `image_url` 内容块会被直接拒掉，但它会去读 prompt 里点名的图片文件，
/// 所以截图落到临时工作目录、在正文里报路径就够了。
struct AgyCLIProvider: ChatProvider {
    /// 这是故意比普通网络请求长：AGY 首次启动会扫描本地配置和 skills，
    /// 带截图时还要多一轮读文件的工具调用。
    static let wallClockTimeout: TimeInterval = 300

    /// 一次请求塞给 AGY 的上限，按估算 token 记。
    ///
    /// AGY 自己也有输入上限，实测卡在约 71,400 token，而且是**静默**截断：
    /// 29 万字的正文送进去只算了 7.1 万 token，埋在中间的整段就此消失，模型
    /// 还当读到的是全文，答「正文里没有实质内容」。换成 stdin 的 stream-json
    /// 通道结果一样，所以这是 AGY 的行为，不是传输方式的问题。
    ///
    /// 与其被它悄悄截，不如我们自己截、并且把省略说清楚——`ContextCapture.truncate`
    /// 会留下省略标记，模型据此知道缺了哪一段、缺了多少。
    ///
    /// 取 56,000 是量出来的，不是拍的。AGY 自带约 30,400 token 的固定开销（空提示
    /// 就要这么多），截图另算约 1,150（它是用工具读文件，不把图内联进上下文）。
    /// 默认 60,000 字上限的单轮请求实测本地估算 52,612、实际 67,877 token，未触顶，
    /// 正文与截图都读得到，所以预算必须高于它，才不会把这条已验证可用的主路径截坏；
    /// 而估算到 65,000 时 AGY 开始不稳，三次里两次返回空回答。56,000 卡在两者之间。
    static let promptBudget = 56_000

    /// GUI 应用拿不到登录 shell 的 PATH，常见安装位置都要主动扫。
    /// `~/.local/bin/agy` 是当前安装位置；如果 AGY 更新原地替换它，下一次扫描自然拿到新版本。
    static let searchPaths = [
        NSHomeDirectory() + "/.local/bin/agy",
        "/opt/homebrew/bin/agy",
        "/usr/local/bin/agy",
    ]

    private static var candidatePaths: [String] {
        var paths = searchPaths
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths += path.split(separator: ":").map { String($0) + "/agy" }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// 只检查路径，不缓存版本号。这样 AGY 更新后不需要重置 Wisp 设置。
    static var detectedPath: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func resolvePath(_ configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) { return trimmed }
        return detectedPath
    }

    /// 多个安装位置同时存在时，实际读取每个候选的版本并选最新的那个。
    /// 不缓存结果，AGY 原地升级或切换安装位置后下一次请求就会重新判断。
    static func latestDetectedPath() async -> String? {
        let candidates = candidatePaths.filter { FileManager.default.isExecutableFile(atPath: $0) }
        guard candidates.count > 1 else { return candidates.first }

        let versions = await withTaskGroup(of: (String, [Int]?).self, returning: [(String, [Int]?)].self) { group in
            for path in candidates {
                group.addTask { (path, await versionNumbers(at: path)) }
            }
            var values: [(String, [Int]?)] = []
            for await value in group { values.append(value) }
            return values
        }

        var best = versions.first!
        for candidate in versions.dropFirst() {
            guard let version = candidate.1 else { continue }
            if best.1 == nil || isNewer(version, than: best.1!) {
                best = candidate
            }
        }
        return best.0
    }

    /// 每次扫描都重新执行 `agy models`，不把模型列表写死在 App 里。
    static func scanModels(configuredPath: String = "") async -> [ModelCatalog.Preset] {
        guard let binary = await pathForUse(configuredPath),
              let result = await CLICommand.run(binary, ["models"], timeout: 30),
              result.status == 0 else { return [] }
        return parseModels(result.stdout)
    }

    /// 没有成功扫描时仅用于 UI 首屏，真实请求仍然允许用户手填任意新模型名。
    /// 下一次「刷新 AGY 模型」会以 CLI 的实际输出覆盖它。
    static let fallbackModels: [ModelCatalog.Preset] = [
        .init(slug: "gemini-3.8-flash-high", title: "Gemini 3.8 Flash (High)", note: ""),
        .init(slug: "gemini-3.8-flash-medium", title: "Gemini 3.8 Flash (Medium)", note: ""),
        .init(slug: "gemini-3.8-flash-low", title: "Gemini 3.8 Flash (Low)", note: ""),
        .init(slug: "gemini-3.7-flash-high", title: "Gemini 3.7 Flash (High)", note: ""),
        .init(slug: "gemini-3.7-flash-medium", title: "Gemini 3.7 Flash (Medium)", note: ""),
        .init(slug: "gemini-3.7-flash-low", title: "Gemini 3.7 Flash (Low)", note: ""),
        .init(slug: "gemini-3.6-flash-high", title: "Gemini 3.6 Flash (High)", note: ""),
        .init(slug: "gemini-3.6-flash-medium", title: "Gemini 3.6 Flash (Medium)", note: ""),
        .init(slug: "gemini-3.6-flash-low", title: "Gemini 3.6 Flash (Low)", note: ""),
        .init(slug: "gemini-3.1-pro-high", title: "Gemini 3.1 Pro (High)", note: ""),
        .init(slug: "gemini-3.1-pro-low", title: "Gemini 3.1 Pro (Low)", note: ""),
        .init(slug: "claude-sonnet-4-6", title: "Claude Sonnet 4.6 (Thinking)", note: ""),
        .init(slug: "claude-opus-4-6-thinking", title: "Claude Opus 4.6 (Thinking)", note: ""),
        .init(slug: "gpt-oss-120b-medium", title: "GPT-OSS 120B (Medium)", note: ""),
    ]

    func stream(messages: [[String: Any]], config: ProviderConfig) -> AsyncThrowingStream<String, Error> {
        let flattened = CodexCLIProvider.flattenBody(messages)

        return AsyncThrowingStream { continuation in
            let box = RunBox()
            let work = Task.detached(priority: .userInitiated) {
                var workDirectory: URL?
                do {
                    guard let binary = await Self.pathForUse(config.cliPath) else {
                        throw ProviderError.agyNotFound
                    }

                    // 工作目录既是 AGY 的 workspace，也是这一轮截图的落脚点。
                    // 不指定的话 AGY 会把 GUI 进程的当前目录当成 workspace，
                    // 而那是用户的文件系统根目录。
                    let directory = try CLITemporaryDirectory.create(prefix: "Wisp-agy")
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
                    try await Self.runHeadless(prompt: prompt,
                                               binary: binary,
                                               model: config.model,
                                               workDirectory: directory,
                                               box: box,
                                               onText: { continuation.yield($0) })
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

    func validate(config: ProviderConfig) async throws {
        guard let binary = await Self.pathForUse(config.cliPath) else { throw ProviderError.agyNotFound }
        guard let result = await CLICommand.run(binary, ["--version"], timeout: 15) else {
            throw ProviderError.agyNotFound
        }
        if result.timedOut { throw ProviderError.agyTimedOut(15) }
        guard result.status == 0 else {
            throw ProviderError.agyFailed(Self.condense(result.stderr), status: result.status)
        }
    }

    // MARK: - Headless

    private static func runHeadless(prompt: String,
                                    binary: String,
                                    model: String,
                                    workDirectory: URL,
                                    box: RunBox,
                                    onText: (String) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.currentDirectoryURL = workDirectory

        var arguments = ["-p", prompt,
                         "--output-format", "stream-json",
                         "--print-timeout", "\(Int(wallClockTimeout))s",
                         "--sandbox"]
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stderrBuffer = DrainBuffer()
        let stderrHandle = stderr.fileHandleForReading
        // 后台把 stderr 抽干。只读 stdout 的话，AGY 往 stderr 写满管道缓冲区就会卡死。
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(chunk)
            }
        }

        defer {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                process.waitUntilExit()
            }
            stderrHandle.readabilityHandler = nil
            box.finish()
        }
        try box.start(process)

        var lines = CLIJSONLines()
        var state = StreamState()
        while true {
            let chunk = stdout.fileHandleForReading.availableData
            for object in try lines.append(chunk, endOfFile: chunk.isEmpty) {
                if let text = try state.receive(object) { onText(text) }
            }
            if chunk.isEmpty { break }
        }
        process.waitUntilExit()

        if let reason = box.reason {
            throw reason == .timedOut
                ? ProviderError.agyTimedOut(Int(Self.wallClockTimeout))
                : ProviderError.cancelled
        }
        guard process.terminationStatus == 0 else {
            throw ProviderError.agyFailed(Self.condense(stderrBuffer.text), status: process.terminationStatus)
        }
        guard state.completed else {
            throw ProviderError.agyFailed("AGY stream ended without a result", status: process.terminationStatus)
        }
    }

    // MARK: - 子进程

    /// 读循环跑在 detached task 里、阻塞在 availableData 上，Task.isCancelled 它看不见。
    /// 所以取消和超时都不去「通知」那个循环，而是直接杀进程：管道一 EOF，循环自然退出。
    private final class RunBox: @unchecked Sendable {
        enum Stop { case cancelled, timedOut }

        private let lock = NSLock()
        private var process: Process?
        private var stopReason: Stop?
        private var settled = false

        func start(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !settled else { throw ProviderError.cancelled }
            self.process = process
            try process.run()
        }

        /// - Parameter onlyIfRunning: 看门狗专用。进程已经自己退出了就什么都不做，
        ///   否则答案明明已经拿到，却还要挨一句「超时」。
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

    private static func pathForUse(_ configured: String) async -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) { return trimmed }
        return await latestDetectedPath() ?? detectedPath
    }

    private static func versionNumbers(at path: String) async -> [Int]? {
        guard let result = await CLICommand.run(path, ["--version"], timeout: 5),
              result.status == 0 else { return nil }
        guard let match = result.stdout.range(of: "[0-9]+(?:\\.[0-9]+)+", options: .regularExpression) else {
            return nil
        }
        return result.stdout[match].split(separator: ".").compactMap { Int($0) }
    }

    private static func isNewer(_ candidate: [Int], than current: [Int]) -> Bool {
        let count = max(candidate.count, current.count)
        for index in 0..<count {
            let left = index < candidate.count ? candidate[index] : 0
            let right = index < current.count ? current[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - 解析

    /// `agy models` 每行是 `slug<TAB>标题`。进度提示走的是 stderr，stdout 只有列表。
    private static func parseModels(_ text: String) -> [ModelCatalog.Preset] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let slugPart = parts.first else { return nil }
            let slug = String(slugPart)
            guard slug.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
                  seen.insert(slug).inserted else { return nil }
            let title = parts.count > 1 ? String(parts[1]) : slug
            return ModelCatalog.Preset(slug: slug, title: title, note: "")
        }
    }

    /// Verified against AGY 1.1.27: step_update carries incremental text, result repeats the final answer.
    struct StreamState {
        private(set) var completed = false
        private var streamed = ""
        private var lastStep: Int?

        mutating func receive(_ object: [String: Any]) throws -> String? {
            guard !completed else { return nil }
            switch object["event"] as? String {
            case "step_update":
                guard let step = object["step_update"] as? [String: Any],
                      step["step_type"] as? String == "agent_response",
                      let delta = step["text_delta"] as? String, !delta.isEmpty else { return nil }
                let index = step["step_index"] as? Int
                let separator = !streamed.isEmpty && index != nil && index != lastStep ? "\n\n" : ""
                lastStep = index
                streamed += separator + delta
                return separator + delta
            case "result":
                guard let result = object["result"] as? [String: Any] else {
                    throw ProviderError.agyFailed("Invalid AGY result", status: -1)
                }
                guard result["status"] as? String == "SUCCESS" else {
                    throw ProviderError.agyFailed(Self.failureDetail(result), status: -1)
                }
                let response = result["response"] as? String ?? ""
                guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ProviderError.agyFailed(String(localized: "Agy 返回了空回答，没有说明原因。多半是这一轮上下文顶到了它的输入上限，或者短时间内发得太密。可以把「页面文字上限」调小一些再试。"), status: -1)
                }
                completed = true
                // Some versions only emit a final response. Never append it twice after deltas.
                if streamed.isEmpty { streamed = response; return response }
                if response.hasPrefix(streamed) {
                    let suffix = String(response.dropFirst(streamed.count))
                    streamed = response
                    return suffix.isEmpty ? nil : suffix
                }
                return nil
            case "error":
                throw ProviderError.agyFailed(Self.failureDetail(object), status: -1)
            default: return nil
            }
        }

        private static func failureDetail(_ object: [String: Any]) -> String {
            if let error = object["error"] as? String, !error.isEmpty { return AgyCLIProvider.condense(error) }
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return AgyCLIProvider.condense(message)
            }
            return "AGY status=\(object["status"] as? String ?? "ERROR")"
        }
    }

    private static func condense(_ text: String) -> String {
        let meaningful = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return String(meaningful.suffix(4).joined(separator: "\n").prefix(400))
    }
}
