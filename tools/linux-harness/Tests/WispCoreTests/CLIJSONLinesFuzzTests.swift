import XCTest
@testable import WispCore

/// Audit round 4 (test-engineering lane): CLIJSONLines chunking
/// invariance + the exact-cap complete-line case. Round 2 pinned fixed
/// chunkings and a line "just under" the cap (its
/// testLineExactlyAtTheCapIsAccepted actually builds a line 8 bytes
/// UNDER the cap — see the audit list). Nothing verified that arbitrary
/// transport chunkings frame identically, and no test fed a complete,
/// newline-terminated line of exactly maxLineBytes or maxLineBytes + 1.

private func canonical(_ objects: [[String: Any]]) -> [String] {
    objects.map { object in
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

final class CLIJSONLinesFuzzTests: XCTestCase {

    private let payloadText =
        "{\"type\":\"delta\",\"text\":\"héllo 你好\"}\n" +
        "{\"type\":\"delta\",\"text\":\"😀👨‍👩‍👧‍👦\"}\n" +
        "  \t\r\n" +
        "{\"type\":\"result\",\"text\":\"done\"}\n" +
        "{\"type\":\"tail\",\"text\":\"no newline at eof\"}"

    func testRandomChunkingsFrameIdenticallyToOneShot() throws {
        let payload = Data(payloadText.utf8)
        var reference = CLIJSONLines()
        let expected = canonical(try reference.append(payload, endOfFile: true))
        XCTAssertEqual(expected.count, 4) // whitespace-only line skipped

        var rng = SeededRNG(seed: 0xC11_0001)
        let bytes = [UInt8](payload)
        for _ in 0..<50 {
            var lines = CLIJSONLines()
            var got: [[String: Any]] = []
            var start = 0
            while start < bytes.count {
                let end = min(start + 1 + rng.nextInt(64), bytes.count)
                got += try lines.append(Data(bytes[start..<end]),
                                        endOfFile: end == bytes.count)
                start = end
            }
            XCTAssertEqual(canonical(got), expected)
        }
    }

    func testByteByByteFramingMatchesOneShot() throws {
        let payload = Data(payloadText.utf8)
        var lines = CLIJSONLines()
        var got: [[String: Any]] = []
        for index in payload.indices {
            let isLast = payload.index(after: index) == payload.endIndex
            got += try lines.append(payload[index...index], endOfFile: isLast)
        }
        var reference = CLIJSONLines()
        XCTAssertEqual(canonical(got),
                       canonical(try reference.append(payload, endOfFile: true)))
    }

    func testEmptyChunksAreNoOps() throws {
        var lines = CLIJSONLines()
        XCTAssertEqual(try lines.append(Data()).count, 0)
        XCTAssertEqual(try lines.append(Data(), endOfFile: true).count, 0)
        XCTAssertEqual(try lines.append(Data("{\"a\":1}\n".utf8)).count, 1)
    }

    func testWhitespaceOnlyTailAtEOFIsSkipped() throws {
        var lines = CLIJSONLines()
        XCTAssertEqual(try lines.append(Data("  \t\r".utf8), endOfFile: true).count, 0)
    }

    func testCRLFTerminatedLineParses() throws {
        var lines = CLIJSONLines()
        let objects = try lines.append(Data("{\"a\":1}\r\n".utf8))
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects[0]["a"] as? Int, 1)
    }

    /// The exact-cap matrix for COMPLETE (newline-terminated) lines —
    /// the `lines.allSatisfy` half of the cap check, which no round-2
    /// test reached (its "exactly at cap" case was 8 bytes under, and
    /// its past-cap case went through the residual path, no newline).
    func testCompleteLineExactlyAtCapParsesAndCapPlusOneThrows() throws {
        let cap = CLIJSONLines.maxLineBytes
        // {"t":"…"} framing overhead is 8 bytes: 6 + 2.
        let atCap = "{\"t\":\"" + String(repeating: "x", count: cap - 8) + "\"}"
        XCTAssertEqual([UInt8](atCap.utf8).count, cap)
        var lines = CLIJSONLines()
        XCTAssertEqual(try lines.append(Data((atCap + "\n").utf8)).count, 1)

        let overCap = "{\"t\":\"" + String(repeating: "x", count: cap - 7) + "\"}"
        XCTAssertEqual([UInt8](overCap.utf8).count, cap + 1)
        var lines2 = CLIJSONLines()
        XCTAssertThrowsError(try lines2.append(Data((overCap + "\n").utf8))) { error in
            guard let providerError = error as? ProviderError,
                  case .network(let message) = providerError else {
                return XCTFail("expected ProviderError.network, got \(error)")
            }
            XCTAssertEqual(message, "Oversized CLI JSON event")
        }
    }

    /// An oversized line does not poison the framing of earlier complete
    /// lines in the same chunk ordering: lines before it in an earlier
    /// chunk were already returned. (Same-chunk behaviour: append is
    /// atomic — it throws before returning anything. Documented here so
    /// a future refactor can't change it silently.)
    func testOversizedLineInSameChunkThrowsAtomically() throws {
        var lines = CLIJSONLines()
        let chunk = Data("{\"a\":1}\n".utf8)
            + Data(repeating: 0x61, count: CLIJSONLines.maxLineBytes + 1)
        XCTAssertThrowsError(try lines.append(chunk))
    }
}
