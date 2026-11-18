import XCTest
@testable import Wisp

final class MarkdownBlockTests: XCTestCase {
    func testParsesStandardTableSeparator() {
        let blocks = MarkdownBlock.parse("| Name | Value |\n| --- | :---: |\n| Wisp | 1 |")

        guard case .table(let headers, let rows) = blocks.first else {
            return XCTFail("Expected a Markdown table")
        }
        XCTAssertEqual(headers, ["Name", "Value"])
        XCTAssertEqual(rows, [["Wisp", "1"]])
    }

    func testDoesNotTreatSingleDashesAsTableSeparator() {
        let blocks = MarkdownBlock.parse("A | B\n- | -")

        XCTAssertFalse(blocks.contains { block in
            if case .table = block { return true }
            return false
        })
    }
}
