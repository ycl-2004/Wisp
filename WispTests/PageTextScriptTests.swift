import JavaScriptCore
import XCTest
@testable import Wisp

/// Runs the injected page scripts in JavaScriptCore against a stub DOM, so the
/// extraction rules are checked as JavaScript, not as strings.
final class PageTextScriptTests: XCTestCase {
    /// A page whose body text the test sets; the scroller never moves.
    private func page() -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in XCTFail("JS: \(exception?.toString() ?? "?")") }
        context.evaluateScript("""
        var window = this;
        var scroller = { scrollTop: 0, scrollHeight: 2000, clientHeight: 600 };
        var document = {
          title: "Fixture", body: { innerText: "" },
          scrollingElement: scroller, documentElement: scroller,
          querySelectorAll: function () { return []; }
        };
        var location = { href: "https://example.com/" };
        window.getSelection = function () { return { toString: function () { return ""; } }; };
        function getComputedStyle() { return { overflowY: "visible" }; }
        """)
        return context
    }

    private func run(_ script: String, in context: JSContext) throws -> [String: Any] {
        let json = try XCTUnwrap(context.evaluateScript(script)?.toString())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// A code page used to lose every repeated `}` and `return`: the first read
    /// deduplicated lines on every page, not only scroll-collected ones.
    func testFirstReadKeepsRepeatedLines() throws {
        let context = page()
        context.evaluateScript(#"document.body.innerText = "func a() {\n  return 1\n}\nfunc b() {\n  return 1\n}\nOK\nOK";"#)
        let result = try run(PageTextScript.beginJS, in: context)
        XCTAssertEqual(result["text"] as? String,
                       "func a() {\nreturn 1\n}\nfunc b() {\nreturn 1\n}\nOK\nOK")
    }

    /// Scroll collection still drops what a virtual list re-renders on the next pass.
    func testLaterScrollPassesDropReRenderedLines() throws {
        let context = page()
        context.evaluateScript(#"document.body.innerText = "Header\nfirst\nfirst";"#)
        _ = try run(PageTextScript.beginJS, in: context)
        context.evaluateScript(#"document.body.innerText = "Header\nfirst\nsecond";"#)
        let step = try run(PageTextScript.absorbJS, in: context)
        XCTAssertEqual(step["added"] as? Int, 1)
        let finish = try run(PageTextScript.finishJS, in: context)
        XCTAssertEqual(finish["text"] as? String, "Header\nfirst\nfirst\nsecond")
    }
}
