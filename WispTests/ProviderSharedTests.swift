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

/// Round-2 audit #28 (found in the coverage pass): the Codex app-server
/// handshake hardcoded its client version ("0.4.0") — the same drift class
/// as #14. It happens to match today; the moment MARKETING_VERSION moves,
/// the app-server would be told a version Wisp no longer is. Pin the
/// payload to the bundle-derived version so a stale literal fails here.
final class CodexClientInfoTests: XCTestCase {

    func testInitializeRequestReportsTheBundleVersion() {
        let params = CodexCLIProvider.AppServerSession.initializeRequest["params"] as? [String: Any]
        let clientInfo = params?["clientInfo"] as? [String: String]
        XCTAssertEqual(clientInfo?["version"], UpdateChecker.currentVersion)
        XCTAssertEqual(clientInfo?["name"], "wisp")
    }
}
