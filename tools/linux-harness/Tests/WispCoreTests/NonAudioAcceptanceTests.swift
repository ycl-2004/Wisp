// Ported from WispTests/NonAudioAcceptanceTests.swift for the Linux harness.
// Kept: the 4 ConversationStore tests (subjects in the Foundation-only closure).
// Dropped (AppKit/SwiftUI subjects; still run on macOS CI): testChatEmptyAnswerStreamingErrorAndHistoryRenderWithoutAudio, testComposerTypingSelectionSubmitAndEscapeKeepArrowArtwork, testDismissBeforePresentationCompletesDoesNotReopenOrRunAction, testNonAudioSettingsTabsRenderAtTheirActualWindowSize, testRepeatedCursorSessionsReleaseWindowsAndDoNotAccumulateHideCounts.
// The private render() helper used only by the dropped tests went with them.
// @MainActor test bodies are bridged (see bridge below): corelibs-xctest discovery
// traps on @MainActor test methods. Assertions are byte-identical to the original.
// AppKit/SwiftUI imports dropped too. Everything kept is verbatim.
import XCTest
@testable import WispCore


final class NonAudioAcceptanceTests: XCTestCase {

    // swift-corelibs-xctest cannot discover @MainActor test methods (its
    // discovery cast traps the whole run), so the ported tests keep their
    // original @MainActor bodies as private impls and bridge into them.
    private static func bridge(_ body: @MainActor @escaping () throws -> Void) throws {
        // corelibs-xctest runs tests on the main thread, so the body can be
        // executed in place under an isolation assertion; a semaphore hop
        // would deadlock against the very executor it waits for.
        if Thread.isMainThread {
            try MainActor.assumeIsolated { try body() }
            return
        }
        final class Box { var error: Error? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            do { try body() } catch { box.error = error }
            sem.signal()
        }
        sem.wait()
        if let error = box.error { throw error }
    }

    func testConversationCreateStreamReloadSelectAndDelete() throws { try Self.bridge { try self.impl_testConversationCreateStreamReloadSelectAndDelete() } }
    func testConversationLimitsRequireExplicitEviction() throws { try Self.bridge { try self.impl_testConversationLimitsRequireExplicitEviction() } }
    func testNewerConversationFormatIsPreservedUntilExplicitArchive() throws { try Self.bridge { try self.impl_testNewerConversationFormatIsPreservedUntilExplicitArchive() } }
    func testCorruptHistoryIsBackedUpAndSurvivingMessagesRemainReadable() throws { try Self.bridge { try self.impl_testCorruptHistoryIsBackedUpAndSurvivingMessagesRemainReadable() } }

    @MainActor
    private func withStore(_ body: (ConversationStore, URL, AppSettings) throws -> Void) throws {
        let suite = "wisp-acceptance-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults)
        let file = directory.appendingPathComponent("conversations.json")
        try body(ConversationStore(fileURL: file, settings: settings), file, settings)
    }

    @MainActor
    private func impl_testConversationCreateStreamReloadSelectAndDelete() throws {
        try withStore { store, file, settings in
            let first = try XCTUnwrap(store.createNew())
            let question = Message(role: .user, text: "Synthetic acceptance question")
            let answer = Message(role: .assistant, text: "", mode: .quick)
            store.append(question, to: first.id)
            store.append(answer, to: first.id)
            let beforeStream = try Data(contentsOf: file)
            store.updateStreaming(text: "First chunk", messageID: answer.id, in: first.id)
            XCTAssertEqual(try Data(contentsOf: file), beforeStream, "Each streaming delta must not write the history file")
            store.updateStreaming(text: "First chunk and final answer", messageID: answer.id, in: first.id, persistNow: true)
            let second = try XCTUnwrap(store.createNew())
            store.select(first.id)
            let loaded = ConversationStore(fileURL: file, settings: settings)
            XCTAssertEqual(loaded.activeID, first.id)
            XCTAssertEqual(loaded.active?.title, question.text)
            XCTAssertEqual(loaded.active?.messages.last?.text, "First chunk and final answer")
            XCTAssertEqual(loaded.active?.messages.last?.mode, .quick)
            loaded.removeMessage(answer.id, from: first.id)
            XCTAssertEqual(loaded.active?.messages.count, 1)
            loaded.delete(first.id)
            XCTAssertEqual(loaded.activeID, second.id)
            XCTAssertEqual(ConversationStore(fileURL: file, settings: settings).conversations.count, 1)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }

    @MainActor
    private func impl_testConversationLimitsRequireExplicitEviction() throws {
        try withStore { store, _, settings in
            settings.maxConversations = 2
            settings.maxUserTurns = 1
            let first = try XCTUnwrap(store.createNew())
            store.append(Message(role: .user, text: "First"), to: first.id)
            XCTAssertTrue(store.isAtTurnLimit(try XCTUnwrap(store.active)))
            let second = try XCTUnwrap(store.createNew())
            XCTAssertNil(store.createNew())
            XCTAssertEqual(Set(store.conversations.map(\.id)), [first.id, second.id])
            XCTAssertEqual(store.evictionCandidate?.id, first.id)
            let replacement = try XCTUnwrap(store.createNewEvictingOldest())
            XCTAssertEqual(Set(store.conversations.map(\.id)), [replacement.id, second.id])
        }
    }

    @MainActor
    private func impl_testNewerConversationFormatIsPreservedUntilExplicitArchive() throws {
        try withStore { _, file, settings in
            let future = Data(#"{"version":999,"futureSecret":"synthetic","conversations":[]}"#.utf8)
            try future.write(to: file)
            let store = ConversationStore(fileURL: file, settings: settings)
            XCTAssertTrue(store.isReadOnly)
            _ = store.createNew()
            store.flush()
            XCTAssertEqual(try Data(contentsOf: file), future)
            let backup = try XCTUnwrap(store.archiveBlockingFileAndReset())
            XCTAssertEqual(try Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(backup)), future)
            XCTAssertFalse(store.isReadOnly)
            XCTAssertTrue(store.conversations.isEmpty)
            XCTAssertNotNil(store.createNew())
            XCTAssertEqual(ConversationStore(fileURL: file, settings: settings).conversations.count, 1)
        }
    }

    @MainActor
    private func impl_testCorruptHistoryIsBackedUpAndSurvivingMessagesRemainReadable() throws {
        try withStore { _, file, settings in
            let corrupt = Data("not valid JSON".utf8)
            try corrupt.write(to: file)
            let store = ConversationStore(fileURL: file, settings: settings)
            guard case .recovered(let backup) = store.loadIssue else { return XCTFail("Corrupt history must report its recovery") }
            XCTAssertEqual(try Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(backup)), corrupt)
            XCTAssertTrue(store.conversations.isEmpty)
            let partial = Data(#"{"version":1,"conversations":[{"messages":[{"role":"user","text":"kept"},{"role":"unknown","text":"bad"},{"role":"assistant","text":"also kept"}]}]}"#.utf8)
            try partial.write(to: file)
            let recovered = ConversationStore(fileURL: file, settings: settings)
            XCTAssertEqual(recovered.active?.messages.map(\.text), ["kept", "also kept"])
            XCTAssertNil(recovered.loadIssue)
        }
    }











}
