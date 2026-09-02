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
    case ollamaNotRunning

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "还没有填 API Key。请在设置里填写后再提问。"
        case .badBaseURL:
            return "Base URL 格式不对，请填写形如 https://api.openai.com/v1 的地址。"
        case .unauthorized:
            return "API Key 被拒绝（401）。请检查 Key 是否正确、是否有该模型的权限。"
        case .rateLimited(let detail, let upstream, let resetHint):
            var text = upstream
                ? "被限流（429）。这次是上游供应商满了，不是你的额度用光。免费模型经常这样，等几分钟再试，或换一个付费模型。"
                : "被限流（429）。免费模型的额度是每分钟 20 次、每天 50 次；OpenRouter 账户充值满 10 credits 后每天上限提到 1000 次。"
            if let resetHint, !resetHint.isEmpty { text += "\n\(resetHint)" }
            if !detail.isEmpty { text += "\n服务端说明：\(detail)" }
            return text
        case .imageUnsupported(let detail):
            return "这个模型或网关不接受图片输入。\(detail)"
        case .http(let code, let message):
            return "请求失败（HTTP \(code)）：\(message)"
        case .network(let message):
            return "网络错误：\(message)"
        case .cancelled:
            return "已取消。"
        case .codexNotFound:
            return "找不到 codex 可执行文件。请在设置里填它的完整路径，或先装好 Codex CLI。"
        case .codexFailed(let detail, let status):
            return "codex 执行失败（退出码 \(status)）：\(detail)"
        case .ollamaNotRunning:
            return "Ollama 没在运行。在设置里点「启动 Ollama」，或在终端跑 `ollama serve`。"
        }
    }
}

struct ProviderConfig {
    var kind: ProviderKind = .openAICompatible
    var baseURL: String = ""
    var apiKey: String = ""
    var model: String = ""
    var codexPath: String = ""

    static func current() throws -> ProviderConfig {
        let settings = AppSettings.shared
        switch ProviderKind.current {
        case .openAICompatible:
            guard let key = KeychainStore.load() else { throw ProviderError.missingKey }
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
