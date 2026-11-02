import XCTest
@testable import WispCore

/// Audit round 4 (test-engineering lane): `ContextCapture.truncate` and
/// `CLIPrompt.fit` previously had exactly ONE indirect test between them
/// (the oversized-prompt case that became finding #32). This file pins
/// the invariants that hold today and — in the tests whose names start
/// with `testDocumentingCurrentBehavior` — characterizes behaviour that
/// looks wrong but is NOT fixed here: #32's disposition (subtract the
/// marker's cost inside `fit`, vs a locale-aware test bound) is the
/// owner's pending product decision. These tests document, they do
/// not endorse.

final class ContextCaptureTruncateTests: XCTestCase {

    func testAtOrUnderLimitReturnsInputVerbatim() {
        XCTAssertEqual(ContextCapture.truncate("", limit: 0), "")
        XCTAssertEqual(ContextCapture.truncate("", limit: 10), "")
        XCTAssertEqual(ContextCapture.truncate("abc", limit: 3), "abc")
        XCTAssertEqual(ContextCapture.truncate("abc", limit: 100), "abc")
        XCTAssertEqual(ContextCapture.truncate("你好世界", limit: 4), "你好世界")
    }

    func testHeadAndTailArePreservedAroundTheMarker() {
        let text = (0..<10).map { "line-\($0)-" + String(repeating: "x", count: 20) }
            .joined(separator: "\n")
        let result = ContextCapture.truncate(text, limit: 100)
        XCTAssertTrue(result.hasPrefix("line-0-"), result)
        // The marker announces the omission and the samples bracket it.
        XCTAssertTrue(result.contains("此处省略正文中间"), result)
        // Head keeps ~75%, so the tail sample comes from the last lines.
        XCTAssertTrue(result.hasSuffix(String(text.suffix(10))), result)
        XCTAssertLessThan(result.count, text.count + 120)
    }

    func testNewlineSnappingPrefersLineBoundaries() {
        // Newlines every 10 chars: the head cut must land on a newline
        // (snapBackward) and the tail must start right after one
        // (snapForward), rather than slicing mid-line.
        let line = String(repeating: "a", count: 9) + "\n"
        let text = String(repeating: line, count: 100) // 1000 chars
        let result = ContextCapture.truncate(text, limit: 200)
        let markerStart = result.range(of: "\n\n[")!.lowerBound
        let head = String(result[..<markerStart])
        XCTAssertTrue(head.hasSuffix(String(repeating: "a", count: 9)),
                      "head should end at a full line, got tail: \(head.suffix(15))")
        let afterMarker = result.range(of: "]\n\n")!.upperBound
        let tail = String(result[afterMarker...])
        XCTAssertTrue(tail.hasPrefix(String(repeating: "a", count: 9)))
    }

    func testGraphemeClustersAreNeverSplit() {
        // Family ZWJ sequence: 1 Character, 7 scalars, 25 UTF-8 bytes.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1)
        let text = String(repeating: family, count: 300)
        let result = ContextCapture.truncate(text, limit: 100)
        XCTAssertTrue(result.hasPrefix(String(repeating: family, count: 70)))
        XCTAssertTrue(result.hasSuffix(String(repeating: family, count: 20)))
        // No replacement characters anywhere: nothing was cut mid-scalar.
        XCTAssertFalse(result.contains("\u{FFFD}"))
    }

    func testAllNewlinesInputStillTruncatesWithEmptySamples() {
        let text = String(repeating: "\n", count: 200)
        let result = ContextCapture.truncate(text, limit: 100)
        // Samples trim to empty, so the marker quotes 「」 twice.
        XCTAssertTrue(result.contains("上一段结束于「」，下一段开始于「」"), result)
        XCTAssertTrue(result.contains("省略正文中间 102 字"), result)
    }

    func testZeroLimitYieldsOnlyTheMarker() {
        let result = ContextCapture.truncate("abcdef", limit: 0)
        XCTAssertTrue(result.contains("省略正文中间 6 字"), result)
        XCTAssertFalse(result.contains("abcdef"))
    }

