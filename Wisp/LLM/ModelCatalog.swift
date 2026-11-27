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

    private static var defaultCodexHome: String {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            return home
        }
        return NSHomeDirectory() + "/.codex"
    }

    /// Codex CLI 自己把可用模型缓存在 ~/.codex/models_cache.json，直接读它，不用猜。
    static func codexPresets(codexHome: String? = nil) -> [Preset] {
        let path = (codexHome ?? defaultCodexHome) + "/models_cache.json"
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
    static var codexConfiguredModel: String? { codexConfiguredModel() }

    static func codexConfiguredModel(codexHome: String? = nil) -> String? {
        let path = (codexHome ?? defaultCodexHome) + "/config.toml"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parseTopLevelTOMLModel(text)
    }

    static func parseTopLevelTOMLModel(_ text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // 顶层键在任何 [table] 段之前；进段后遇到的 model 属于 profile 或 provider。
            if trimmed.hasPrefix("[") { break }
            guard let eq = trimmed.firstIndex(of: "="),
                  trimmed[..<eq].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let rhs = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let quote = rhs.first, quote == "\"" || quote == "'" {
                let rest = rhs.dropFirst()
                if let closing = rest.firstIndex(of: quote) {
                    let value = String(rest[..<closing]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : value
                }
            }
            let uncommented = rhs.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let value = String(uncommented).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 当前值在不在预设里。不在就说明用户自己填了别的。
    static func isCustom(_ value: String, in presets: [Preset]) -> Bool {
        !value.isEmpty && !presets.contains { $0.slug == value }
    }

    /// 同一个模型的 High 思考档：`gemini-4-neon-low` → `gemini-4-neon-high`。
    /// 只认清单里真有的那一个；已经是 `-xhigh` 或不带档位就返回 nil（绝不把 `-xhigh` 降成 `-high`）。
    static func highThinkingSibling(of slug: String, in presets: [Preset]) -> String? {
        guard let level = ["-low", "-medium", "-high"].first(where: slug.hasSuffix) else { return nil }
        let base = String(slug.dropLast(level.count))
        let high = base + "-high"
        if presets.contains(where: { $0.slug == high }) { return high }
        if level != "-high" {
            let xhigh = base + "-xhigh"
            if presets.contains(where: { $0.slug == xhigh }) { return xhigh }
        }
        return nil
    }
}
