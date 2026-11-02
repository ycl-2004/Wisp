import XCTest
@testable import Wisp

/// Audit round 4 (test-engineering lane): property/fuzz coverage for the
/// cloud streaming seams. Round 2 pinned happy paths and the two caps at
/// fixed examples; nothing verified that *where the transport splits the
/// byte stream* cannot change the parse, and `SSEParser.parse` /
/// `SSEParser.errorMessage` had no direct tests at all (only indirect
/// exercise through the provider's URLProtocol test).
///
/// Invariant under test: for any byte stream and any split of it into
/// feed() calls — including splits inside a multi-byte UTF-8 scalar and
/// inside the `data:` prefix — the line sequence, and therefore the
/// parsed event sequence, equals the unsplit parse; or a cap error is
/// thrown. Never a crash, never a silently different result.

private func describe(_ event: SSEParser.Event) -> String {
    switch event {
    case .delta(let text): return "delta:" + text
    case .done: return "done"
    case .ignored: return "ignored"
    }
}

/// Runs the provider's exact pipeline shape (splitter → lines → parse,
/// with the finish() tail flush) over `bytes` fed in `chunks`.
private func runPipeline(_ bytes: [UInt8], chunks: [[UInt8]]) throws -> [String] {
    var splitter = SSELineSplitter()
    var events: [String] = []
    for chunk in chunks {
        for byte in chunk {
            if let line = try splitter.feed(byte) {
                events.append(describe(SSEParser.parse(line: line)))
            }
        }
    }
    if let tail = splitter.finish() {
        events.append(describe(SSEParser.parse(line: tail)))
    }
    return events
}

final class SSESplitInvarianceTests: XCTestCase {

    /// A representative stream: CJK + emoji deltas (multi-byte scalars that
    /// random splits will cut), an array-form delta, an in-stream error,
    /// a comment line, a CRLF line, [DONE], and an unterminated tail.
    private let streamText =
        "data: {\"choices\":[{\"delta\":{\"content\":\"héllo\"}}]}\n" +
        "\n" +
        "data: {\"choices\":[{\"delta\":{\"content\":\" 你好😀界\"}}]}\r\n" +
        ": keep-alive\n" +
        "data: {\"choices\":[{\"delta\":{\"content\":[{\"text\":\"ab\"},{\"text\":\"cd\"}]}}]}\n" +
        "data: {\"error\":{\"message\":\"boom\"}}\n" +
        "event: ping\n" +
        "data: [DONE]\n" +
        "data: {\"choices\":[{\"delta\":{\"content\":\"tail\"}}]}"

    func testRandomSplitsNeverChangeTheEventSequence() throws {
        let bytes = [UInt8](streamText.utf8)
        let whole = try runPipeline(bytes, chunks: [bytes])
        // The unsplit baseline itself is pinned, so "equal to itself"
        // cannot hide a broken parse.
        XCTAssertEqual(whole, [
            "delta:héllo",
            "ignored",
            "delta: 你好😀界",
            "ignored",
            "delta:abcd",
            "delta:\n\n[服务端错误] boom",
            "ignored",
            "done",
            "delta:tail",
        ])

        var rng = SeededRNG(seed: 0x55E5_0001)
        for _ in 0..<60 {
            // Random chunking: 1...12 cut points at random offsets.
            var cuts = Set<Int>()
            for _ in 0..<(1 + rng.nextInt(12)) { cuts.insert(rng.nextInt(bytes.count + 1)) }
            var chunks: [[UInt8]] = []
            var start = 0
            for cut in cuts.sorted() {
                chunks.append(Array(bytes[start..<cut]))
                start = cut
            }
            chunks.append(Array(bytes[start...]))
            XCTAssertEqual(try runPipeline(bytes, chunks: chunks), whole)
        }
    }

    func testByteByByteEqualsWholeFeedForGarbageStreams() throws {
        var rng = SeededRNG(seed: 0x55E5_0002)
        for _ in 0..<40 {
            let bytes = rng.nextBytes(count: rng.nextInt(in: 0...300))
            // Garbage can contain 0x0A anywhere, but no line here can
            // approach the 1 MiB cap, so neither run may throw.
            let whole = try runPipeline(bytes, chunks: [bytes])
            let bytewise = try runPipeline(bytes, chunks: bytes.map { [$0] })
            XCTAssertEqual(bytewise, whole)
        }
    }

    func testLineSequenceIsSplitInvariantIncludingFinishTail() throws {
        func lines(for chunks: [[UInt8]]) throws -> [String] {
            var splitter = SSELineSplitter()
            var out: [String] = []
            for chunk in chunks {
                for byte in chunk {
                    if let line = try splitter.feed(byte) { out.append(line) }
                }
            }
            if let tail = splitter.finish() { out.append(tail) }
            return out
        }
        let text = "data: a\rb\nsecond\r\nthird\n\npartial-你好"
        let bytes = [UInt8](text.utf8)
        let whole = try lines(for: [bytes])
        XCTAssertEqual(whole, ["data: a\rb", "second", "third", "", "partial-你好"])
        var rng = SeededRNG(seed: 0x55E5_0003)
        for _ in 0..<40 {
            let cut = rng.nextInt(bytes.count + 1)
            let split = try lines(for: [Array(bytes[..<cut]), Array(bytes[cut...])])
            XCTAssertEqual(split, whole)
        }
    }
}

