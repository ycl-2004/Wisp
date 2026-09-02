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

    /// 云端模型列表跟着服务商走。选了「自定义」就按用户填的 Base URL 反查一次，
    /// 手填的地址正好是某家时照样能带出推荐。
    static func cloudPresets(provider: CloudProvider, baseURL: String) -> [Preset] {
        guard provider == .custom else { return provider.presets }
        return CloudProvider.matching(baseURL: baseURL)?.presets ?? []
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
