import XCTest
@testable import WispCore

/// Audit round 4, #38: three call sites read whole response bodies with
/// data(for:) — validate(), the Ollama probe, and the update check —
/// so a broken or hostile endpoint could make Wisp buffer an arbitrary
/// amount of memory before anyone looked at the bytes (round 2's #10
/// capped only the streaming path). Bodies now accumulate through
/// OpenAICompatibleProvider.accumulate, which throws
/// URLError.dataLengthExceedsMaximum past the cap; the existing error
/// mapping at each call site takes it from there.
final class Round4CappedBodyTests: XCTestCase {

    private func stream(of bytes: [UInt8]) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish()
        }
    }

    func testAccumulateUnderLimitReturnsEverything() async throws {
        let bytes = [UInt8](repeating: 0x61, count: 1_000)
        let data = try await OpenAICompatibleProvider.accumulate(stream(of: bytes), limit: 2_000)
        XCTAssertEqual(data.count, 1_000)
    }

    func testAccumulateExactlyAtLimitIsAccepted() async throws {
        let bytes = [UInt8](repeating: 0x62, count: 500)
        let data = try await OpenAICompatibleProvider.accumulate(stream(of: bytes), limit: 500)
        XCTAssertEqual(data.count, 500)
    }

    func testAccumulateOverLimitThrowsLengthExceeded() async {
        let bytes = [UInt8](repeating: 0x63, count: 501)
        do {
            _ = try await OpenAICompatibleProvider.accumulate(stream(of: bytes), limit: 500)
            XCTFail("one byte over the cap must throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAccumulateEmptyStreamIsEmpty() async throws {
        let data = try await OpenAICompatibleProvider.accumulate(stream(of: []), limit: 10)
        XCTAssertTrue(data.isEmpty)
    }
}