final class SSELineSplitterBoundaryTests: XCTestCase {

    private func feedString(_ splitter: inout SSELineSplitter, _ text: String) throws -> [String] {
        var lines: [String] = []
        for byte in Data(text.utf8) {
            if let line = try splitter.feed(byte) { lines.append(line) }
        }
        return lines
    }

    /// Cap matrix with a 3-byte scalar straddling the boundary. Feed is
    /// byte-by-byte, so every case also splits the scalar across feeds.
    func testCapMinusCapAndCapPlusOneWithMultibyteTail() throws {
        let cap = SSELineSplitter.maxLineBytes

        // cap - 1 bytes total ("你" = 3 bytes at the tail): accepted.
        var s1 = SSELineSplitter()
        let under = String(repeating: "x", count: cap - 4) + "你"
        XCTAssertEqual([UInt8](under.utf8).count, cap - 1)
        XCTAssertEqual(try feedString(&s1, under + "\n"), [under])

        // Exactly cap bytes: accepted (the cap trips on count > cap,
        // and the newline arrives before any byte past the cap).
        var s2 = SSELineSplitter()
        let exact = String(repeating: "x", count: cap - 3) + "你"
        XCTAssertEqual([UInt8](exact.utf8).count, cap)
        XCTAssertEqual(try feedString(&s2, exact + "\n"), [exact])

        // cap + 1 bytes: the scalar's last byte crosses the cap → throws.
        var s3 = SSELineSplitter()
        let over = String(repeating: "x", count: cap - 2) + "你"
        XCTAssertEqual([UInt8](over.utf8).count, cap + 1)
        XCTAssertThrowsError(try feedString(&s3, over)) { error in
            XCTAssertEqual(error as? SSELineSplitter.Failure, .lineTooLong(limit: cap))
        }
    }

    /// Since audit #51 the splitter decodes lossily: a line with invalid
    /// UTF-8 is delivered with U+FFFD in place of the bad bytes instead of
    /// being silently emptied (the old `?? ""` behaviour this test used to
    /// document). The parser still ignores the line — its payload is not
    /// JSON — so the stream survives, and a corrupt byte inside real
    /// answer text now costs one character, not the whole delta.
    func testInvalidUTF8LineDecodesAsEmptyAndStreamContinues() throws {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        let bytes: [UInt8] = [0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xFF, 0xFE, 0x0A]
            + [UInt8]("data: [DONE]\n".utf8)
        for byte in bytes {
            if let line = try splitter.feed(byte) { lines.append(line) }
        }
        XCTAssertEqual(lines, ["data: \u{FFFD}\u{FFFD}", "data: [DONE]"])
    }

    func testLoneCarriageReturnIsContentNotADelimiter() throws {
        var splitter = SSELineSplitter()
        // Round-2 accepted delta vs AsyncBytes.lines: only \n delimits.
        XCTAssertEqual(try feedString(&splitter, "a\rb\n"), ["a\rb"])
        XCTAssertEqual(try feedString(&splitter, "only-cr\r"), [])
        XCTAssertEqual(splitter.finish(), "only-cr")
    }

    func testFinishStripsOneTrailingCRButNotTwo() throws {
        var splitter = SSELineSplitter()
        _ = try feedString(&splitter, "abc\r\r")
        XCTAssertEqual(splitter.finish(), "abc\r")
    }
}

final class CappedDataBufferBoundaryTests: XCTestCase {

    func testByteMatrixAcrossLimits() {
        let payload = [UInt8]("abcdefghij".utf8)
        for limit in [0, 1, 2, 5, 9, 10, 11] {
            var buffer = CappedDataBuffer(limit: limit)
            var acceptedAll = true
            for byte in payload { acceptedAll = buffer.append(byte) && acceptedAll }
            XCTAssertEqual(buffer.data, Data(payload.prefix(limit)), "limit \(limit)")
            XCTAssertEqual(buffer.truncated, payload.count > limit, "limit \(limit)")
            XCTAssertEqual(acceptedAll, payload.count <= limit, "limit \(limit)")
        }
    }

    func testChunkAppendStopsMidChunkAtTheCap() {
        var buffer = CappedDataBuffer(limit: 5)
        XCTAssertTrue(buffer.append(contentsOf: Data("abc".utf8)))
        XCTAssertFalse(buffer.append(contentsOf: Data("defgh".utf8)))
        XCTAssertEqual(buffer.data, Data("abcde".utf8))
        XCTAssertTrue(buffer.truncated)
    }

