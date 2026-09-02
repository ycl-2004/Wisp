import Foundation

/// Chromium 的「Allow JavaScript from Apple Events」是每个配置文件各自独立的开关。
/// 这里直接读本地偏好文件，好在出错时告诉用户到底是哪个配置文件没开。
enum ChromeProfileInspector {

    struct Profile {
        var directoryName: String
        var displayName: String
        var allowsJavaScript: Bool
    }

    /// bundle id → Chromium user data 目录（相对 ~/Library/Application Support）。
    private static let userDataPaths: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.dev": "Google/Chrome Dev",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.brave.Browser.beta": "BraveSoftware/Brave-Browser-Beta",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.microsoft.edgemac.Beta": "Microsoft Edge Beta",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    static func supportsInspection(bundleID: String) -> Bool {
        userDataPaths[bundleID] != nil
    }

    /// 读取该浏览器所有在用的配置文件及其开关状态。读不到就返回空数组。
    static func profiles(bundleID: String) -> [Profile] {
        guard let relative = userDataPaths[bundleID] else { return [] }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(relative, isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }

        // Local State 的 info_cache 列出真正在用的配置文件，避免报出早已废弃的残留目录。
        var directories: [String] = []
        var displayNames: [String: String] = [:]
        if let data = try? Data(contentsOf: base.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = json["profile"] as? [String: Any],
           let cache = profile["info_cache"] as? [String: Any] {
            for (directory, value) in cache {
                directories.append(directory)
                if let entry = value as? [String: Any], let name = entry["name"] as? String {
                    displayNames[directory] = name
                }
            }
        }
        if directories.isEmpty {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
            directories = contents.filter { name in
                name == "Default" || name.hasPrefix("Profile ")
            }
        }

        return directories.sorted().compactMap { directory -> Profile? in
            let prefs = base.appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent("Preferences")
            guard let data = try? Data(contentsOf: prefs),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let browser = json["browser"] as? [String: Any]
            var allowed = (browser?["allow_javascript_apple_events"] as? Bool) ?? false
            if !allowed,
               let account = json["account_values"] as? [String: Any],
               let accountBrowser = account["browser"] as? [String: Any],
               let value = accountBrowser["allow_javascript_apple_events"] as? Bool {
                allowed = value
            }
            let name = displayNames[directory]
                ?? ((json["profile"] as? [String: Any])?["name"] as? String)
                ?? directory
            return Profile(directoryName: directory, displayName: name, allowsJavaScript: allowed)
        }
    }

    /// JS 被拒时给出的说明：点名哪些配置文件没开。
    static func javaScriptDisabledHint(bundleID: String, appName: String) -> String {
        let list = profiles(bundleID: bundleID)
        guard !list.isEmpty else {
            return "\(appName) 没有开启「Allow JavaScript from Apple Events」，本次只读到网址，没有整页文字。在 \(appName) 的「View → Developer」里打开一次即可。"
        }
        let off = list.filter { !$0.allowsJavaScript }.map(\.displayName)
        let on = list.filter { $0.allowsJavaScript }.map(\.displayName)

        var text = "当前窗口所属的 \(appName) 配置文件没有开启「Allow JavaScript from Apple Events」，所以只读到网址，没有整页文字。这个开关每个配置文件要各开一次。"
        text += "\n开法：切到该配置文件的窗口，菜单栏「View → Developer → Allow JavaScript from Apple Events」。"
        if !off.isEmpty || !on.isEmpty {
            var detail = "按本机偏好文件推断："
            if !off.isEmpty { detail += "还没开的是 \(off.joined(separator: "、"))；" }
            if !on.isEmpty { detail += "已开好的是 \(on.joined(separator: "、"))。" }
            detail += "刚改完设置的话，Chrome 可能还没写盘，这行会慢一拍。"
            text += "\n（\(detail)）"
        }
        return text
    }

    /// 设置页用：全部配置文件的状态摘要。
    static func statusSummary(bundleID: String) -> [Profile] {
        profiles(bundleID: bundleID)
    }
}
