import XCTest
@testable import Wisp

/// Round-2 audit #11: CLI stderr must not accumulate without limit.
/// A CLI stuck in an error loop can spew stderr for the whole 300 s watchdog
/// window; only the tail is ever read (each provider's `condense` shows the
/// last lines), so the shared DrainBuffer keeps just the last 256 KiB.
final class DrainBufferTests: XCTestCase {

    func testUnderCapKeepsEverything() {
        let buffer = DrainBuffer()
        buffer.append(Data("line one\n".utf8))
        buffer.append(Data("line two\n".utf8))
        XCTAssertEqual(buffer.text, "line one\nline two\n")
    }

    func testEmptyBufferHasEmptyText() {
        XCTAssertEqual(DrainBuffer().text, "")
    }

    func testOverCapKeepsTheTail() {
        let buffer = DrainBuffer()
        let head = String(repeating: "h", count: DrainBuffer.maxBytes)
        buffer.append(Data(head.utf8))
        buffer.append(Data("TAIL".utf8))
        // The head is pushed out; exactly maxBytes remain, ending with the tail.
        XCTAssertEqual(buffer.text,
                       String(repeating: "h", count: DrainBuffer.maxBytes - 4) + "TAIL")
    }

    func testManySmallAppendsStillRespectTheCap() {
        let buffer = DrainBuffer()
        let chunk = Data(String(repeating: "x", count: 1024).utf8)
        for _ in 0..<(DrainBuffer.maxBytes / 1024 + 10) {
            buffer.append(chunk)
        }
        XCTAssertEqual(buffer.text.count, DrainBuffer.maxBytes)
    }

    /// The trim point can land inside a multi-byte scalar. The leftover
    /// continuation bytes must be skipped, or `text` fails UTF-8 decoding
    /// wholesale and every error message silently becomes "".
    func testTrimLandingMidScalarStillYieldsValidText() {
        let buffer = DrainBuffer()
        // "你好" is 6 bytes (3 + 3). Fill so the cap trims 4 bytes from the
        // head: all of 你 plus the first byte of 好， leaving 好's two
        // continuation bytes at the front.
        buffer.append(Data("你好".utf8))
        let filler = String(repeating: "a", count: DrainBuffer.maxBytes - 2)
        buffer.append(Data(filler.utf8))
        XCTAssertEqual(buffer.text, filler)
    }

    func testCapIs256KiB() {
        XCTAssertEqual(DrainBuffer.maxBytes, 256 * 1024)
    }
}
