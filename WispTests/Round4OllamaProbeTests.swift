import XCTest
@testable import Wisp

/// Audit round 4, #50: OllamaSupport.probe parsed the /models body with
/// a chain of optional casts ending in ?? [] — any valid JSON of the
/// wrong shape (a proxy's error page, the native /api/tags shape, a
/// top-level array) was reported as "running with zero models", and
/// malformed JSON surfaced a raw Foundation error string. The parse is
/// now a pure function returning nil for unrecognised shapes, and the
/// probe reports .failed instead.
final class Round4OllamaProbeTests: XCTestCase {

    func testValidShapeParsesSorted() {
        let body = Data(#"{"data":[{"id":"qwen3:8b"},{"id":"llama3.2:3b"}]}"#.utf8)
        XCTAssertEqual(OllamaSupport.models(from: body), ["llama3.2:3b", "qwen3:8b"])
    }

    func testEmptyDataArrayIsLegitimatelyZeroModels() {
        // A healthy server with nothing installed: running, zero models.
        XCTAssertEqual(OllamaSupport.models(from: Data(#"{"data":[]}"#.utf8)), [])
    }

    func testEntriesWithoutStringIDsAreDropped() {
        let body = Data(#"{"data":[{"id":"kept:1"},{"name":"no-id"},{"id":42}]}"#.utf8)
        XCTAssertEqual(OllamaSupport.models(from: body), ["kept:1"])
    }

    func testWrongShapesReturnNil() {
        let cases: [String] = [
            #"{"models":[{"name":"llama3.2"}]}"#,  // native /api/tags shape, not /v1/models
            #"[{"id":"x"}]"#,                       // top-level array
            #"{"data":{"id":"x"}}"#,                // data not an array
            #"{"unexpected":true}"#,                // no data key at all
            "not json at all",
            "",
        ]
        for json in cases {
            XCTAssertNil(OllamaSupport.models(from: Data(json.utf8)), json)
        }
    }
}
