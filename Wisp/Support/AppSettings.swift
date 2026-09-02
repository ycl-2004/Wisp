import Foundation

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
        static let maxConversations = "maxConversations"
        static let maxUserTurns = "maxUserTurns"
        static let sendScreenshot = "sendScreenshot"
        static let lastActiveConversationID = "lastActiveConversationID"
        static let panelFrame = "panelFrame"
        static let debugDumpEnabled = "debugDumpEnabled"
        static let showIsland = "showIsland"
        static let islandPosition = "islandPosition"
        static let idleDismissSeconds = "idleDismissSeconds"
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
            K.maxConversations: 10,
            K.maxUserTurns: 30,
            K.sendScreenshot: true,
            K.debugDumpEnabled: false,
            K.showIsland: true,
            K.islandPosition: "bottom",
            K.idleDismissSeconds: 10.0,
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
        for key in [K.lastActiveConversationID, K.panelFrame] {
            d.removeObject(forKey: key)
        }
        objectWillChange.send()
    }
}
