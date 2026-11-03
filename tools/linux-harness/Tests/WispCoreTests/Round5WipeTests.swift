import XCTest
@testable import WispCore

/// #5 (round 5): 「删除全部数据」must be a true factory reset for
/// AppSettings — every key it owns returns to its first-launch state.
/// The key list below is an independent enumeration of the persisted
/// contract: if `K.all` (the wipe's own list) ever misses a key, the
/// sentinel planted here survives and this test fails.
final class AppSettingsWipeTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        suiteName = "wisp-wipe-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        super.tearDown()
    }

    /// All 42 AppSettings keys by their persisted string names.
    private let allKeys = [
        "providerKind", "baseURL", "cloudProvider", "cloudModels",
        "ollamaBaseURL", "ollamaModel", "codexPath", "codexModel",
        "cliProvider", "agyPath", "agyModel", "claudeCodePath",
        "claudeCodeModel", "model", "excludedBundleIDs", "pageTextLimit",
        "captureMode", "captureScope", "screenHiddenBundleIDs",
        "maxConversations", "maxUserTurns", "sendScreenshot",
        "shortcutTrigger", "advancedShortcut", "lastActiveConversationID",
        "panelFrame", "notesText", "notesPanelFrame", "debugDumpEnabled",
        "showIsland", "showsMenuBarIcon", "hideFromScreenCapture",
        "localCursorEnabled", "islandPosition", "idleDismissSeconds",
        "panelBackgroundOpacity", "panelOpaqueWhenActive",
        "checkForUpdates", "lastUpdateCheck", "islandOrigin",
        "islandAnchor", "appLanguage", "listeningEnabled",
        "hasShownFirstRunOnboarding",
    ]

    func testWipeRemovesEveryAppSettingsKey() {
        for key in allKeys { defaults.set("wisp-sentinel", forKey: key) }
        settings.wipeLocalData()
        for key in allKeys {
            XCTAssertNotEqual(defaults.object(forKey: key) as? String, "wisp-sentinel",
                              "\(key) survived the wipe")
        }
    }

    func testWipeRestoresFirstLaunchValues() {
        settings.baseURL = "https://example.invalid/v1"
        settings.model = "some-custom-model"
        defaults.set(123_456, forKey: "pageTextLimit")
        defaults.set(Date(), forKey: "lastUpdateCheck")

        settings.wipeLocalData()

        // Registered defaults re-apply, exactly as on first launch.
        XCTAssertEqual(settings.baseURL, CloudProvider.openRouter.baseURL)
        XCTAssertEqual(settings.model, CloudProvider.openRouter.defaultModel)
        XCTAssertEqual(settings.pageTextLimit, 60_000)
        XCTAssertEqual(settings.excludedBundleIDs, [
            "com.1password.1password",
            "com.apple.keychainaccess",
            "com.agilebits.onepassword7",
        ])
        // Unregistered keys are simply absent again.
        XCTAssertNil(settings.lastUpdateCheck)
        XCTAssertNil(defaults.object(forKey: "cloudModels"))
    }

    func testWipeLeavesOtherDefaultsAlone() {
        // The wipe is scoped to AppSettings' own keys: library- and
        // UI-owned entries in the same domain are not its business.
        defaults.set(true, forKey: "KeyboardShortcuts_toggleAssistant")
        defaults.set("data", forKey: "settingsTab")
        settings.wipeLocalData()
        XCTAssertEqual(defaults.bool(forKey: "KeyboardShortcuts_toggleAssistant"), true)
        XCTAssertEqual(defaults.string(forKey: "settingsTab"), "data")
    }

    func testWipeRemovesSupportDirectoryContents() throws {
        let dir = AppSettings.supportDirectory
        try AppSettings.ensurePrivateDirectory(dir)
        let marker = dir.appendingPathComponent("wisp-wipe-marker.txt")
        try Data("x".utf8).write(to: marker)
        settings.wipeLocalData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
