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
            return String(localized: "找不到 codex 可执行文件。请在设置里填它的完整路径，或先装好 Codex CLI。")
        case .codexFailed(let detail, let status):
            return String(localized: "codex 执行失败（退出码 \(status)）：\(detail)")
        case .codexTimedOut(let seconds):
            return String(localized: "codex 超过 \(seconds) 秒没有返回，已经把它停掉了。可以换个更小的模型，或者先在终端直接跑一次 codex 确认它是通的。")
        case .ollamaNotRunning:
            return String(localized: "Ollama 没在运行。在设置里点「启动 Ollama」，或在终端跑 `ollama serve`。")
        case .offline:
            return String(localized: "现在连不上网。检查一下网络，或者改用 Ollama / Codex CLI 这种本地接法。")
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
    var codexPath: String = ""

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
            return ProviderConfig(kind: .codexCLI,
                                  model: settings.codexModel,
                                  codexPath: settings.codexPath)
        }
    }

    static func provider(for kind: ProviderKind) -> ChatProvider {
        kind == .codexCLI ? CodexCLIProvider() : OpenAICompatibleProvider()
    }
}

protocol ChatProvider {
    /// 流式回答，逐段吐出增量文本。
    func stream(messages: [[String: Any]], config: ProviderConfig) -> AsyncThrowingStream<String, Error>
    /// 用一张小图验证 Key、模型与图片支持。
    func validate(config: ProviderConfig) async throws
}