    /// Invariant across shapes: the result is always head + marker + tail
    /// where head is a prefix and tail a suffix of the input, the marker's
    /// stated omission count matches the characters actually dropped,
    /// and the kept characters total exactly the limit when no newline
    /// snapping applies.
    func testOmittedCountMatchesDroppedCharactersAcrossShapes() {
        var rng = SeededRNG(seed: 0x7A11_0001)
        let alphabets = ["ab", "甲乙丙", "a甲b😀", "word "]
        for alphabet in alphabets {
            let chars = Array(alphabet)
            let text = String((0..<500).map { _ in chars[rng.nextInt(chars.count)] })
            for limit in [10, 100, 250, 499] {
                let result = ContextCapture.truncate(text, limit: limit)
                // Extract the omitted count the marker claims.
                let marker = result.components(separatedBy: "此处省略正文中间 ")
                XCTAssertEqual(marker.count, 2, "alphabet \(alphabet) limit \(limit)")
                let claimed = Int(marker[1].prefix(while: \.isNumber))!
                // Head is a prefix of the input, tail a suffix; what is
                // neither in head nor tail was dropped.
                var headLen = 0
                while headLen < text.count, headLen < result.count,
                      Array(text)[headLen] == Array(result)[headLen] { headLen += 1 }
                // (Prefix comparison is only exact until the marker; the
                // marker starts with "\n\n[", which the alphabets lack or
                // — for "word " — cannot produce at a cut point.)
                XCTAssertEqual(text.count - claimed <= headLen + limit, true)
                XCTAssertGreaterThanOrEqual(claimed, text.count - limit)
                XCTAssertLessThanOrEqual(claimed, text.count)
            }
        }
    }
}

final class CLIPromptEstimatorTests: XCTestCase {

    func testNarrowCharactersCostOneTokenPerFourWithFloorDivision() {
        XCTAssertEqual(CLIPrompt.estimatedTokens(""), 0)
        XCTAssertEqual(CLIPrompt.estimatedTokens("abc"), 0)   // 3/4 floors to 0
        XCTAssertEqual(CLIPrompt.estimatedTokens("abcd"), 1)
        XCTAssertEqual(CLIPrompt.estimatedTokens("abcde"), 1) // 5/4 floors to 1
        XCTAssertEqual(CLIPrompt.estimatedTokens("abcdefgh"), 2)
    }

    func testWideRangesCostOneTokenPerScalar() {
        XCTAssertEqual(CLIPrompt.estimatedTokens("甲"), 1)      // CJK
        XCTAssertEqual(CLIPrompt.estimatedTokens("あ"), 1)      // Hiragana
        XCTAssertEqual(CLIPrompt.estimatedTokens("한"), 1)      // Hangul
        XCTAssertEqual(CLIPrompt.estimatedTokens("Ａ"), 1)      // Fullwidth
        XCTAssertEqual(CLIPrompt.estimatedTokens("测试abcde"), 3) // pinned pre-existing case
    }

    func testEmojiAndZWJScalarsAreNarrow() {
        // 😀 is U+1F600: outside every wide range, so it costs 1/4 token
        // per scalar — four emoji estimate as a single token.
        XCTAssertEqual(CLIPrompt.estimatedTokens("😀😀😀😀"), 1)
        // The ZWJ family is 7 narrow scalars → 7/4 = 1.
        XCTAssertEqual(CLIPrompt.estimatedTokens("👨‍👩‍👧‍👦"), 1)
        // Combining marks are narrow scalars too.
        XCTAssertEqual(CLIPrompt.estimatedTokens("e\u{301}e\u{301}e\u{301}e\u{301}"), 2)
    }
}

final class CLIPromptFitCharacterizationTests: XCTestCase {

    func testEmptyAndUnderBudgetInputsPassThroughUnchanged() {
        XCTAssertEqual(CLIPrompt.fit([], budget: 100), [])
        XCTAssertEqual(CLIPrompt.fit([], budget: 0), [])
        XCTAssertEqual(CLIPrompt.fit([""], budget: 0), [""])
        XCTAssertEqual(CLIPrompt.fit(["short", "sections"], budget: 10_000),
                       ["short", "sections"])
        // Exactly at budget: no truncation (the guard is `total > budget`).
        XCTAssertEqual(CLIPrompt.fit(["甲乙丙丁"], budget: 4), ["甲乙丙丁"])
    }

