import XCTest
@testable import Wisp

/// Fixtures shared by both listening test files.
extension XCTestCase {
    func transcript() -> ListeningTranscript {
        ListeningTranscript(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_000),
                            locale: "en-US", applicationName: "Fixture", savesAudio: false)
    }

    func segment(id: UUID = UUID(), source: ListeningSource = .application,
                 start: Double, end: Double, text: String, final: Bool = true) -> ListeningSegment {
        ListeningSegment(id: id, source: source, start: start, end: end, text: text, isFinal: final)
    }
}

/// The Foundation-only half of the listening tests: ListeningTranscript,
/// ListeningPreferences and ListeningStorageBudget. Runs on macOS CI and in
/// the Linux harness; ListeningTests.swift keeps the ListeningModel,
/// scheduler/track and SwiftUI tests.
final class ListeningTranscriptTests: XCTestCase {
    func testStorageAdmissionRejectsRootLinksWithoutTouchingTheirTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let link = root.appendingPathComponent("Listening")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ListeningStorageBudget.validate(root: link, savesAudio: false))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try ListeningStorageBudget.validate(root: dangling, savesAudio: false))
    }

    func testPartialRevisionDoesNotDuplicateAndLatePartialCannotUndoFinal() {
        var transcript = transcript()
        let id = UUID()
        transcript.upsert(segment(id: id, start: 1, end: 2, text: "ship", final: false))
        transcript.upsert(segment(id: id, start: 1, end: 3, text: "ship tomorrow"))
        transcript.upsert(segment(id: id, start: 1, end: 2, text: "ship", final: false))
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].text, "ship tomorrow")
        XCTAssertTrue(transcript.segments[0].isFinal)
    }

    func testTwoSourcesRemainSeparateAndOutOfOrderCallbacksAreSorted() {
        var transcript = transcript()
        transcript.upsert(segment(source: .microphone, start: 20, end: 22, text: "My response"))
        transcript.upsert(segment(start: 10, end: 30, text: "Their question"))
        transcript.upsert(segment(start: 0, end: 1, text: "  \n"))
        XCTAssertEqual(transcript.segments.map(\.source), [.application, .microphone])
        XCTAssertEqual(transcript.segments.map(\.start), [10, 20])
    }

    /// 会议里隔几分钟才按一次分析，中间这几分钟必须一起交出去。早先按「最近 90 秒」取，
    /// 间隔一超过 90 秒，中间说的话就再也进不了任何一次发送，只剩本地记录里有。
    func testEverythingSinceTheLastTransferIsSentHoweverLongAgoItWasSaid() {
        var transcript = transcript()
        let staged = segment(start: 0, end: 5, text: "已经交出去的开场")
        transcript.upsert(staged)
        transcript.upsert(segment(start: 40, end: 160, text: "五分钟前说的重点"))
        transcript.upsert(segment(source: .microphone, start: 300, end: 305, text: "刚刚说的最后一句"))
        transcript.stoppedAt = Date(timeIntervalSince1970: 100_000)
        let pending = transcript.unstagedDraft(excluding: [staged.id]).text
        XCTAssertTrue(pending.contains("五分钟前说的重点"))
        XCTAssertTrue(pending.contains("刚刚说的最后一句"))
        XCTAssertFalse(pending.contains("已经交出去的开场"))
    }

    func testExplanationBudgetAndUncertainTextArePreserved() {
        var transcript = transcript()
        transcript.upsert(segment(start: 0, end: 5, text: String(repeating: "你好🌤", count: 100), final: false))
        XCTAssertEqual(transcript.spokenText(characterLimit: 60).count, 60)
        XCTAssertTrue(transcript.spokenText().contains(String(localized: "（末尾是临时文字，可能还会修正）")))
        XCTAssertEqual(transcript.spokenText(characterLimit: 0), "")
    }

    func testPersistentSessionAndReadableTextRoundTripWithoutAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var transcript = transcript()
        transcript.upsert(segment(start: 3661, end: 3662, text: "Hello 你好"))
        try transcript.save(in: directory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ListeningTranscript.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        XCTAssertEqual(restored.segments, transcript.segments)
        XCTAssertFalse(restored.savesAudio)
        let text = try String(contentsOf: directory.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("01:01:01"))
        XCTAssertTrue(text.contains("Hello 你好"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["session.json", "transcript.txt"])
    }

    /// 输入框里的转写要像一段话，不是一堆 `[00:00:01–00:00:02] 我方麦克风:` 开头的碎行。
    func testDraftTextDropsTimestampsAndMergesEachSpeakersBatches() {
        var single = transcript()
        single.upsert(segment(source: .microphone, start: 0, end: 2, text: "等下帮我看一下什么情况"))
        single.upsert(segment(source: .microphone, start: 2, end: 4, text: "就这种东西"))
        XCTAssertEqual(single.spokenText(), "等下帮我看一下什么情况 就这种东西")
        XCTAssertFalse(single.spokenText().contains("00:00"))
        // 只有一个音源时连说话人都不必标：本来就只有他在说。
        XCTAssertFalse(single.spokenText().contains(ListeningSource.microphone.title))
        // 存到本地的那份仍然带完整时间戳。
        XCTAssertTrue(single.text.contains("[00:00:00–00:00:02]"))

        var both = transcript()
        both.upsert(segment(source: .microphone, start: 0, end: 2, text: "我们下周一给结论"))
        both.upsert(segment(source: .application, start: 2, end: 4, text: "好，那就这么定"))
        both.upsert(segment(source: .application, start: 4, end: 6, text: "我记一下", final: false))
        let turns = both.spokenText().components(separatedBy: "\n")
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0], "\(ListeningSource.microphone.title): 我们下周一给结论")
        XCTAssertTrue(turns[1].hasPrefix("\(ListeningSource.application.title): 好，那就这么定 我记一下"))
        // 临时标记按段落标一次，不是每一批都标。
        let mark = String(localized: "（末尾是临时文字，可能还会修正）")
        XCTAssertEqual(both.spokenText().components(separatedBy: mark).count - 1, 1)
    }

    func testTranscriptRejectsOversizedRevisionWithoutChangingSavedText() {
        var transcript = transcript()
        let part = segment(start: 0, end: 1, text: "preserved", final: false)
        XCTAssertTrue(transcript.upsert(part))
        XCTAssertFalse(transcript.upsert(segment(id: part.id, start: 0, end: 2,
            text: String(repeating: "x", count: ListeningTranscript.maximumCharacters + 1))))
        XCTAssertEqual(transcript.segments, [part])
        // One grapheme can contain many combining marks: character limits alone are insufficient.
        let pathological = "a" + String(repeating: "\u{0301}", count: 1_000_001)
        XCTAssertEqual(pathological.count, 1)
        XCTAssertFalse(transcript.upsert(segment(start: 2, end: 3, text: pathological)))
        XCTAssertEqual(transcript.segments, [part])
        transcript.segments = (0..<ListeningTranscript.maximumSegments).map {
            segment(start: Double($0), end: Double($0 + 1), text: "x")
        }
        XCTAssertFalse(transcript.upsert(segment(start: 9999, end: 10000, text: "too many")))
    }

    func testStorageAdmissionReservesSpaceAndNeverDeletesOldRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.caf")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        // Sparse file measures logical storage without allocating gigabytes in the test.
        let size = ListeningStorageBudget.maximumBytes - ListeningStorageBudget.audioReservation + 1
        try handle.truncate(atOffset: UInt64(size))
        XCTAssertThrowsError(try ListeningStorageBudget.validate(root: root, savesAudio: true))
        XCTAssertNoThrow(try ListeningStorageBudget.validate(root: root, savesAudio: false))
        XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(size))
        try handle.truncate(atOffset: 0)
        for _ in 0..<ListeningStorageBudget.maximumSessions {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        }
        XCTAssertThrowsError(try ListeningStorageBudget.validate(root: root, savesAudio: false))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 101)
    }

    func testListeningModesKeepMicrophoneOptInAndSourcesSeparate() {
        XCTAssertEqual(ListeningPreferences().mode, .application)
        XCTAssertEqual(ListeningMode.application.sources, [.application])
        XCTAssertEqual(ListeningMode.microphone.sources, [.microphone])
        XCTAssertEqual(Set(ListeningMode.both.sources), Set([.microphone, .application]))
    }

    func testListeningPreferencesPersistAndRejectUnsupportedSavedLocale() throws {
        let suite = "wisp-listening-settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ListeningPreferences.load(from: defaults), ListeningPreferences())
        var preferences = ListeningPreferences(mode: .both, locale: "zh-CN", savesAudio: true)
        preferences.save(to: defaults)
        XCTAssertEqual(ListeningPreferences.load(from: defaults), preferences)
        preferences.locale = "invalid-language"
        preferences.save(to: defaults)
        XCTAssertEqual(ListeningPreferences.load(from: defaults).locale, "en-US")
        defaults.set(Data("broken".utf8), forKey: ListeningPreferences.key)
        XCTAssertEqual(ListeningPreferences.load(from: defaults), ListeningPreferences())
    }

    func testFocusedCleanupRemovesOnlyListeningAndIsSafeToRepeat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("Listening/session")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = root.appendingPathComponent("conversations.json")
        try Data("keep chat".utf8).write(to: chat)
        try Data("fixture speech".utf8).write(to: sessions.appendingPathComponent("transcript.txt"))
        try Data([0, 1, 2]).write(to: sessions.appendingPathComponent("microphone.caf"))
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("link"), withDestinationURL: chat)
        try ListeningStorageBudget.clearRecords(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Listening").path))
        XCTAssertEqual(try Data(contentsOf: chat), Data("keep chat".utf8))
        XCTAssertNoThrow(try ListeningStorageBudget.clearRecords(in: root))
        XCTAssertNoThrow(try ListeningStorageBudget.validate(root: root.appendingPathComponent("Listening"), savesAudio: true))
    }

    func testDraftBudgetTrimsWholeTurnsFromTheOldestEnd() {
        var transcript = transcript()
        for index in 0..<10 {
            transcript.upsert(segment(source: index.isMultiple(of: 2) ? .application : .microphone,
                                      start: Double(index * 4), end: Double(index * 4 + 4),
                                      text: "第\(index)段会议内容"))
        }
        XCTAssertEqual(transcript.spokenText().components(separatedBy: "\n").count, 10)
        let trimmed = transcript.spokenText(characterLimit: 60)
        XCTAssertFalse(trimmed.isEmpty)
        XCTAssertLessThanOrEqual(trimmed.count, 60)
        for line in trimmed.components(separatedBy: "\n") {
            XCTAssertTrue(line.contains(": 第"), "整轮发言一起丢，不能切出半句话：\(line)")
        }
        XCTAssertTrue(trimmed.contains("第9段"))
        XCTAssertFalse(trimmed.contains("第0段"))
    }

    /// 一场半小时的会议一次没按过分析，停止时能交出去多少：按比日常更快的语速算，
    /// 12,000 字的预算大约装得下最后二十分钟，更早的部分整段丢，且丢的是最旧的。
    func testAWholeMeetingIsCarriedUpToTheDraftBudget() {
        var transcript = transcript()
        // 每 4 秒一批、每批 20 字 ≈ 每秒 5 字，快于日常语速；录满一小时。
        let batch = String(repeating: "会议内容记录要点", count: 2) + "结论待办"
        XCTAssertEqual(batch.count, 20)
        for index in 0..<900 {
            transcript.upsert(segment(start: Double(index * 4), end: Double(index * 4 + 4),
                                      text: "第\(index)句" + batch))
        }
        let whole = transcript.spokenText()
        XCTAssertLessThanOrEqual(whole.count, ListeningTranscript.draftLimit)
        // 一个人连着说，出来是连贯的一段，不是四百多行碎片。
        XCTAssertFalse(whole.contains("\n"))
        // 丢的是开头，留的是最近说的。
        XCTAssertFalse(whole.contains("第0句"))
        XCTAssertTrue(whole.contains("第899句"))
        // 丢的边界落在一句话的开头，不是把某句从中间切开。
        XCTAssertTrue(whole.hasPrefix("第"), "裁剪不能切出半句话：\(whole.prefix(20))")
        let minutes = Double(transcript.segments.count * 4) / 60
        let carried = Double(whole.count) / Double(transcript.spokenText(characterLimit: .max).count)
        let attachment = XCTAttachment(string: "\(Int(minutes)) min at 5 chars/s → "
            + "\(transcript.spokenText(characterLimit: .max).count) chars spoken, "
            + "\(whole.count) carried (\(Int(carried * 100))%), budget=\(ListeningTranscript.draftLimit)")
        attachment.name = "draft budget measurement"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 一小时会议一次交出去时，放不下的开头不能悄悄消失：草稿开头写明丢了哪一段，
    /// 而且那一段算「已交」——否则下一次分析会把它当最新内容再发一次，顺序全乱。
    func testOverBudgetDraftDeclaresTheOmittedSpanAndConsumesIt() throws {
        var transcript = transcript()
        let batch = String(repeating: "会议内容记录要点", count: 2) + "结论待办"
        for index in 0..<900 {
            transcript.upsert(segment(start: Double(index * 4), end: Double(index * 4 + 4),
                                      text: "第\(index)句" + batch))
        }
        let draft = transcript.unstagedDraft(excluding: [])
        XCTAssertLessThanOrEqual(draft.text.count, ListeningTranscript.draftLimit)
        let firstLine = draft.text.components(separatedBy: "\n").first ?? ""
        let lastOmitted = try XCTUnwrap(transcript.segments.last { !draft.text.contains($0.text) })
        XCTAssertEqual(firstLine, ListeningTranscript.omissionNotice(from: 0, to: lastOmitted.end))
        XCTAssertTrue(draft.text.contains("第899句"))
        XCTAssertFalse(draft.text.contains("第0句"))
        XCTAssertEqual(draft.consumed, Set(transcript.segments.map(\.id)))
        XCTAssertEqual(transcript.unstagedDraft(excluding: draft.consumed).text, "")
        XCTAssertFalse(transcript.hasUnstagedText(excluding: draft.consumed))
    }

    func testDraftWithinBudgetCarriesNoOmissionNotice() {
        var transcript = transcript()
        transcript.upsert(segment(start: 0, end: 4, text: "一句话"))
        XCTAssertEqual(transcript.unstagedDraft(excluding: []).text, "一句话")
    }

    func testClippedSingleSegmentGetsAnOmissionNoticeWithinTheBudget() {
        var transcript = transcript()
        let tail = segment(start: 3_601, end: 3_605,
                           text: String(repeating: "x", count: 500) + " final words")
        transcript.upsert(tail)

        let draft = transcript.unstagedDraft(excluding: [], characterLimit: 256)
        XCTAssertLessThanOrEqual(draft.text.count, 256)
        XCTAssertTrue(draft.text.hasPrefix(ListeningTranscript.omissionNotice(from: tail.start, to: tail.end)))
        XCTAssertTrue(draft.text.hasSuffix("final words"))
        XCTAssertEqual(draft.consumed, [tail.id])
    }

    /// 「现在分析」时最后一批往往还是临时文字。它进草稿（带临时标记），但不能记成已交：
    /// 定稿后的文字要在下一次交出去，不能因为同一个 id 被排除而永远丢掉。
    func testProvisionalSegmentStaysPendingUntilItsFinalTextIsSent() {
        var transcript = transcript()
        let settled = segment(start: 0, end: 4, text: "已经定稿的一句")
        let tailID = UUID()
        transcript.upsert(settled)
        transcript.upsert(segment(id: tailID, start: 4, end: 8, text: "还在识别", final: false))
        let first = transcript.unstagedDraft(excluding: [])
        XCTAssertTrue(first.text.contains("还在识别"))
        XCTAssertEqual(first.consumed, [settled.id])
        transcript.upsert(segment(id: tailID, start: 4, end: 8, text: "还在识别的最终说法"))
        XCTAssertTrue(transcript.hasUnstagedText(excluding: first.consumed))
        let second = transcript.unstagedDraft(excluding: first.consumed)
        XCTAssertEqual(second.text, "还在识别的最终说法")
        XCTAssertEqual(second.consumed, [tailID])
    }

    func testPendingPredicateAgreesWithTheTextThatWouldBeSent() {
        var transcript = transcript()
        let first = segment(start: 0, end: 4, text: "第一句")
        let second = segment(start: 300, end: 304, text: "很久以后的第二句")
        transcript.upsert(first)
        XCTAssertTrue(transcript.hasUnstagedText(excluding: []))
        XCTAssertFalse(transcript.hasUnstagedText(excluding: [first.id]))
        XCTAssertEqual(transcript.unstagedDraft(excluding: [first.id]).text, "")
        transcript.upsert(second)
        // 交出去过的那段之外还剩内容：按钮亮着，取到的文字也确实非空。
        XCTAssertTrue(transcript.hasUnstagedText(excluding: [first.id]))
        XCTAssertFalse(transcript.unstagedDraft(excluding: [first.id]).text.isEmpty)
        XCTAssertFalse(transcript.hasUnstagedText(excluding: [first.id, second.id]))
        XCTAssertEqual(transcript.unstagedDraft(excluding: [first.id, second.id]).text, "")
    }
}
