import XCTest
@testable import WispCore

/// Audit round 4, #44: the numeric settings had floors but no ceilings,
/// and pageTextLimit is set from a free-form number field — raising it
/// defeated the app's only page-text cut point. Getters now clamp to a
/// ceiling as well (same pattern as the existing opacity clamps), which
/// also covers values written outside the UI.
final class Round4SettingsClampTests: XCTestCase {

    private func withSettings(_ body: (AppSettings) throws -> Void) throws {
        let suite = "wisp-round4-clamp-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppSettings(defaults: defaults))
    }

    func testPageTextLimitIsCapped() throws {
        try withSettings { settings in
            settings.pageTextLimit = 100_000_000
            XCTAssertEqual(settings.pageTextLimit, 500_000)
            settings.pageTextLimit = 1
            XCTAssertEqual(settings.pageTextLimit, 2_000, "the existing floor still applies")
            settings.pageTextLimit = 60_000
            XCTAssertEqual(settings.pageTextLimit, 60_000, "in-range values pass through")
        }
    }

    func testMaxConversationsIsCapped() throws {
        try withSettings { settings in
            settings.maxConversations = 1_000_000
            XCTAssertEqual(settings.maxConversations, 50)
            settings.maxConversations = 0
            XCTAssertEqual(settings.maxConversations, 1)
        }
    }

    func testMaxUserTurnsIsCapped() throws {
        try withSettings { settings in
            settings.maxUserTurns = 1_000_000
            XCTAssertEqual(settings.maxUserTurns, 200)
            settings.maxUserTurns = 0
            XCTAssertEqual(settings.maxUserTurns, 1)
        }
    }
}
