import XCTest
@testable import Wisp

/// Round-2 finding #27: the CLI providers' stdout line framing buffered
/// without limit. `CLIJSONLines` (AGY + Codex) accumulated bytes until a
/// newline showed up; Claude's inline NDJSON loop did the same. A CLI that
/// emits one endless line — corrupt output, a binary accidentally treated
/// as text — grows memory until the 300 s watchdog kills the process.
/// These tests pin the framing behaviour that must not change, plus the
/// new 16 MiB single-line cap.
final class CLIJSONLinesTests: XCTestCase {

    func testCompleteLinesInOneChunkParseInOrder() throws {
        var lines = CLIJSONLines()
        let objects = try lines.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects[0]["a"] as? Int, 1)
        XCTAssertEqual(objects[1]["b"] as? Int, 2)
    }

    func testPartialLineIsHeldUntilTheNewlineArrives() throws {
        var lines = CLIJSONLines()
        XCTAssertEqual(try lines.append(Data("{\"a\":".utf8)).count, 0)
        let objects = try lines.append(Data("1}\n".utf8))
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects[0]["a"] as? Int, 1)
    }

    func testEndOfFileFlushesTheTrailingPartialLine() throws {
        var lines = CLIJSONLines()
        let objects = try lines.append(Data("{\"a\":1}".utf8), endOfFile: true)
        XCTAssertEqual(objects.count, 1)
    }

    func testWhitespaceOnlyLinesAreSkipped() throws {
        var lines = CLIJSONLines()
        let objects = try lines.append(Data("  \t\r\n{\"a\":1}\n".utf8))
        XCTAssertEqual(objects.count, 1)
    }

    func testInvalidJSONThrows() {
        var lines = CLIJSONLines()
        XCTAssertThrowsError(try lines.append(Data("not json\n".utf8)))
    }

    func testSingleLinePastTheCapThrows() {
        var lines = CLIJSONLines()
        let oversized = Data(repeating: 0x61, count: CLIJSONLines.maxLineBytes + 1)
        XCTAssertThrowsError(try lines.append(oversized))
    }

    func testResidualLineGrowingPastTheCapAcrossChunksThrows() {
        var lines = CLIJSONLines()
        let chunk = Data(repeating: 0x61, count: 1024 * 1024)
        XCTAssertThrowsError(try {
            // No newline anywhere: the residual must trip the cap.
            for _ in 0...CLIJSONLines.maxLineBytes / chunk.count {
                _ = try lines.append(chunk)
            }
        }())
    }

    func testLineJustUnderTheCapIsAccepted() throws {
        var lines = CLIJSONLines()
        // A valid JSON object whose line is just under the cap parses fine.
        let padding = String(repeating: "x", count: CLIJSONLines.maxLineBytes - 16)
        let objects = try lines.append(Data("{\"t\":\"\(padding)\"}\n".utf8))
        XCTAssertEqual(objects.count, 1)
    }
}
