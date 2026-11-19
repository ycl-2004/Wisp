import XCTest
@testable import Wisp

final class CaptionBufferTests: XCTestCase {
    private func piece(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> CaptionPiece {
        CaptionPiece(text: text, start: start, end: end)
    }

    /// A new guess replaces the last one; committed words replace the guess they settle.
    func testGuessesReplaceEachOtherAndCommittedWordsSettleThem() {
        var buffer = CaptionBuffer()
        buffer.apply(.volatile(piece("你能说", 0, 1)))
        buffer.apply(.volatile(piece("你能说一下", 0, 1.4)))
        XCTAssertEqual(buffer.text, "你能说一下")
        buffer.apply(.committed([piece("你", 0, 0.2), piece("能", 0.2, 0.4), piece("说", 0.4, 0.6),
                                 piece("一", 0.6, 0.8), piece("下", 0.8, 1.0)]))
        XCTAssertEqual(buffer.text, "你能说一下")
        XCTAssertNil(buffer.volatile)
        buffer.apply(.volatile(piece(" API 吗", 1.0, 2.0)))
        XCTAssertEqual(buffer.text, "你能说一下 API 吗")
        buffer.apply(.volatile(nil))
        XCTAssertEqual(buffer.text, "你能说一下")
    }

    /// A window counts back from the latest word, cuts between committed words, and always includes
    /// the guess still being revised.
    func testWindowCutsAtWordsAndCountsBackFromTheLatestWord() {
        var buffer = CaptionBuffer()
        buffer.apply(.committed([piece("好的，", 0, 1), piece("我们下周再说。", 1, 3)]))
        buffer.apply(.committed([piece("RAG", 20, 20.5), piece(" 是什么？", 20.5, 21)]))
        buffer.apply(.volatile(piece("还有", 21, 22)))
        XCTAssertEqual(buffer.text(lastSeconds: 5), "RAG 是什么？还有")
        XCTAssertEqual(buffer.text(lastSeconds: 1.2), "是什么？还有")
        XCTAssertEqual(buffer.text(lastSeconds: 30), "好的，我们下周再说。RAG 是什么？还有")
        XCTAssertEqual(buffer.text(lastSeconds: 0), "")
        // A long silence does not empty the window: the last thing said is still the question.
        var quiet = CaptionBuffer()
        quiet.apply(.committed([piece("这个 folder 是怎么组织的？", 100, 103)]))
        XCTAssertEqual(quiet.text(lastSeconds: 10), "这个 folder 是怎么组织的？")
    }

    /// Nothing older than the longest window is kept.
    func testBufferKeepsOnlyTheLastHalfMinute() {
        var buffer = CaptionBuffer()
        for second in 0..<120 {
            buffer.apply(.committed([piece("字", TimeInterval(second), TimeInterval(second) + 0.9)]))
        }
        XCTAssertLessThanOrEqual(buffer.committed.count, Int(CaptionBuffer.retention) + 1)
        XCTAssertGreaterThanOrEqual(buffer.committed.first?.end ?? 0, buffer.latestEnd - CaptionBuffer.retention)
        // Push-to-talk keeps its whole question.
        var question = CaptionBuffer(retention: .infinity)
        for second in 0..<60 {
            question.apply(.committed([piece("问", TimeInterval(second), TimeInterval(second) + 0.9)]))
        }
        XCTAssertEqual(question.committed.count, 60)
    }

    /// Both recognizers put the space before an English word into the word itself.
    func testJoiningKeepsTheRecognizersOwnSpacing() {
        XCTAssertEqual(CaptionBuffer.join(["这个", " folder", "里面"]), "这个 folder里面")
        XCTAssertEqual(CaptionBuffer.join(["trans", "cribe"]), "transcribe")
        XCTAssertEqual(CaptionBuffer.join([" RAG", " 是什么"]), "RAG 是什么")
        XCTAssertEqual(CaptionBuffer.join([]), "")
    }

    func testQuestionDetectionLooksForTheQuestionMarkRecognizersAdd() {
        XCTAssertTrue(CaptionBuffer.endsWithQuestion("RAG 是什么？"))
        XCTAssertTrue(CaptionBuffer.endsWithQuestion("How does it work? "))
        XCTAssertFalse(CaptionBuffer.endsWithQuestion("我们下周再说。"))
        XCTAssertFalse(CaptionBuffer.endsWithQuestion(""))
    }

    func testBlankUpdatesLeaveNothingBehind() {
        var buffer = CaptionBuffer()
        buffer.apply(.committed([piece("  ", 0, 1)]))
        buffer.apply(.volatile(piece(" ", 1, 2)))
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.text, "")
    }

    // MARK: - Preferences

    /// A setting saved by an older Wisp (a local model as the engine, keys of removed features)
    /// costs only that field: the language survives.
    func testPreferencesFromOlderVersionsKeepWhatStillApplies() throws {
        let suite = "wisp-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"mode":"both","locale":"en-US","savesAudio":true,"chineseScript":"traditional","recognitionEngine":"local:k2-fsa/sense-voice","senseVoiceLanguage":"yue","applicationBundleID":"us.zoom.xos"}"#.utf8),
                     forKey: ListeningPreferences.key)
        var preferences = ListeningPreferences.load(from: defaults)
        XCTAssertEqual(preferences.locale, "en-US")
        XCTAssertNil(preferences.recognitionEngine)
        XCTAssertNil(preferences.autoAnswer)

        preferences.recognitionEngine = .soniox
        preferences.autoAnswer = true
        preferences.save(to: defaults)
        XCTAssertEqual(ListeningPreferences.load(from: defaults), preferences)
        XCTAssertEqual(ListeningPreferences.load(from: try XCTUnwrap(UserDefaults(suiteName: suite + "-empty"))).locale,
                       "zh-CN", "captions default to Chinese")
    }

    // MARK: - In-memory conversations

    /// The caption conversation holds the other side's words: it is never written, never becomes
    /// the conversation restored at launch, and does not count against the limit.
    func testCaptionConversationIsNeverWrittenToDisk() throws {
        try onMainActor { try self.captionConversationIsNeverWrittenToDisk() }
    }

    @MainActor
    private func captionConversationIsNeverWrittenToDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("conversations.json")
        let suite = "wisp-ephemeral-\(UUID().uuidString)"
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        settings.maxConversations = 1

        let store = ConversationStore(fileURL: file, settings: settings)
        let saved = try XCTUnwrap(store.createNew())
        store.append(Message(role: .user, text: "saved question"), to: saved.id)
        XCTAssertFalse(store.canCreateNew)

        let caption = store.activateEphemeral(title: "会议提问（不保存）")
        XCTAssertEqual(store.activateEphemeral(title: "again").id, caption.id, "one caption conversation at a time")
        store.append(Message(role: .user, text: "对方刚才说的话：「RAG 是什么？」"), to: caption.id)
        store.select(caption.id)
        XCTAssertEqual(settings.lastActiveConversationID, saved.id.uuidString)
        XCTAssertEqual(store.savedCount, 1)
        XCTAssertTrue(store.evictionCandidates.allSatisfy { $0.id != caption.id })

        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(written.contains("saved question"))
        XCTAssertFalse(written.contains("RAG"))
        XCTAssertFalse(written.contains(caption.id.uuidString))

        store.discardEphemeral()
        XCTAssertEqual(store.activeID, saved.id)
        XCTAssertEqual(store.conversations.map(\.id), [saved.id])
    }
}
