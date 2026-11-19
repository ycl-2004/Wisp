import XCTest
@testable import Wisp

/// #5 (round 5): 「删除全部数据」must be a true factory reset for
/// AppSettings — every key it owns returns to its first-launch state.
/// The key list below is an independent enumeration of the persisted
/// contract: if `K.all` (the wipe's own list) ever misses a key, the
/// sentinel planted here survives and this test fails.
final class AppSettingsWipeTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var fixtureDirectory: URL!

    override func setUpWithError() throws {
        suiteName = "wisp-wipe-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(defaults: defaults)
        fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try AppSettings.ensurePrivateDirectory(fixtureDirectory)
    }

    override func tearDown() {
        if let fixtureDirectory { try? FileManager.default.removeItem(at: fixtureDirectory) }
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        super.tearDown()
    }

    /// Every persisted key the app owns, by its string name — including the
    /// ones other types read and write (listening preferences, quick
    /// commands, the scan flag, the language pin, the settings tab), which
    /// the first version of this wipe missed.
    private let allKeys = [
        "providerKind", "baseURL", "cloudProvider", "cloudModels",
        "ollamaBaseURL", "ollamaModel", "codexPath", "codexModel",
        "cliProvider", "agyPath", "agyModel", "claudeCodePath",
        "claudeCodeModel", "model", "excludedBundleIDs", "pageTextLimit",
        "captureMode", "captureScope", "screenHiddenBundleIDs",
        "maxConversations", "maxUserTurns", "sendScreenshot",
        "shortcutTrigger", "advancedShortcut", "lastActiveConversationID",
        "panelFrame", "debugDumpEnabled",
        "showIsland", "showsMenuBarIcon", "hideFromScreenCapture",
        "islandPosition", "idleDismissSeconds",
        "panelBackgroundOpacity", "panelOpaqueWhenActive",
        "checkForUpdates", "lastUpdateCheck", "islandOrigin",
        "islandAnchor", "appLanguage", "listeningEnabled",
        "responseMode", "responseModels", "settingsTab",
        "listeningPreferences", "quickCommands", "captionCommandsSeeded",
        "AppleLanguages",
        // Left behind by removed features (recording notes, cursor lock, local speech models).
        "notesText", "notesPanelFrame", "localCursorEnabled", "localSpeechScanRequested",
    ]

    func testKeysOwnedByOtherTypesAreTheRegisteredOnes() {
        XCTAssertEqual(ListeningPreferences.key, "listeningPreferences")
        XCTAssertEqual(AppSettings.quickCommandsKey, "quickCommands")
        XCTAssertEqual(AppSettings.appleLanguagesKey, "AppleLanguages")
        XCTAssertEqual(AppSettings.settingsTabKey, "settingsTab")
    }

    func testWipeRemovesEveryAppSettingsKey() throws {
        for key in allKeys { defaults.set("wisp-sentinel", forKey: key) }
        try settings.wipeLocalData(in: fixtureDirectory)
        for key in allKeys {
            XCTAssertNotEqual(defaults.object(forKey: key) as? String, "wisp-sentinel",
                              "\(key) survived the wipe")
        }
    }

    func testWipeRestoresFirstLaunchValues() throws {
        settings.baseURL = "https://example.invalid/v1"
        settings.model = "some-custom-model"
        defaults.set(123_456, forKey: "pageTextLimit")
        defaults.set(Date(), forKey: "lastUpdateCheck")

        try settings.wipeLocalData(in: fixtureDirectory)

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

    func testWipeLeavesOtherDefaultsAlone() throws {
        // The wipe removes only registered keys. Library-owned entries in the
        // same domain are reset through their own API by the Settings flow
        // (KeyboardShortcuts.reset), and anything unregistered is left alone.
        // ("settingsTab" used to be the UI-owned example here; it is now
        // registered, so the full reset also reopens Settings on its first tab.)
        defaults.set(true, forKey: "KeyboardShortcuts_toggleAssistant")
        defaults.set("data", forKey: "SomeOtherComponent_state")
        try settings.wipeLocalData(in: fixtureDirectory)
        XCTAssertEqual(defaults.bool(forKey: "KeyboardShortcuts_toggleAssistant"), true)
        XCTAssertEqual(defaults.string(forKey: "SomeOtherComponent_state"), "data")
    }

    func testWipeRemovesSupportDirectoryContents() throws {
        let support = fixtureDirectory.appendingPathComponent("Wisp", isDirectory: true)
        let listening = support.appendingPathComponent("Listening", isDirectory: true)
        try AppSettings.ensurePrivateDirectory(listening)
        let sibling = fixtureDirectory.appendingPathComponent("other-app-data.txt")
        let fixture = Data("fixture".utf8)
        try fixture.write(to: support.appendingPathComponent("conversations.json"))
        try fixture.write(to: listening.appendingPathComponent("transcript.txt"))
        try fixture.write(to: sibling)

        try settings.wipeLocalData(in: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertEqual(try Data(contentsOf: sibling), fixture)
        XCTAssertNoThrow(try settings.wipeLocalData(in: support))
    }

    func testFailedFileRemovalLeavesSettingsAvailableForRetry() {
        // An overlong component reliably fails on both APFS and Linux, even as root.
        let invalidPath = fixtureDirectory.appendingPathComponent(String(repeating: "x", count: 512))
        settings.model = "fixture-model"
        XCTAssertThrowsError(try settings.wipeLocalData(in: invalidPath))
        XCTAssertEqual(settings.model, "fixture-model")
    }
}