    /// Documents current behaviour: the cap is bytewise, so a buffer cut
    /// mid-scalar holds invalid UTF-8. `errorMessage` then cannot decode
    /// the raw body at all and falls back to the "no explanation" string —
    /// the readable ASCII head is lost with it. (JSON-shaped error bodies
    /// are ASCII up to the message text, so the practical blast radius is
    /// a CJK error message cut at exactly 64 KiB.)
    func testMidScalarTruncationMakesRawErrorBodyUnreadable() {
        var buffer = CappedDataBuffer(limit: 5)
        XCTAssertFalse(buffer.append(contentsOf: Data("你好世界".utf8)))
        XCTAssertEqual(buffer.data.count, 5)
        XCTAssertEqual(SSEParser.errorMessage(from: buffer.data), "服务端没有返回说明。")
    }

    func testNegativeLimitClampsToZero() {
        var buffer = CappedDataBuffer(limit: -3)
        XCTAssertFalse(buffer.append(0x61))
        XCTAssertTrue(buffer.data.isEmpty)
        XCTAssertTrue(buffer.truncated)
    }
}

/// First direct tests for SSEParser.parse / errorMessage: every branch.
final class SSEParserBranchTests: XCTestCase {

    func testDeltaStringContent() {
        XCTAssertEqual(describe(SSEParser.parse(
            line: #"data: {"choices":[{"delta":{"content":"hi"}}]}"#)), "delta:hi")
    }

    func testDeltaArrayContentJoinsTextPartsAndSkipsOthers() {
        XCTAssertEqual(describe(SSEParser.parse(
            line: #"data: {"choices":[{"delta":{"content":[{"text":"a"},{"type":"image"},{"text":"b"}]}}]}"#)),
            "delta:ab")
    }

    func testMessageFallbackForNonStreamingShape() {
        XCTAssertEqual(describe(SSEParser.parse(
            line: #"data: {"choices":[{"message":{"content":"full"}}]}"#)), "delta:full")
    }

    func testEmptyDeltaAndMissingChoicesAreIgnored() {
        XCTAssertEqual(describe(SSEParser.parse(
            line: #"data: {"choices":[{"delta":{"content":""}}]}"#)), "ignored")
        XCTAssertEqual(describe(SSEParser.parse(line: #"data: {"choices":[]}"#)), "ignored")
        XCTAssertEqual(describe(SSEParser.parse(line: #"data: {"id":"x"}"#)), "ignored")
        XCTAssertEqual(describe(SSEParser.parse(
            line: #"data: {"choices":[{"delta":{"content":42}}]}"#)), "ignored")
    }

    func testInStreamErrorBecomesDeltaWithServerErrorPrefix() {
        XCTAssertEqual(describe(SSEParser.parse(
            line: #"data: {"error":{"message":"boom"}}"#)), "delta:\n\n[服务端错误] boom")
        // An error object without a message string is not surfaced.
        XCTAssertEqual(describe(SSEParser.parse(
            line: #"data: {"error":{"code":500}}"#)), "ignored")
    }

    func testDoneAndNonDataAndMalformedLines() {
        XCTAssertEqual(describe(SSEParser.parse(line: "data: [DONE]")), "done")
        XCTAssertEqual(describe(SSEParser.parse(line: "data:[DONE]")), "done")
        XCTAssertEqual(describe(SSEParser.parse(line: "data:   [DONE]  ")), "done")
        XCTAssertEqual(describe(SSEParser.parse(line: "data:")), "ignored")
        XCTAssertEqual(describe(SSEParser.parse(line: "data:   ")), "ignored")
        XCTAssertEqual(describe(SSEParser.parse(line: ": comment")), "ignored")
        XCTAssertEqual(describe(SSEParser.parse(line: "event: message")), "ignored")
        XCTAssertEqual(describe(SSEParser.parse(line: "")), "ignored")
        XCTAssertEqual(describe(SSEParser.parse(line: "data: {oops")), "ignored")
        XCTAssertEqual(describe(SSEParser.parse(line: "datax: [DONE]")), "ignored")
    }

    func testErrorMessagePrecedenceAndFallbacks() {
        XCTAssertEqual(SSEParser.errorMessage(
            from: Data(#"{"error":{"message":"m1"},"message":"m2"}"#.utf8)), "m1")
        XCTAssertEqual(SSEParser.errorMessage(
            from: Data(#"{"message":"m2","detail":"m3"}"#.utf8)), "m2")
        XCTAssertEqual(SSEParser.errorMessage(
            from: Data(#"{"detail":"m3"}"#.utf8)), "m3")
        XCTAssertEqual(SSEParser.errorMessage(from: Data("plain failure".utf8)), "plain failure")
        XCTAssertEqual(SSEParser.errorMessage(from: Data()), "服务端没有返回说明。")
    }

    func testErrorMessageRawFallbackIsCappedAt400Characters() {
        let long = String(repeating: "e", count: 500)
        XCTAssertEqual(SSEParser.errorMessage(from: Data(long.utf8)),
                       String(repeating: "e", count: 400))
    }
}
