import XCTest
@testable import WispCore

/// Round-2 audit #10: the cloud streaming path must bound what it accumulates.
/// A hostile or broken endpoint (custom base URLs are a headline feature) could
/// otherwise grow memory without limit: an endless error body, or one SSE line
/// that never terminates. These tests pin the two caps at their testable seams.
final class CappedDataBufferTests: XCTestCase {

    func testUnderLimitKeepsEveryByte() {
        var buffer = CappedDataBuffer(limit: 8)
        for byte in Data("12345678".utf8) {
            XCTAssertTrue(buffer.append(byte))
        }
        XCTAssertEqual(buffer.data, Data("12345678".utf8))
        XCTAssertFalse(buffer.truncated)
    }

    func testExactlyAtLimitIsNotTruncated() {
        var buffer = CappedDataBuffer(limit: 4)
        XCTAssertTrue(buffer.append(contentsOf: Data("abcd".utf8)))
        XCTAssertEqual(buffer.data.count, 4)
        XCTAssertFalse(buffer.truncated)
    }

    func testPastLimitStopsAtLimitAndReportsTruncation() {
        var buffer = CappedDataBuffer(limit: 4)
        XCTAssertFalse(buffer.append(contentsOf: Data("abcdefgh".utf8)))
        XCTAssertEqual(buffer.data, Data("abcd".utf8))
        XCTAssertTrue(buffer.truncated)
        // Once full, further appends keep refusing and change nothing.
        XCTAssertFalse(buffer.append(0x7A))
        XCTAssertEqual(buffer.data, Data("abcd".utf8))
    }

    func testZeroLimitAcceptsNothing() {
        var buffer = CappedDataBuffer(limit: 0)
        XCTAssertFalse(buffer.append(0x61))
        XCTAssertTrue(buffer.data.isEmpty)
        XCTAssertTrue(buffer.truncated)
    }

    func testErrorBodyCapIs64KiB() {
        XCTAssertEqual(OpenAICompatibleProvider.maxErrorBodyBytes, 64 * 1024)
    }
}

final class SSELineSplitterTests: XCTestCase {

    private func feedAll(_ splitter: inout SSELineSplitter, _ text: String) throws -> [String] {
        var lines: [String] = []
        for byte in Data(text.utf8) {
            if let line = try splitter.feed(byte) { lines.append(line) }
        }
        return lines
    }

    func testSingleLineIsEmittedAtNewline() throws {
        var splitter = SSELineSplitter()
        let lines = try feedAll(&splitter, "data: hello\n")
        XCTAssertEqual(lines, ["data: hello"])
        XCTAssertNil(splitter.finish())
    }

    func testCRLFLineEndingStripsTheCarriageReturn() throws {
        var splitter = SSELineSplitter()
        let lines = try feedAll(&splitter, "data: a\r\n")
        XCTAssertEqual(lines, ["data: a"])
    }

    func testMultipleLinesIncludingBlankSeparator() throws {
        var splitter = SSELineSplitter()
        let lines = try feedAll(&splitter, "data: one\n\ndata: two\n")
        XCTAssertEqual(lines, ["data: one", "", "data: two"])
    }

    func testUnterminatedTailIsFlushedByFinish() throws {
        var splitter = SSELineSplitter()
        let lines = try feedAll(&splitter, "data: tail")
        XCTAssertEqual(lines, [])
        XCTAssertEqual(splitter.finish(), "data: tail")
        // finish() drains: a second call has nothing left.
        XCTAssertNil(splitter.finish())
    }

    func testFinishOnEmptyStreamReturnsNil() {
        var splitter = SSELineSplitter()
        XCTAssertNil(splitter.finish())
    }

    func testMultibyteUTF8SplitAcrossFeedsDecodesIntact() throws {
        var splitter = SSELineSplitter()
        // Feeding one byte at a time splits every multi-byte scalar; the
        // reassembled line must still decode as the original string.
        let lines = try feedAll(&splitter, "data: 你好，世界\n")
        XCTAssertEqual(lines, ["data: 你好，世界"])
    }

    func testLineExactlyAtCapIsAccepted() throws {
        var splitter = SSELineSplitter()
        let payload = String(repeating: "x", count: SSELineSplitter.maxLineBytes)
        let lines = try feedAll(&splitter, payload + "\n")
        XCTAssertEqual(lines, [payload])
    }

    func testLinePastCapThrows() {
        var splitter = SSELineSplitter()
        let payload = String(repeating: "x", count: SSELineSplitter.maxLineBytes + 1)
        var thrown: Error?
        do {
            _ = try feedAll(&splitter, payload)
        } catch {
            thrown = error
        }
        XCTAssertEqual(thrown as? SSELineSplitter.Failure,
                       .lineTooLong(limit: SSELineSplitter.maxLineBytes))
    }
}

final class StreamByteBudgetTests: XCTestCase {

    func testUnderLimitAccountsEveryByte() throws {
        var budget = StreamByteBudget(limit: 10)
        for _ in 0..<10 { try budget.add() }
        XCTAssertEqual(budget.total, 10)
    }

    func testExactlyAtLimitIsAccepted() throws {
        var budget = StreamByteBudget(limit: 4)
        try budget.add(4)
        XCTAssertEqual(budget.total, 4)
    }

    func testBytePastLimitThrows() {
        var budget = StreamByteBudget(limit: 3)
        XCTAssertNoThrow(try budget.add(3))
        XCTAssertThrowsError(try budget.add()) { error in
            XCTAssertEqual(error as? StreamByteBudget.Failure,
                           .totalTooLarge(limit: 3))
        }
        // 抛错后 total 停在上限，不再往上长。
        XCTAssertEqual(budget.total, 3)
    }

    func testBulkAddCrossingLimitThrowsAtomically() {
        var budget = StreamByteBudget(limit: 10)
        XCTAssertNoThrow(try budget.add(7))
        XCTAssertThrowsError(try budget.add(4)) { error in
            XCTAssertEqual(error as? StreamByteBudget.Failure,
                           .totalTooLarge(limit: 10))
        }
        XCTAssertEqual(budget.total, 10)
    }

    func testDefaultLimitIs32MiB() {
        XCTAssertEqual(StreamByteBudget.maxTotalBytes, 32 << 20)
        XCTAssertEqual(StreamByteBudget().limit, StreamByteBudget.maxTotalBytes)
    }
}
