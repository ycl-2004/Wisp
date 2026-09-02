import Foundation

/// 云端接法下具体走哪一家。选中一家就带出它的 Base URL 和模型列表，
/// `.custom` 保留手填任意 OpenAI 兼容地址的老行为。
///
/// 收录门槛：Wisp 每次都发截图，所以只收 OpenAI 兼容 chat/completions
/// + SSE 流式 + `image_url` data URL 三样都支持的家。
enum CloudProvider: String, CaseIterable, Identifiable {
    case openRouter
    case gemini
    case openAI
    case anthropic
    case zhipu
    case custom

    var id: String { rawValue }

    /// 下拉里排在「自定义」前面的那些。
    static var builtIn: [CloudProvider] { allCases.filter { $0 != .custom } }

    var title: String {
        switch self {
        case .openRouter:   return "OpenRouter"
        case .gemini:       return "Google Gemini"
        case .openAI:       return "OpenAI"
        case .anthropic:    return "Anthropic"
        case .zhipu:        return String(localized: "智谱 GLM")
        case .custom:       return String(localized: "自定义…")
        }
    }

    /// 选中即写进设置的 Base URL。`.custom` 没有，由用户自己填。
    var baseURL: String? {
        switch self {
        case .openRouter:   return "https://openrouter.ai/api/v1"
        case .gemini:       return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openAI:       return "https://api.openai.com/v1"
        case .anthropic:    return "https://api.anthropic.com/v1"
        case .zhipu:        return "https://open.bigmodel.cn/api/paas/v4"
        case .custom:       return nil
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openRouter:   return "sk-or-v1-…"
        case .gemini:       return "AIza…"
        case .openAI:       return "sk-…"
        case .anthropic:    return "sk-ant-…"
        case .zhipu:        return "…"
        case .custom:       return "sk-…"
        }
    }

    /// 去哪儿领 Key。设置页 API Key 那行的「获取」链接。
    var keyConsoleURL: URL? {
        switch self {
        case .openRouter:   return URL(string: "https://openrouter.ai/keys")
        case .gemini:       return URL(string: "https://aistudio.google.com/apikey")
        case .openAI:       return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic:    return URL(string: "https://platform.claude.com/settings/keys")
        case .zhipu:        return URL(string: "https://open.bigmodel.cn/usercenter/apikeys")
        case .custom:       return nil
        }
    }

    /// 这一家值得先说一句的事。nil 表示没有。
    var note: String? {
        switch self {
        case .openRouter:
            return String(localized: "一个 Key 通到各家模型，带若干免费模型。免费模型限流严，付费模型更稳。")
        case .gemini:
            return String(localized: "Flash 和 Flash-Lite 有免费额度，不用绑卡；Pro 系列只能付费用。截图场景性价比最高。")
        case .openAI:
            return String(localized: "GPT-5.6 三档全系支持图片输入，按量计费，没有免费额度。")
        case .anthropic:
            return String(localized: "走 Anthropic 的 OpenAI 兼容层。图片输入官方标注完全支持，但这层的官方定位是「测试和对比模型能力」，不承诺长期生产可用。")
        case .zhipu:
            return String(localized: "国内可直连。GLM-4.6V Flash 免费，GLM-5.3-Flash 是原生多模态、100 万上下文。")
        case .custom:
            return nil
        }
    }

    /// 这一家在钥匙串里的账号名。一家一份，切换时不会互相顶掉。
    var keychainAccount: String { "api-key.\(rawValue)" }

    /// 切到这一家时默认选中的模型。
    var defaultModel: String { presets.first?.slug ?? "" }

    // MARK: - 模型

