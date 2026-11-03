import Foundation

/// 本地 CLI 的具体后端。它们都归在上层的「Agent CLI」分组下，避免把已登录的 CLI 误归类为云端 API。
enum CLIProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case agy
    case claudeCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:      return "Codex Cli"
        case .agy:        return "Antigravity Cli"
        case .claudeCode: return "Claude Code Cli"
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
        case .codexCLI:         return "Agent Cli"
        }
    }

    /// 卡片副标题说「适合谁」，不说实现（UX 改造第 4 项）：新用户是按
    /// 自己的处境挑接法的——有没有 Key、愿不愿意装东西、本机有没有
    /// 现成的登录。设置页与向导共用这组卡片，两处同一个说法。
    var subtitle: String {
        switch self {
        case .openAICompatible: return String(localized: "用 OpenAI、OpenRouter 等服务的 Key · 最通用")
        case .ollama:           return String(localized: "需先装好 Ollama · 不联网 · 不花钱")
        case .codexCLI:         return String(localized: "已装并登录的话，什么都不用填")
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
