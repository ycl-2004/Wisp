import Foundation

/// 模型下拉的数据源。云端按 Base URL 给推荐，Codex 直接读它自己的模型缓存。
enum ModelCatalog {

    struct Preset: Identifiable, Hashable {
        var id: String { slug }
        let slug: String
        let title: String
        let note: String
    }

    /// 选中它表示要自己填。
    static let customTag = "__custom__"
    /// Codex 专用：跟随 Codex 自己的默认模型。
    static let codexDefaultTag = ""

    // MARK: - 云端

    static func cloudPresets(baseURL: String) -> [Preset] {
        let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespaces))?.host?.lowercased() ?? ""

        if host.contains("openrouter.ai") {
            return [
                Preset(slug: "z-ai/glm-5.3-flash",
                       title: "GLM-5.3 Flash",
                       note: "输入 $0.075/百万 · 131 万上下文 · 综合最稳"),
                Preset(slug: "qwen/qwen3.7-flash",
                       title: "Qwen3.7 Flash",
                       note: "输入 $0.030/百万 · 100 万上下文 · 最便宜"),
                Preset(slug: "minimax/minimax-m3:free",
                       title: "MiniMax M3（免费）",
                       note: "不花钱 · 100 万上下文 · 免费首选。付费版 $0.300/百万，说明底子不弱"),
                Preset(slug: "thinkingmachines/inkling:free",
                       title: "Inkling（免费备用）",
                       note: "不花钱 · 100 万上下文 · 免费里最强，但也最容易被占满。付费版 $1.000/百万"),
            ]
        }
        if host.contains("api.openai.com") {
            return [
                Preset(slug: "gpt-5-mini", title: "GPT-5 mini", note: "便宜，40 万上下文"),
                Preset(slug: "gpt-4o-mini", title: "GPT-4o mini", note: "老牌便宜款"),
                Preset(slug: "gpt-5", title: "GPT-5", note: "最强，也最贵"),
            ]
        }
        return []
    }

    // MARK: - Codex

    /// Codex CLI 自己把可用模型缓存在 ~/.codex/models_cache.json，直接读它，不用猜。
    static func codexPresets() -> [Preset] {
        let path = NSHomeDirectory() + "/.codex/models_cache.json"
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            return []
        }
        return models
            .filter { ($0["visibility"] as? String) == "list" }
            .filter { ($0["supported_in_api"] as? Bool) ?? true }
            .sorted { (($0["priority"] as? Int) ?? 99) < (($1["priority"] as? Int) ?? 99) }
            .compactMap { entry in
                guard let slug = entry["slug"] as? String else { return nil }
                return Preset(slug: slug,
                              title: entry["display_name"] as? String ?? slug,
                              note: entry["description"] as? String ?? "")
            }
    }

    /// Codex 缓存里记的默认模型，用来在「跟随默认」那一项上标出来。
    static var codexConfiguredModel: String? {
        let path = NSHomeDirectory() + "/.codex/config.toml"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("model") else { continue }
            let parts = trimmed.components(separatedBy: "=")
            guard parts.count >= 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return nil
    }

    /// 当前值在不在预设里。不在就说明用户自己填了别的。
    static func isCustom(_ value: String, in presets: [Preset]) -> Bool {
        !value.isEmpty && !presets.contains { $0.slug == value }
    }
}
