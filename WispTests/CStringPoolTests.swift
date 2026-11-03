import XCTest
@testable import Wisp

/// Round-2 audit #25: CStringPool force-unwrapped `strdup`. Malloc failure
/// is vanishingly rare, but the pool sits in the model-loading path where a
/// proper error vocabulary (ListeningFailure) already exists — a crash on
/// allocation failure is strictly worse than a "model failed to load"
/// message. These tests pin the pool's contract; the failure branch itself
/// cannot be triggered from a unit test (there is no way to make strdup
/// fail on demand), so it is covered by inspection and by the
/// `allocationFailed` flag's happy-path value.
final class CStringPoolTests: XCTestCase {

    func testPooledStringContentsMatchInput() {
        let pool = CStringPool()
        XCTAssertEqual(String(cString: pool("greedy_search")), "greedy_search")
    }

    func testPointersStayValidAfterFurtherAppends() {
        let pool = CStringPool()
        let first = pool("first")
        for index in 0..<64 { _ = pool("value-\(index)") }
        // The whole point of the pool: earlier pointers outlive later calls.
        XCTAssertEqual(String(cString: first), "first")
    }

    func testDistinctStringsGetDistinctStorage() {
        let pool = CStringPool()
        XCTAssertNotEqual(pool("a"), pool("b"))
    }

    func testMissingRolePathResolvesToEmptyString() {
        let pool = CStringPool()
        XCTAssertEqual(String(cString: pool.path("missing", in: [:])), "")
    }

    func testPresentRolePathResolvesToTheFilePath() {
        let pool = CStringPool()
        let url = URL(fileURLWithPath: "/tmp/model.onnx")
        XCTAssertEqual(String(cString: pool.path("model", in: ["model": url])), "/tmp/model.onnx")
    }

    func testAllocationFailureFlagIsClearInNormalUse() {
        let pool = CStringPool()
        _ = pool("anything")
        _ = pool.path("missing", in: [:])
        XCTAssertFalse(pool.allocationFailed)
    }
}
