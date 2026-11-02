import XCTest
@testable import Wisp

/// Round-2 audit #13: the three CLI providers must share one wall-clock
/// timeout. Codex used to stop at 240 s while Claude and AGY got 300 s,
/// for no documented reason — a slow-but-working Codex call died a minute
/// early and the user had no way to tell why this one provider timed out
/// first.
final class CLIWallClockTests: XCTestCase {

    func testSharedWallClockIs300Seconds() {
        XCTAssertEqual(CLIWallClock.timeout, 300)
    }

    func testEveryCLIProviderUsesTheSharedWallClock() {
        XCTAssertEqual(ClaudeCodeCLIProvider.wallClockTimeout, CLIWallClock.timeout)
        XCTAssertEqual(AgyCLIProvider.wallClockTimeout, CLIWallClock.timeout)
        XCTAssertEqual(CodexCLIProvider.wallClockTimeout, CLIWallClock.timeout)
    }
}

/// Round-2 audit #14: cloud requests identified the app as "Wisp/0.1", a
/// version that never shipped (the app is 0.4.x). The User-Agent must be
/// derived from the bundle version, the same way the update checker does,
/// so it can never go stale again.
final class UserAgentTests: XCTestCase {

    func testUserAgentIsDerivedFromTheBundleVersion() {
        XCTAssertEqual(UpdateChecker.userAgent, "Wisp/\(UpdateChecker.currentVersion)")
    }

    func testUserAgentIsNotTheStaleHardcodedVersion() {
        XCTAssertNotEqual(UpdateChecker.userAgent, "Wisp/0.1")
        XCTAssertFalse(UpdateChecker.currentVersion.isEmpty)
    }
}
