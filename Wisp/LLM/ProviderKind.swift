import Foundation

/// 三种接法。前两种走同一套 HTTP 代码，只是默认值和校验不同；Codex 走本地命令行。
enum ProviderKind: String, CaseIterable, Identifiable {
    case openAICompatible
    case ollama
    case codexCLI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAICompatible: return "云端接口"
        case .ollama:           return "Ollama 本地"
        case .codexCLI:         return "Codex CLI"
        }
    }

    var subtitle: String {
        switch self {
        case .openAICompatible: return "任何 OpenAI 兼容接口，自带 Key"
        case .ollama:           return "本机模型，不联网，不花钱"
        case .codexCLI:         return "复用已登录的 Codex，免配 Key"
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
