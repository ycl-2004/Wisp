import XCTest
@testable import Wisp

/// Audit round 4, #47: runAppleScript read two captured Data variables
/// after discarding the DispatchGroup wait result — when a grandchild
/// held a pipe open past osascript's exit, the reads raced the reader
/// threads and could return torn data as a "successful" script output.
/// Output now flows through PipeResultBox (lock-synchronized), and a
/// wait timeout is a failure, never a read. The full osascript path is
/// macOS-only; the box is the portable seam the fix stands on.
final class Round4AppleScriptSinkTests: XCTestCase {

    func testBoxDeliversExactlyWhatWasWrittenUnderConcurrency() {
        let box = BrowserTextExtractor.PipeResultBox()
        let out = Data((0..<200_000).map { UInt8($0 % 251) })
        let err = Data("script error text".utf8)
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if index == 0 {
                box.setOut(out)
                box.setErr(err)
            }
            _ = box.out
            _ = box.err
        }
        XCTAssertEqual(box.out, out)
        XCTAssertEqual(box.err, err)
    }

    func testBoxStartsEmpty() {
        let box = BrowserTextExtractor.PipeResultBox()
        XCTAssertTrue(box.out.isEmpty)
        XCTAssertTrue(box.err.isEmpty)
    }
}
