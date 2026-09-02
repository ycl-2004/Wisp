import Foundation

enum ProviderError: LocalizedError {
    case missingKey
    case badBaseURL
    case unauthorized
    case rateLimited(detail: String, upstream: Bool, resetHint: String?)
    case imageUnsupported(String)
    case http(Int, String)
    case network(String)
    case cancelled
    case codexNotFound
    case codexFailed(String, status: Int32)
    case codexTimedOut(Int)
    case agyNotFound
    case agyFailed(String, status: Int32)
    case agyTimedOut(Int)
    case claudeCodeNotFound
    case claudeCodeSignedOut
    case claudeCodeFailed(String, status: Int32)
    case claudeCodeTimedOut(Int)
    case ollamaNotRunning
    case offline
    case timedOut(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return String(localized: "还没有填 API Key。请在设置里填写后再提问。")
        case .badBaseURL:
            return String(localized: "Base URL 格式不对，请填写形如 https://api.openai.com/v1 的地址。")
        case .unauthorized:
            return String(localized: "API Key 被拒绝（401）。请检查 Key 是否正确、是否有该模型的权限。")
        case .rateLimited(let detail, let upstream, let resetHint):
            var text = upstream
                ? String(localized: "被限流（429）。这次是上游供应商满了，不是你的额度用光。免费模型经常这样，等几分钟再试，或换一个付费模型。")
                : String(localized: "被限流（429）。已经碰到这家服务商的速率上限，等一会儿再试，或换一个模型。免费额度一般按每分钟和每天分开计。")
            if let resetHint, !resetHint.isEmpty { text += "\n\(resetHint)" }
            if !detail.isEmpty { text += String(localized: "\n服务端说明：\(detail)") }
            return text
        case .imageUnsupported(let detail):
            return String(localized: "这个模型或网关不接受图片输入。\(detail)")
        case .http(let code, let message):
            return String(localized: "请求失败（HTTP \(code)）：\(message)")
        case .network(let message):
            return String(localized: "网络错误：\(message)")
        case .cancelled:
            return String(localized: "已取消。")
        case .codexNotFound:
            return String(localized: "找不到 codex 可执行文件。请在设置里填它的完整路径，或先装好 Codex Cli。")
        case .codexFailed(let detail, let status):
            return String(localized: "codex 执行失败（退出码 \(status)）：\(detail)")
        case .codexTimedOut(let seconds):
            return String(localized: "codex 超过 \(seconds) 秒没有返回，已经把它停掉了。可以换个更小的模型，或者先在终端直接跑一次 codex 确认它是通的。")
        case .agyNotFound:
            return String(localized: "找不到 agy 可执行文件。请先安装并登录 Antigravity Cli，或在设置里填它的完整路径。")
        case .agyFailed(let detail, let status):
            return String(localized: "agy 执行失败（退出码 \(status)）：\(detail)")
        case .agyTimedOut(let seconds):
            return String(localized: "agy 超过 \(seconds) 秒没有返回，已经把它停掉了。可以换个更小的模型，或先在终端直接跑一次 agy 确认它是通的。")
        case .claudeCodeNotFound:
            return String(localized: "找不到 claude 可执行文件。请先安装 Claude Code，或在设置里填它的完整路径。")
        case .claudeCodeSignedOut:
            return String(localized: "Claude Code 还没有登录。在终端跑一次 `claude auth login`，之后回到这里再测一次。")
        case .claudeCodeFailed(let detail, let status):
            return String(localized: "claude 执行失败（退出码 \(status)）：\(detail)")
        case .claudeCodeTimedOut(let seconds):
            return String(localized: "claude 超过 \(seconds) 秒没有返回，已经把它停掉了。可以换个更小的模型，或先在终端直接跑一次 claude 确认它是通的。")
        case .ollamaNotRunning:
            return String(localized: "Ollama 没在运行。在设置里点「启动 Ollama」，或在终端跑 `ollama serve`。")
        case .offline:
            return String(localized: "现在连不上网。检查一下网络，或者改用 Ollama / Agent Cli 这种本地接法。")
        case .timedOut(let seconds):
            return String(localized: "等了 \(seconds) 秒还没有任何响应，已经中断。可能是网络不稳，或者这个接口太慢。")
        }
    }
}

