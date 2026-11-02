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