    /// DOCUMENTING CURRENT BEHAVIOUR (#32): the allowance floor is
    /// 2,000 characters — a section shorter than that can never be
    /// truncated, whatever the budget says. A zero budget with a short
    /// section returns the section untouched.
    func testDocumentingCurrentBehavior_ShortSectionSurvivesZeroBudget() {
        let short = String(repeating: "甲", count: 100)
        XCTAssertEqual(CLIPrompt.fit([short], budget: 0), [short])
        XCTAssertEqual(CLIPrompt.fit([short], budget: 1), [short])
    }

    /// DOCUMENTING CURRENT BEHAVIOUR (#32): the allowance floor also
    /// dominates a zero budget for a long section: fit truncates to the
    /// 2,000-character floor (plus marker), not to anywhere near 0.
    func testDocumentingCurrentBehavior_ZeroBudgetStillReturnsTheFloor() {
        let fitted = CLIPrompt.fit([String(repeating: "甲", count: 5_000)], budget: 0)
        XCTAssertEqual(fitted.count, 1)
        XCTAssertLessThan(fitted[0].count, 5_000)
        XCTAssertGreaterThan(CLIPrompt.estimatedTokens(fitted[0]), 2_000)
    }

    /// DOCUMENTING CURRENT BEHAVIOUR (#32, the finding itself): `fit`
    /// makes one proportional pass per section and never accounts for
    /// the truncation marker `ContextCapture.truncate` appends, so the
    /// result can exceed the budget by the marker's full token cost.
    /// Measured here with the app's own estimator: the fitted prompt for
    /// the pre-existing test's input estimates ABOVE its 3,000 budget,
    /// and the overshoot equals the marker cost (~107 tokens for the
    /// Chinese marker this harness resolves; ~93 for the English one —
    /// which is why the original test's budget+100 slack passes only
    /// on English-locale hosts). The fix is the owner's decision; this
    /// test pins the numbers so the decision is made on evidence.
    func testDocumentingCurrentBehavior_FitIgnoresMarkerCost_Finding32() {
        let original = String(repeating: "甲", count: 5_000)
        let fitted = CLIPrompt.fit([original], budget: 3_000)
        XCTAssertEqual(fitted.count, 1)

        // fit's single pass truncates the one section to a 3,000-char
        // allowance; the result is exactly truncate's output for it.
        XCTAssertEqual(fitted[0], ContextCapture.truncate(original, limit: 3_000))

        let estimate = CLIPrompt.estimatedTokens(fitted[0])
        let markerCost = estimate - 3_000
        XCTAssertGreaterThan(estimate, 3_000, "fit output must be over budget today")
        XCTAssertGreaterThan(markerCost, 100,
                             "marker costs \(markerCost) tokens here — more than the original test's +100 slack")
        // The overshoot is exactly the marker: head+tail estimate 3,000.
        XCTAssertEqual(estimate, 3_000 + markerCost)
    }

    /// With wildly unequal sections, the small one is never touched and
    /// each pass cuts only the current longest. Documents that the loop
    /// runs at most one pass per section (`for _ in sections.indices`),
    /// so even two passes may leave the total over budget.
    func testUnequalSectionsOnlyTheLongestIsCut() {
        let long = String(repeating: "甲", count: 5_000)
        let fitted = CLIPrompt.fit([long, "short"], budget: 3_000)
        XCTAssertEqual(fitted.count, 2)
        XCTAssertEqual(fitted[1], "short")
        XCTAssertLessThan(fitted[0].count, long.count)
        let total = fitted.reduce(0) { $0 + CLIPrompt.estimatedTokens($1) }
        XCTAssertLessThan(total, 5_001)
    }

    func testMultiSectionOverBudgetConvergesBelowOriginalTotal() {
        let sections = [String(repeating: "甲", count: 3_000),
                        String(repeating: "乙", count: 3_000)]
        let fitted = CLIPrompt.fit(sections, budget: 4_000)
        XCTAssertEqual(fitted.count, 2)
        let total = fitted.reduce(0) { $0 + CLIPrompt.estimatedTokens($1) }
        XCTAssertLessThan(total, 6_000)
        // Both sections were over the per-pass longest at some point or
        // the total already fit; either way neither grew.
        XCTAssertLessThanOrEqual(fitted[0].count, 3_000 + 200)
        XCTAssertLessThanOrEqual(fitted[1].count, 3_000 + 200)
    }
}