struct ProviderConfig: Sendable {
    var kind: ProviderKind = .openAICompatible
    var baseURL: String = ""
    var apiKey: String = ""
    var model: String = ""
    var cliProvider: CLIProvider = .codex
    var cliPath: String = ""

    static func current() throws -> ProviderConfig {
        let settings = AppSettings.shared
        switch ProviderKind.current {
        case .openAICompatible:
            guard let key = KeychainStore.load(for: settings.cloudProvider) else {
                throw ProviderError.missingKey
            }
            return ProviderConfig(kind: .openAICompatible,
                                  baseURL: settings.baseURL,
                                  apiKey: key,
                                  model: settings.model)
        case .ollama:
            return ProviderConfig(kind: .ollama,
                                  baseURL: settings.ollamaBaseURL,
                                  apiKey: "ollama",
                                  model: settings.ollamaModel)
        case .codexCLI:
            switch settings.cliProvider {
            case .codex:
                return ProviderConfig(kind: .codexCLI, model: settings.codexModel,
                                      cliProvider: .codex, cliPath: settings.codexPath)
            case .agy:
                return ProviderConfig(kind: .codexCLI, model: settings.agyModel,
                                      cliProvider: .agy, cliPath: settings.agyPath)
            case .claudeCode:
                return ProviderConfig(kind: .codexCLI, model: settings.claudeCodeModel,
                                      cliProvider: .claudeCode, cliPath: settings.claudeCodePath)
            }
        }
    }

    static func provider(for kind: ProviderKind) -> ChatProvider {
        guard kind == .codexCLI else { return OpenAICompatibleProvider() }
        return provider(for: ProviderConfig(kind: .codexCLI,
                                            cliProvider: AppSettings.shared.cliProvider))
    }

    static func provider(for config: ProviderConfig) -> ChatProvider {
        guard config.kind == .codexCLI else { return OpenAICompatibleProvider() }
        switch config.cliProvider {
        case .codex:      return CodexCLIProvider()
        case .agy:        return AgyCLIProvider()
        case .claudeCode: return ClaudeCodeCLIProvider()
        }
    }
}

/// 跑一条短命令并把输出收全。两个本地 CLI provider 的辅助调用
/// （`--version`、列模型）都走这里，别再各写一份。
enum CLICommand {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        /// 到点还没退出，是被我们杀掉的。`status` 这时没有参考价值。
        let timedOut: Bool
    }

    /// stdout 和 stderr 同时抽干，谁都堵不死谁。
    ///
    /// 只挂一个从不读的 `Pipe`、或者等进程退出再读，都会在输出撑满管道缓冲区
    /// （64 KB）时死锁——codex 启动时刷的那批 skill 扫描告警就是往 stderr 写的。
    ///
    /// 返回 nil 表示进程根本没起来，调用方按「找不到可执行文件」处理。
    static func run(_ binary: String,
                    _ arguments: [String],
                    timeout: TimeInterval) async -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        // 两条管道并行读到 EOF。进程一死管道就关，两个读随之返回。
        async let outData = readToEnd(stdout.fileHandleForReading)
        async let errData = readToEnd(stderr.fileHandleForReading)

        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            // SIGTERM 不一定收得住，而收不住就是死局：管道一直开着，上面两个读
            // 永远回不来，这个调用再也不返回，设置页会一直停在「测试中…」。
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        let (out, err) = await (outData, errData)
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      stdout: String(data: out, encoding: .utf8) ?? "",
                      stderr: String(data: err, encoding: .utf8) ?? "",
                      timedOut: timedOut)
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}

