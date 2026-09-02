import Foundation

/// 一次采集能动用到什么程度。越往下拿到的正文越全，代价也越大。
enum CaptureMode: String, CaseIterable, Identifiable {
    /// 只截图 + 网址标题。不注入 JS，最快，什么都不碰。
    case screenshotOnly
    /// 额外注入 JS 读整页正文。普通网页足够，虚拟滚动页面只能拿到一屏。
    case pageText
    /// 在上一档基础上，用真实滚轮事件把虚拟滚动页面滚一遍再采。
    /// 需要辅助功能权限，采集时会短暂借用鼠标指针。
    case scrollCollect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshotOnly: return String(localized: "纯截图")
        case .pageText: return String(localized: "读取页面正文")
        case .scrollCollect: return String(localized: "允许滑动采集")
        }
    }

    var detail: String {
        switch self {
        case .screenshotOnly:
            return String(localized: "只发送当前窗口截图和网址，不注入任何脚本。最快，也最不打扰。")
        case .pageText:
            return String(localized: "额外读取整页文字。普通网页能拿全；飞书文档、Notion 这类按需渲染的页面只能读到屏幕上的那一屏。")
        case .scrollCollect:
            return String(localized: "遇到按需渲染的页面时，用真实滚轮事件把页面滚一遍并累积正文，读完滚回原位。需要「辅助功能」权限，采集期间会短暂借用鼠标指针（结束后放回原处）。")
        }
    }

    /// 要不要注入 JS 读正文。
    var readsPageText: Bool { self != .screenshotOnly }
}

