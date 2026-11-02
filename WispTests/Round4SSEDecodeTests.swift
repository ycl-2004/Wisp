import XCTest
@testable import Wisp

/// Audit round 4, #51: SSELineSplitter decoded each completed line with
/// String(data:encoding:) ?? "" — a single invalid UTF-8 byte anywhere
/// in the line silently dropped the entire line (a hole in the answer,
/// persisted). Decoding is now lossy, matching the DrainBuffer/Capped
/// DataBuffer precedent: a corrupt byte becomes U+FFFD inside the line.
final class Round4SSEDecodeTests: XCTestCase {

    func testInvalidUTF8LineIsDeliveredLossyNotDropped() throws {
        var splitter = SSELineSplitter()
        // "data: {\"x\":\"A" 0xFF "B\"}" + \n — 0xFF is never valid UTF-8.
        var bytes: [UInt8] = Array("data: {\"x\":\"A".utf8)
        bytes.append(0xFF)
        bytes += Array("B\"}".utf8)
        bytes.append(0x0A)
        var line: String?
        for byte in bytes {
            if let completed = try splitter.feed(byte) { line = completed }
        }
        let unwrapped = try XCTUnwrap(line, "the line must be delivered, not dropped")
        XCTAssertTrue(unwrapped.hasPrefix("data:"), unwrapped)
        XCTAssertTrue(unwrapped.contains("\u{FFFD}"), "corrupt byte must surface as U+FFFD: \(unwrapped)")
        XCTAssertTrue(unwrapped.contains("B"), unwrapped)
    }

    func testInvalidUTF8TailIsDeliveredLossyOnFinish() throws {
        var splitter = SSELineSplitter()
        var bytes: [UInt8] = Array("tail-".utf8)
        bytes.append(0xFE)
        for byte in bytes { _ = try splitter.feed(byte) }
        let tail = try XCTUnwrap(splitter.finish())
        XCTAssertTrue(tail.hasPrefix("tail-"), tail)
        XCTAssertTrue(tail.contains("\u{FFFD}"), tail)
    }
}