/// CLI 图片输入的短生命周期工作目录。目录权限固定为 0700，命令结束后由
/// provider 调用 `remove`；如果应用被强制终止，系统临时目录仍会负责后续回收。
enum CLITemporaryDirectory {
    static func create(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    @discardableResult
    static func remove(_ directory: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: directory)
            return !FileManager.default.fileExists(atPath: directory.path)
        } catch {
            return false
        }
    }
}

/// 截图靠文件路径交给 CLI 时，摊平后的正文要补的收尾说明和长度控制。
/// Codex 走 `--image` 附件，不用这里；AGY 和 Claude Code 都用。
enum CLIPrompt {
    /// 正文末尾再补两段：截图在哪、以及这一轮的行为约束。
    ///
    /// 约束必须跟着截图一起变。Codex 那份写的是「不要读写文件」，而这两个 CLI 的
    /// 截图正是靠读文件拿到的，照搬会让它拒绝打开自己的输入。
    ///
    /// - Parameter budget: 按估算 token 记的上限，超了就自己截并标注省略。
    ///   各家的输入上限差得很远，所以由调用方给。
    static func compose(sections: [String], imagePaths: [String], budget: Int) -> String {
        var sections = fit(sections, budget: budget)
        if imagePaths.isEmpty {
            sections.append(String(localized: "只回答问题本身，不要执行任何命令，不要读写文件。"))
        } else {
            let list = imagePaths.map { "- \($0)" }.joined(separator: "\n")
            sections.append(String(localized: "下面这些文件是当前屏幕的截图，请先读取它们，再结合看到的内容回答：\n\(list)"))
            sections.append(String(localized: "只回答问题本身。除了上面列出的截图文件，不要读写任何其它文件，也不要执行别的命令。"))
        }
        return sections.joined(separator: CodexCLIProvider.sectionSeparator)
    }

    /// 把正文压进预算：每轮砍当前最长的那一段，直到进预算。
    ///
    /// 砍的是摊平后的整段，而每段里用户那句问题在末尾、上下文标注在开头，
    /// `ContextCapture.truncate` 的头 75% + 尾 25% 正好把这两头都保住，
    /// 省略标记落在中间。一轮下来长度没减少就收手，避免在截不动的内容上空转。
    static func fit(_ sections: [String], budget: Int) -> [String] {
        var sections = sections
        var total = sections.reduce(0) { $0 + estimatedTokens($1) }
        guard total > budget else { return sections }

        for _ in sections.indices {
            guard total > budget,
                  let index = sections.indices
                    .max(by: { estimatedTokens(sections[$0]) < estimatedTokens(sections[$1]) })
            else { break }

            let section = sections[index]
            let tokens = estimatedTokens(section)
            guard tokens > 0 else { break }
            // 要砍掉的 token 数按字符等比折算回字符数。
            let keep = Double(max(tokens - (total - budget), 1)) / Double(tokens)
            let allowance = max(2_000, Int(Double(section.count) * keep))
            guard allowance < section.count else { break }

            sections[index] = ContextCapture.truncate(section, limit: allowance)
            let updated = sections.reduce(0) { $0 + estimatedTokens($1) }
            if updated >= total { break }
            total = updated
        }
        return sections
    }

    /// 粗算 token：中日韩按一字一 token，其余按四字符一 token。
    /// 只用来判断要不要截，所以宁可高估，也别让内容被 CLI 悄悄丢掉。
    static func estimatedTokens(_ text: String) -> Int {
        var wide = 0
        var narrow = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x1100...0x11FF, 0x2E80...0x303F, 0x3040...0x33FF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F,
                 0xAC00...0xD7FF, 0xF900...0xFAFF, 0xFE30...0xFE4F,
                 0xFF00...0xFF60, 0x20000...0x3FFFF:
                wide += 1
            default:
                narrow += 1
            }
        }
        return wide + narrow / 4
    }
}

protocol ChatProvider {
    /// 流式回答，逐段吐出增量文本。
    func stream(messages: [[String: Any]], config: ProviderConfig) -> AsyncThrowingStream<String, Error>
    /// 用一张小图验证 Key、模型与图片支持。
    func validate(config: ProviderConfig) async throws
}
