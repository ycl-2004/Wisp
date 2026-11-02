import XCTest
@testable import Wisp

/// Audit round 4 (test-engineering lane): DrainBuffer boundary matrix.
/// Round 2 covered under-cap, one over-cap tail case, many-small-chunks,
/// and one mid-scalar trim (3-byte scalar). Missing: exact cap-1 / cap /
/// cap+1 in single appends, 2-byte and 4-byte scalars straddling the
/// trim point (the continuation-skip loop must skip 1...3 bytes), a
/// single chunk far past the cap, and appends after a trim.
final class DrainBufferBoundaryTests: XCTestCase {

    private let cap = DrainBuffer.maxBytes

    func testCapMinusOneCapAndCapPlusOne() {
        let under = DrainBuffer()
        under.append(Data(repeating: 0x61, count: cap - 1))
        XCTAssertEqual(under.text.count, cap - 1)

        let exact = DrainBuffer()
        exact.append(Data(repeating: 0x61, count: cap))
        XCTAssertEqual(exact.text.count, cap)

        // cap + 1: the first byte is pushed out, the tail is exact.
        let over = DrainBuffer()
        over.append(Data("Z".utf8))
        over.append(Data(repeating: 0x61, count: cap))
        XCTAssertEqual(over.text, String(repeating: "a", count: cap))
    }

    func testSingleChunkFarPastCapKeepsExactTail() {
        let buffer = DrainBuffer()
        buffer.append(Data(repeating: 0x62, count: cap * 3))
        XCTAssertEqual(buffer.text, String(repeating: "b", count: cap))
    }

    func testEmptyAppendChangesNothing() {
        let buffer = DrainBuffer()
        buffer.append(Data("keep".utf8))
        buffer.append(Data())
        XCTAssertEqual(buffer.text, "keep")
    }

    func testAppendsAfterATrimKeepWorking() {
        let buffer = DrainBuffer()
        buffer.append(Data(repeating: 0x61, count: cap + 10))
        buffer.append(Data("END".utf8))
        XCTAssertEqual(buffer.text.count, cap)
        XCTAssertTrue(buffer.text.hasSuffix("END"))
    }

    /// 2-byte scalar (é = C3 A9): trimming 1 byte leaves exactly one
    /// continuation byte, which must be skipped or `text` decodes to "".
    func testTrimInsideTwoByteScalar() {
        let buffer = DrainBuffer()
        buffer.append(Data("é".utf8))                              // 2 bytes
        buffer.append(Data(repeating: 0x61, count: cap - 1))        // total cap + 1
        // Trim drops C3; A9 is a lone continuation and is skipped too.
        XCTAssertEqual(buffer.text, String(repeating: "a", count: cap - 1))
    }

    /// 4-byte scalar (😀 = F0 9F 98 80): trimming 1, 2, or 3 bytes into
    /// it leaves 3, 2, or 1 continuation bytes — all must be skipped,
    /// and the surviving text must be exactly the ASCII tail.
    func testTrimInsideFourByteScalarAtEveryOffset() {
        for trim in 1...3 {
            let buffer = DrainBuffer()
            buffer.append(Data("😀".utf8))                          // 4 bytes
            let filler = cap + trim - 4
            buffer.append(Data(repeating: 0x61, count: filler))     // total cap + trim
            XCTAssertEqual(buffer.text, String(repeating: "a", count: filler),
                           "trim \(trim) into a 4-byte scalar")
        }
    }

    /// Mixed content: after a mid-scalar trim the remainder must still
    /// decode as the exact expected string (not merely be non-empty).
    func testTrimBoundaryBetweenScalarsKeepsBothSidesIntact() {
        let buffer = DrainBuffer()
        // 你 (3 bytes) + 好 (3 bytes), then filler so the trim lands
        // exactly between the two scalars: trim 3 bytes.
        buffer.append(Data("你好".utf8))
        let filler = String(repeating: "a", count: cap - 3)
        buffer.append(Data(filler.utf8))                            // total cap + 3
        XCTAssertEqual(buffer.text, "好" + filler)
    }
}
