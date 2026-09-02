import Foundation

/// 本地 CLI 的具体后端。它们都归在上层的「Agent CLI」分组下，避免把已登录的 CLI 误归类为云端 API。
enum CLIProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case agy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "Codex CLI"
        case .agy:   return "AGY CLI"
        }
    }
}

/// 三种接法。前两种走同一套 HTTP 代码，只是默认值和校验不同；本地 CLI 走已登录的命令行。
enum ProviderKind: String, CaseIterable, Identifiable {
    case openAICompatible
    case ollama
    case codexCLI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAICompatible: return String(localized: "云端接口")
        case .ollama:           return String(localized: "Ollama 本地")
        case .codexCLI:         return "Agent CLI"
        }
    }

    var subtitle: String {
        switch self {
        case .openAICompatible: return String(localized: "任何 OpenAI 兼容接口，自带 Key")
        case .ollama:           return String(localized: "本机模型，不联网，不花钱")
        case .codexCLI:         return String(localized: "复用已登录的 Codex 或 AGY，免配 Key")
        }
    }

    var symbol: String {
        switch self {
        case .openAICompatible: return "cloud"
        case .ollama:           return "desktopcomputer"
        case .codexCLI:         return "terminal"
        }
    }

    var needsAPIKey: Bool { self == .openAICompatible }

    var supportsModelDiscovery: Bool { self == .ollama }
}

extension ProviderKind {
    static var current: ProviderKind {
        ProviderKind(rawValue: AppSettings.shared.providerKind) ?? .openAICompatible
    }
}
