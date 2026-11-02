import XCTest
@testable import WispCore

/// Audit round 4, #39: the debug dump (last-context.json +
/// last-screenshot.jpg at a fixed path) was gated on a single
/// UserDefaults bool in a non-sandboxed app. Any same-user process
/// could `defaults write` it on and turn Wisp — which holds the Screen
/// Recording grant the attacker lacks — into a screenshot oracle.
/// The toggle now also requires an arm file inside the app's private
/// support directory, created only by the in-app setter: a defaults
/// flip alone no longer enables dumping.
final class Round4DebugDumpGateTests: XCTestCase {

    func testDefaultsFlipAloneDoesNotArmTheDump() throws {
        let suite = "wisp-round4-dump-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        // Start from a known disarmed state, then clean up after.
        settings.debugDumpEnabled = false
        defer { settings.debugDumpEnabled = false }

        // The attack: flip the defaults key directly, no app involvement.
        defaults.set(true, forKey: "debugDumpEnabled")
        XCTAssertTrue(defaults.bool(forKey: "debugDumpEnabled"))
        XCTAssertFalse(settings.debugDumpEnabled,
                       "a defaults-only flip must not arm the dump")

        // The legitimate path: the app's own setter arms it.
        settings.debugDumpEnabled = true
        XCTAssertTrue(settings.debugDumpEnabled)

        settings.debugDumpEnabled = false
        XCTAssertFalse(settings.debugDumpEnabled)
    }
}