/// UserDefaults 包装。不存 API Key（Key 在 Keychain）。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    private enum K {
        static let providerKind = "providerKind"
        static let baseURL = "baseURL"
        static let ollamaBaseURL = "ollamaBaseURL"
        static let ollamaModel = "ollamaModel"
        static let codexPath = "codexPath"
        static let codexModel = "codexModel"
        static let model = "model"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let pageTextLimit = "pageTextLimit"
        static let captureMode = "captureMode"
        static let maxConversations = "maxConversations"
        static let maxUserTurns = "maxUserTurns"
        static let sendScreenshot = "sendScreenshot"
        static let lastActiveConversationID = "lastActiveConversationID"
        static let panelFrame = "panelFrame"
        static let debugDumpEnabled = "debugDumpEnabled"
        static let showIsland = "showIsland"
        static let islandPosition = "islandPosition"
        static let idleDismissSeconds = "idleDismissSeconds"
        static let checkForUpdates = "checkForUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let islandOrigin = "islandOrigin"   // 0.2.0 开发期的旧键，只用于迁移
        static let islandAnchor = "islandAnchor"
        static let appLanguage = "appLanguage"
    }

    private init() {
        d.register(defaults: [
            K.providerKind: ProviderKind.openAICompatible.rawValue,
            K.baseURL: "https://api.openai.com/v1",
            K.ollamaBaseURL: OllamaSupport.defaultBaseURL,
            K.ollamaModel: "",
            K.codexPath: "",
            K.codexModel: "",
            K.model: "gpt-4o-mini",
            K.excludedBundleIDs: [
                "com.1password.1password",
                "com.apple.keychainaccess",
                "com.agilebits.onepassword7",
            ],
            K.pageTextLimit: 60_000,
            K.captureMode: CaptureMode.pageText.rawValue,
            K.maxConversations: 10,
            K.maxUserTurns: 30,
            K.sendScreenshot: true,
            K.debugDumpEnabled: false,
            K.showIsland: true,
            K.islandPosition: "bottom",
            K.idleDismissSeconds: 10.0,
            K.checkForUpdates: true,
            K.appLanguage: "system",
        ])
    }

    var providerKind: String {
        get { d.string(forKey: K.providerKind) ?? ProviderKind.openAICompatible.rawValue }
        set { d.set(newValue, forKey: K.providerKind); objectWillChange.send() }
    }

    var ollamaBaseURL: String {
        get { d.string(forKey: K.ollamaBaseURL) ?? OllamaSupport.defaultBaseURL }
        set { d.set(newValue, forKey: K.ollamaBaseURL); objectWillChange.send() }
    }

    var ollamaModel: String {
        get { d.string(forKey: K.ollamaModel) ?? "" }
        set { d.set(newValue, forKey: K.ollamaModel); objectWillChange.send() }
    }

    var codexPath: String {
        get { d.string(forKey: K.codexPath) ?? "" }
        set { d.set(newValue, forKey: K.codexPath); objectWillChange.send() }
    }

    var codexModel: String {
        get { d.string(forKey: K.codexModel) ?? "" }
        set { d.set(newValue, forKey: K.codexModel); objectWillChange.send() }
    }

    var baseURL: String {
        get { d.string(forKey: K.baseURL) ?? "https://api.openai.com/v1" }
        set { d.set(newValue, forKey: K.baseURL); objectWillChange.send() }
    }

    var model: String {
        get { d.string(forKey: K.model) ?? "gpt-4o-mini" }
        set { d.set(newValue, forKey: K.model); objectWillChange.send() }
    }

    var excludedBundleIDs: [String] {
        get { d.stringArray(forKey: K.excludedBundleIDs) ?? [] }
        set { d.set(newValue, forKey: K.excludedBundleIDs); objectWillChange.send() }
    }

    var pageTextLimit: Int {
        get { max(2_000, d.integer(forKey: K.pageTextLimit)) }
        set { d.set(newValue, forKey: K.pageTextLimit); objectWillChange.send() }
    }

    /// 一次采集能动用到什么程度。默认 `.pageText`：读正文但不碰用户的鼠标。
    /// `.scrollCollect` 会注入真实滚轮事件，属于要用户明确同意的行为，不默认开。
    var captureMode: CaptureMode {
        get { CaptureMode(rawValue: d.string(forKey: K.captureMode) ?? "") ?? .pageText }
        set { d.set(newValue.rawValue, forKey: K.captureMode); objectWillChange.send() }
    }

    var maxConversations: Int {
        get { max(1, d.integer(forKey: K.maxConversations)) }
        set { d.set(newValue, forKey: K.maxConversations); objectWillChange.send() }
    }

    var maxUserTurns: Int {
        get { max(1, d.integer(forKey: K.maxUserTurns)) }
        set { d.set(newValue, forKey: K.maxUserTurns); objectWillChange.send() }
    }

    var sendScreenshot: Bool {
        get { d.bool(forKey: K.sendScreenshot) }
        set { d.set(newValue, forKey: K.sendScreenshot); objectWillChange.send() }
    }

    var debugDumpEnabled: Bool {
        get { d.bool(forKey: K.debugDumpEnabled) }
        set { d.set(newValue, forKey: K.debugDumpEnabled); objectWillChange.send() }
    }

    var showIsland: Bool {
        get { d.bool(forKey: K.showIsland) }
        set { d.set(newValue, forKey: K.showIsland); objectWillChange.send() }
    }

    var islandPosition: String {
        get { d.string(forKey: K.islandPosition) ?? "bottom" }
        set { d.set(newValue, forKey: K.islandPosition); objectWillChange.send() }
    }

    /// 面板失去焦点后自动收起前等待的秒数。0 表示不自动收起。
    var idleDismissSeconds: Double {
        get { max(0, d.double(forKey: K.idleDismissSeconds)) }
        set { d.set(max(0, newValue), forKey: K.idleDismissSeconds); objectWillChange.send() }
    }

    /// 启动时去 GitHub 看一眼有没有新版本。只发一个不带标识的请求，不自动下载。
    var checkForUpdates: Bool {
        get { d.bool(forKey: K.checkForUpdates) }
        set { d.set(newValue, forKey: K.checkForUpdates); objectWillChange.send() }
    }

    var lastUpdateCheck: Date? {
        get { d.object(forKey: K.lastUpdateCheck) as? Date }
        set { d.set(newValue, forKey: K.lastUpdateCheck) }
    }

    /// 用户把药丸拖到的位置，存的是**那颗小圆的中心**（屏幕坐标），不是窗口原点。
    /// 窗口比小圆大得多（要给展开态留地方），拿窗口原点当锚点会让小圆永远靠不到屏幕边。
    /// nil 表示还没拖过，用默认的底部居中。只对底部形态有意义。
    var islandAnchor: CGPoint? {
        get {
            guard let raw = d.string(forKey: K.islandAnchor), !raw.isEmpty else { return nil }
            return NSPointFromString(raw)
        }
        set {
            if let newValue {
                d.set(NSStringFromPoint(newValue), forKey: K.islandAnchor)
            } else {
                d.removeObject(forKey: K.islandAnchor)
            }
            objectWillChange.send()
        }
    }

    var hasCustomIslandAnchor: Bool { islandAnchor != nil }

    /// 旧键读写，只给迁移用。
    var legacyIslandOrigin: CGPoint? {
        get {
            guard let raw = d.string(forKey: K.islandOrigin), !raw.isEmpty else { return nil }
            return NSPointFromString(raw)
        }
        set {
            if newValue == nil { d.removeObject(forKey: K.islandOrigin) }
        }
    }

    /// 界面语言的选择本身（"system" / "en" / "zh-Hans"）。
    /// 真正生效靠 AppLanguage.apply 写的 AppleLanguages，这里只记住用户选了什么。
    var appLanguage: String {
        get { d.string(forKey: K.appLanguage) ?? "system" }
        set { d.set(newValue, forKey: K.appLanguage); objectWillChange.send() }
    }

    var lastActiveConversationID: String? {
        get { d.string(forKey: K.lastActiveConversationID) }
        set { d.set(newValue, forKey: K.lastActiveConversationID) }
    }

    var panelFrame: String? {
        get { d.string(forKey: K.panelFrame) }
        set { d.set(newValue, forKey: K.panelFrame) }
    }

    func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }

    /// 应用支持目录：~/Library/Application Support/Wisp
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Wisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 清空全部本地数据（对话 JSON、调试文件、UserDefaults）。Keychain 由调用方另行清除。
    func wipeLocalData() {
        let dir = AppSettings.supportDirectory
        try? FileManager.default.removeItem(at: dir)
        for key in [K.lastActiveConversationID, K.panelFrame, K.islandOrigin, K.islandAnchor] {
            d.removeObject(forKey: key)
        }
        objectWillChange.send()
    }
}
