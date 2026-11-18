import XCTest
@testable import Wisp

/// Non-audio acceptance: the conversation store's user-visible contract
/// (create → stream → reload → select → delete, explicit eviction at the
/// limit, newer-format preservation, corrupt-history recovery). Split out of
/// NonAudioAcceptanceTests so the Foundation-only half also runs in the
/// Linux harness; the AppKit/SwiftUI half stays there. Entry points hop into
/// @MainActor bodies through `onMainActor` (MainActorBridge.swift).
final class ConversationAcceptanceTests: XCTestCase {
    func testConversationCreateStreamReloadSelectAndDelete() throws { try onMainActor { try self.impl_testConversationCreateStreamReloadSelectAndDelete() } }
    func testConversationLimitsRequireExplicitEviction() throws { try onMainActor { try self.impl_testConversationLimitsRequireExplicitEviction() } }
    func testNewerConversationFormatIsPreservedUntilExplicitArchive() throws { try onMainActor { try self.impl_testNewerConversationFormatIsPreservedUntilExplicitArchive() } }
    func testCorruptHistoryIsBackedUpAndSurvivingMessagesRemainReadable() throws { try onMainActor { try self.impl_testCorruptHistoryIsBackedUpAndSurvivingMessagesRemainReadable() } }

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
            XCTAssertEqual(store.evictionCandidates.first?.id, first.id)
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