    /// 每家挑 3–5 个够用的，剩下的交给「自定义」。
    var presets: [ModelCatalog.Preset] {
        switch self {
        case .openRouter:
            return [
                .init(slug: "z-ai/glm-5.3-flash",
                      title: "GLM-5.3 Flash",
                      note: String(localized: "输入 $0.075/百万 · 131 万上下文 · 综合最稳")),
                .init(slug: "qwen/qwen3.7-flash",
                      title: "Qwen3.7 Flash",
                      note: String(localized: "输入 $0.030/百万 · 100 万上下文 · 最便宜")),
                .init(slug: "minimax/minimax-m3:free",
                      title: String(localized: "MiniMax M3（免费）"),
                      note: String(localized: "不花钱 · 100 万上下文 · 免费首选。付费版 $0.300/百万，说明底子不弱")),
                .init(slug: "thinkingmachines/inkling:free",
                      title: String(localized: "Inkling（免费备用）"),
                      note: String(localized: "不花钱 · 100 万上下文 · 免费里最强，但也最容易被占满。付费版 $1.000/百万")),
            ]

        case .gemini:
            return [
                .init(slug: "gemini-3.5-flash-lite",
                      title: "Gemini 3.5 Flash-Lite",
                      note: String(localized: "最快最省 · 免费额度里限额最宽（15 次/分、1000 次/天）")),
                .init(slug: "gemini-3.7-flash",
                      title: "Gemini 3.7 Flash",
                      note: String(localized: "当前主力 Flash · 多模态最稳 · 免费额度 10 次/分、250 次/天")),
                .init(slug: "gemini-3.6-flash",
                      title: "Gemini 3.6 Flash",
                      note: String(localized: "上一代 Flash · 速度和能力折中")),
                .init(slug: "gemini-2.5-flash",
                      title: "Gemini 2.5 Flash",
                      note: String(localized: "老牌性价比款 · 跑得久，行为最可预期")),
            ]

        case .openAI:
            return [
                .init(slug: "gpt-5.6-luna",
                      title: "GPT-5.6 Luna",
                      note: String(localized: "输入 $0.20/百万 · 最省，日常够用")),
                .init(slug: "gpt-5.6-terra",
                      title: "GPT-5.6 Terra",
                      note: String(localized: "输入 $2.00/百万 · 能力和成本的平衡点")),
                .init(slug: "gpt-5.6-sol",
                      title: "GPT-5.6 Sol",
                      note: String(localized: "输入 $5.00/百万 · 最强，也最贵")),
            ]

        case .anthropic:
            return [
                .init(slug: "claude-haiku-4-5-20251001",
                      title: "Claude Haiku 4.5",
                      note: String(localized: "最快最省的一档，适合看一眼截图就答")),
                .init(slug: "claude-sonnet-5",
                      title: "Claude Sonnet 5",
                      note: String(localized: "日常主力，长正文和截图混着读也稳")),
                .init(slug: "claude-opus-5",
                      title: "Claude Opus 5",
                      note: String(localized: "最强的一档，慢且贵，留给硬问题")),
            ]

        case .zhipu:
            return [
                .init(slug: "glm-5.3-flash",
                      title: "GLM-5.3 Flash",
                      note: String(localized: "原生多模态 · 100 万上下文 · GLM-5.3 的十分之一价")),
                .init(slug: "glm-4.6v-flash",
                      title: String(localized: "GLM-4.6V Flash（免费）"),
                      note: String(localized: "不花钱的视觉模型，日常看截图够用")),
                .init(slug: "glm-4.6v",
                      title: "GLM-4.6V",
                      note: String(localized: "付费视觉主力，比 Flash 版读图更细")),
                .init(slug: "glm-5v-turbo",
                      title: "GLM-5V-Turbo",
                      note: String(localized: "偏界面和代码截图理解")),
            ]

        case .custom:
            return []
        }
    }

    // MARK: - 从 Base URL 反查

    /// 只存了 Base URL 的老配置（0.2.x）靠它认出是哪一家；
    /// 用户在「自定义」里手填了某家的地址时，也靠它把模型列表带出来。
    static func matching(baseURL: String) -> CloudProvider? {
        guard let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespaces))?
            .host?.lowercased() else { return nil }
        return builtIn.first { candidate in
            guard let candidateHost = URLComponents(string: candidate.baseURL ?? "")?.host?.lowercased()
            else { return false }
            return host == candidateHost
        }
    }
}
