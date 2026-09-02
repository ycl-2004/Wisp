import AppKit
import Foundation
import ServiceManagement

/// 开机自启。用 macOS 13 起的 SMAppService，不写 LaunchAgent plist。
enum LaunchAtLogin {

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// 用户在「系统设置 → 通用 → 登录项」里把它关掉了，需要引导他去那里重新打开。
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            guard status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static var statusNote: String? {
        switch status {
        case .requiresApproval:
            return String(localized: "系统把它拦下了。去「系统设置 → 通用 → 登录项与扩展」里允许 Wisp。")
        case .notFound:
            return String(localized: "系统找不到这个 App 的登录项。把 Wisp.app 放到「应用程序」或「~/应用程序」里再试。")
        default:
            return nil
        }
    }
}

/// 界面语言。默认跟随系统，也可以在应用内钉死一种。
/// 原理是往本 App 自己的 UserDefaults 域写 `AppleLanguages`，它会盖过系统全局设置。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:            return String(localized: "跟随系统")
        case .english:           return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    /// 不能直接读 AppleLanguages 来判断：没设过的时候读到的是系统那份列表，
    /// 会把「跟随系统」误判成一个具体语言。所以另存一个我们自己的键。
    static var current: AppLanguage {
        AppLanguage(rawValue: AppSettings.shared.appLanguage) ?? .system
    }

    static func apply(_ language: AppLanguage) {
        AppSettings.shared.appLanguage = language.rawValue
        let defaults = UserDefaults.standard
        switch language {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChinese:
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}

/// 改完语言要重开才生效：Bundle 的本地化表在进程启动时就定好了。
@MainActor
enum AppRelaunch {
    static func now() {
        // 先落盘，否则新进程可能读不到刚写的设置。
        UserDefaults.standard.synchronize()
        ConversationStore.shared.flush()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }
}

/// 启动时那次检查的结果，用来在菜单栏里挂一条提示。
@MainActor
final class UpdateNotice: ObservableObject {
    static let shared = UpdateNotice()
    @Published var availableVersion: String?
    private init() {}
}

/// 检查 GitHub 上有没有更新版本。只读一次 releases 接口，不带任何标识信息，
/// 也不自动下载或安装——发现新版本只是给个链接。
enum UpdateChecker {

    static let repositorySlug = "ycl-2004/Wisp"

    static var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(repositorySlug)/releases/latest")!
    }

    static var releasesPage: URL {
        URL(string: "https://github.com/\(repositorySlug)/releases/latest")!
    }

    static var issuesPage: URL {
        URL(string: "https://github.com/\(repositorySlug)/issues/new")!
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    enum Outcome: Equatable {
        case upToDate(current: String)
        case available(latest: String)
        case failed(String)
    }

    private struct ReleasePayload: Decodable {
        var tagName: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    static func check() async -> Outcome {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Wisp/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(String(localized: "没有收到 HTTP 响应。"))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed(String(localized: "GitHub 返回 HTTP \(http.statusCode)。"))
            }
            guard let payload = try? JSONDecoder().decode(ReleasePayload.self, from: data),
                  let tag = payload.tagName, !tag.isEmpty else {
                return .failed(String(localized: "没能从 GitHub 的响应里读出版本号。"))
            }
            AppSettings.shared.lastUpdateCheck = Date()
            return isNewer(tag, than: currentVersion)
                ? .available(latest: normalize(tag))
                : .upToDate(current: currentVersion)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            return .failed(String(localized: "现在连不上网。"))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// "v0.1.0" 与 "0.1.0" 等价；按数字逐段比较，段数不同的短的一方补 0。
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = components(remote), l = components(local)
        for index in 0..<max(r.count, l.count) {
            let a = index < r.count ? r[index] : 0
            let b = index < l.count ? l[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func normalize(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }

    private static func components(_ version: String) -> [Int] {
        normalize(version)
            .split(separator: ".")
            .map { segment in
                Int(segment.prefix { $0.isNumber }) ?? 0
            }
    }
}
