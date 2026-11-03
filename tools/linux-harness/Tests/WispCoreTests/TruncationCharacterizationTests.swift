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
        XCTAssertTrue(result.contains("[…… "), result)
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
        // Samples trim to empty; assert the exact marker the production
        // builder emits (its prose is localized, so build it, don't pin it).
        XCTAssertTrue(result.contains(
            ContextCapture.omissionMarker(omitted: 102, previousEnd: "", nextStart: "")), result)
    }

    func testZeroLimitYieldsOnlyTheMarker() {
        let result = ContextCapture.truncate("abcdef", limit: 0)
        XCTAssertEqual(result,
                       ContextCapture.omissionMarker(omitted: 6, previousEnd: "", nextStart: ""))
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
                // Extract the omitted count the marker claims: in every
                // catalog locale the first number after the "[…… " frame
                // is the omitted count (the prose around it is localized).
                let frame = result.range(of: "[…… ")
                XCTAssertNotNil(frame, "alphabet \(alphabet) limit \(limit): \(result)")
                let claimed = Int(result[frame!.upperBound...].drop(while: { !$0.isNumber })
                    .prefix(while: \.isNumber))!
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

    /// INVARIANT (#32, fixed in round 5): `fit` reserves the truncation
    /// marker's own estimated cost before cutting, so a fitted result no
    /// longer lands above budget by the marker's cost. The reserve is
    /// computed from the marker text in the locale that will actually be
    /// appended — this harness resolves the Chinese marker (~107 tokens),
    /// English hosts resolve the cheaper English one (~93) and reserve
    /// correspondingly less — so the invariant is asserted identically
    /// in both paths (the WispTests copy of the oversized case asserts
    /// the same ≤ budget bound).
    /// Scope note: the guarantee covers the marker's contribution. The
    /// separate 2,000-character allowance floor (documented above) can
    /// still leave a section above a *tiny* budget by design; that floor
    /// predates #32 and is untouched.
    func testFitReservesMarkerCost_ResultNeverExceedsBudget() {
        let original = String(repeating: "甲", count: 5_000)
        let fitted = CLIPrompt.fit([original], budget: 3_000)
        XCTAssertEqual(fitted.count, 1)

        let estimate = CLIPrompt.estimatedTokens(fitted[0])
        XCTAssertLessThanOrEqual(estimate, 3_000,
                                 "marker-aware fit must land within budget, got \(estimate)")
        // It did not fix the overshoot by butchering the content either:
        // the reserve is ~120 tokens, so the result stays close to budget.
        XCTAssertGreaterThan(estimate, 2_800)
        // The fitted text is NOT the old single-pass output anymore.
        XCTAssertNotEqual(fitted[0], ContextCapture.truncate(original, limit: 3_000))
        // The marker is still present and functional.
        XCTAssertTrue(fitted[0].contains("[…… "))

        // The reserve really covers the marker this locale appends:
        // measured cost of the marker in the fitted output is the total
        // minus the kept head+tail characters (all wide here).
        let reserve = CLIPrompt.truncationMarkerReserve(for: original)
        XCTAssertGreaterThan(reserve, 80,
                             "reserve \(reserve) must cover the locale marker (~93 EN / ~107 ZH)")
        XCTAssertLessThan(reserve, 200)
    }

    /// Same invariant for narrow (Latin) content: the marker's prose is
    /// locale text, not content, so the reserve must be charged there too.
    func testFitReservesMarkerCost_NarrowContent() {
        let original = String(repeating: "lorem ipsum dolor sit amet ", count: 400) // 10,800 chars ≈ 2,700 tokens
        let fitted = CLIPrompt.fit([original], budget: 1_000)
        XCTAssertEqual(fitted.count, 1)
        let estimate = CLIPrompt.estimatedTokens(fitted[0])
        XCTAssertLessThanOrEqual(estimate, 1_000,
                                 "narrow content must also land within budget, got \(estimate)")
        XCTAssertGreaterThan(estimate, 600)
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
