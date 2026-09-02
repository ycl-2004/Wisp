import Foundation

/// 走本地 `codex exec`。好处是复用你已经登录的 Codex，不用另配 API Key；
/// 代价是它每次都会带上一大段固定上下文（实测约两万 token），而且没有逐字流式，
/// 回答是一次性返回的。
struct CodexCLIProvider: ChatProvider {

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

    // MARK: - 流式（实为一次性返回）

    func stream(messages: [[String: Any]], config: ProviderConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task.detached {
                var workDirectory: URL?
                do {
                    guard let binary = Self.resolvePath(config.codexPath) else {
                        throw ProviderError.codexNotFound
                    }

                    let (prompt, imageData) = Self.flatten(messages)
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Wisp-codex-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

                    try process.run()
                    stdin.fileHandleForWriting.write(Data(prompt.utf8))
                    try? stdin.fileHandleForWriting.close()

                    var delivered = false
                    var buffer = Data()
                    let handle = stdout.fileHandleForReading

                    while true {
                        if Task.isCancelled {
                            process.terminate()
                            throw ProviderError.cancelled
                        }
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

                    if !delivered {
                        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                               encoding: .utf8) ?? ""
                        throw ProviderError.codexFailed(Self.condense(errorText),
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
                if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    func validate(config: ProviderConfig) async throws {
        guard let binary = Self.resolvePath(config.codexPath) else { throw ProviderError.codexNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProviderError.codexFailed("`codex --version` 返回 \(process.terminationStatus)",
                                            status: process.terminationStatus)
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

    /// 把 messages 摊平成一段纯文本，外加要附上的图片。
    static func flatten(_ messages: [[String: Any]]) -> (prompt: String, images: [Data]) {
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
            case "assistant": lines.append("【上一轮你的回答】\n" + body)
            default:          lines.append("【用户】\n" + body)
            }
        }

        if !images.isEmpty {
            lines.append("附件里是当前屏幕的截图，请结合它回答。")
        }
        lines.append("只回答问题本身，不要执行任何命令，不要读写文件。")
        return (lines.joined(separator: "\n\n---\n\n"), images)
    }

    private static func condense(_ text: String) -> String {
        let meaningful = text.components(separatedBy: "\n")
            .filter { !$0.contains("failed to scan skill path") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return String(meaningful.suffix(4).joined(separator: "\n").prefix(400))
    }
}
