import XCTest
@testable import WispCore

/// Audit round 4: ConversationStore guard rails — the version probe's
/// typing (#34), load/persist failure surfaces (#35), and duplicate-ID
/// handling (#49).
///
/// Harness-only port shape: @MainActor bodies run behind the bridge
/// (corelibs-xctest traps on @MainActor test discovery). The WispTests
/// mirror uses @MainActor directly.
final class Round4StoreGuardTests: XCTestCase {

    private static func bridge(_ body: @MainActor @escaping () throws -> Void) throws {
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

    func testStringVersionBlocksPersistence() throws { try Self.bridge { try self.impl_testStringVersionBlocksPersistence() } }
    func testFractionalVersionBlocksPersistence() throws { try Self.bridge { try self.impl_testFractionalVersionBlocksPersistence() } }
    func testNegativeVersionBlocksPersistence() throws { try Self.bridge { try self.impl_testNegativeVersionBlocksPersistence() } }
    func testMissingVersionStillLoadsAsV1() throws { try Self.bridge { try self.impl_testMissingVersionStillLoadsAsV1() } }
    func testPathOccupiedByDirectoryBlocksWithNotice() throws { try Self.bridge { try self.impl_testPathOccupiedByDirectoryBlocksWithNotice() } }
    func testPersistFailureSurfacesSaveIssueAndSuccessClearsIt() throws { try Self.bridge { try self.impl_testPersistFailureSurfacesSaveIssueAndSuccessClearsIt() } }

    @MainActor
    private func withStore(prewritten: Data? = nil,
                           _ body: (ConversationStore, URL, AppSettings) throws -> Void) throws {
        let suite = "wisp-round4-guard-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults)
        let file = directory.appendingPathComponent("conversations.json")
        if let prewritten { try prewritten.write(to: file) }
        try body(ConversationStore(fileURL: file, settings: settings), file, settings)
    }

    // MARK: - #34: a present-but-undecodable version must block, not load as v1

    @MainActor
    private func impl_testStringVersionBlocksPersistence() throws {
        let raw = Data(#"{"version":"2","conversations":[]}"#.utf8)
        try withStore(prewritten: raw) { store, file, _ in
            XCTAssertTrue(store.isReadOnly)
            guard case .unreadableVersion = store.loadIssue else {
                return XCTFail("string version must block as unreadable, got \(String(describing: store.loadIssue))")
            }
            _ = store.createNew()
            XCTAssertEqual(try Data(contentsOf: file), raw,
                           "a blocked store must never overwrite the file")
        }
    }

    @MainActor
    private func impl_testFractionalVersionBlocksPersistence() throws {
        let raw = Data(#"{"version":2.5,"conversations":[]}"#.utf8)
        try withStore(prewritten: raw) { store, file, _ in
            XCTAssertTrue(store.isReadOnly)
            guard case .unreadableVersion = store.loadIssue else {
                return XCTFail("fractional version must block as unreadable, got \(String(describing: store.loadIssue))")
            }
            store.flush()
            XCTAssertEqual(try Data(contentsOf: file), raw)
        }
    }

    @MainActor
    private func impl_testNegativeVersionBlocksPersistence() throws {
        let raw = Data(#"{"version":-1,"conversations":[]}"#.utf8)
        try withStore(prewritten: raw) { store, _, _ in
            XCTAssertTrue(store.isReadOnly)
            guard case .unreadableVersion = store.loadIssue else {
                return XCTFail("negative version must block as unreadable, got \(String(describing: store.loadIssue))")
            }
        }
    }

    @MainActor
    private func impl_testMissingVersionStillLoadsAsV1() throws {
        // Files written before versioning existed carry no version key;
        // the tolerant full decode treats them as v1. That must keep
        // working — only a *present* but unreadable version blocks.
        try withStore(prewritten: Data(#"{"conversations":[]}"#.utf8)) { store, _, _ in
            XCTAssertFalse(store.isReadOnly)
            XCTAssertNil(store.loadIssue)
        }
    }

    // MARK: - #35: load/persist failures must surface, never vanish

    @MainActor
    private func impl_testPathOccupiedByDirectoryBlocksWithNotice() throws {
        // conversations.json exists but is a directory: Data(contentsOf:)
        // fails, and every persist would fail too. Before #35 this was
        // indistinguishable from "no file yet" — empty store, no notice,
        // and a session of silent data loss.
        let suite = "wisp-round4-guard-dir-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults)
        let file = directory.appendingPathComponent("conversations.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let store = ConversationStore(fileURL: file, settings: settings)
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertTrue(store.isReadOnly)
        guard case .unreadable = store.loadIssue else {
            return XCTFail("occupied path must block as unreadable, got \(String(describing: store.loadIssue))")
        }
    }

    @MainActor
    private func impl_testPersistFailureSurfacesSaveIssueAndSuccessClearsIt() throws {
        // The store's directory is blocked by a regular file, so every
        // persist fails. Before #35 persist() swallowed all of it.
        let suite = "wisp-round4-guard-blocked-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults)
        let parent = directory.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: parent)
        let file = parent.appendingPathComponent("conversations.json")
        let store = ConversationStore(fileURL: file, settings: settings)
        XCTAssertNil(store.loadIssue)
        XCTAssertNotNil(store.createNew())
        XCTAssertNotNil(store.saveIssue, "a failed persist must be surfaced, not swallowed")
        XCTAssertEqual(store.conversations.count, 1, "in-memory work continues; only saving is broken")

        // Unblock: the next successful persist clears the notice.
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        XCTAssertNotNil(store.createNew())
        XCTAssertNil(store.saveIssue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - #45: eviction must never take the conversation being streamed into

    func testEvictionSkipsTheStreamingConversation() throws { try Self.bridge { try self.impl_testEvictionSkipsTheStreamingConversation() } }

    @MainActor
    private func impl_testEvictionSkipsTheStreamingConversation() throws {
        // A is time-oldest but mid-stream (stalled: no chunks arriving,
        // so its updatedAt is no longer being bumped). B and C carry
        // future updatedAts so the ordering survives the runtime clock.
        let now = Date()
        let placeholder = Message(role: .assistant, text: "")
        let a = Conversation(title: "A", createdAt: now.addingTimeInterval(-7_200),
                             updatedAt: now.addingTimeInterval(-7_200), messages: [placeholder])
        let b = Conversation(title: "B", createdAt: now, updatedAt: now.addingTimeInterval(3_600))
        let c = Conversation(title: "C", createdAt: now, updatedAt: now.addingTimeInterval(7_200))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ConversationFile(conversations: [a, b, c]))
        try withStore(prewritten: data) { store, _, settings in
            settings.maxConversations = 3
            XCTAssertEqual(store.evictionCandidate?.id, a.id, "sanity: A is the time-oldest")

            store.updateStreaming(text: "partial", messageID: placeholder.id, in: a.id, persistNow: false)
            XCTAssertEqual(store.evictionCandidate?.id, b.id,
                           "the streaming conversation must be exempt from eviction")

            store.updateStreaming(text: "partial", messageID: placeholder.id, in: a.id, persistNow: true)
            XCTAssertEqual(store.evictionCandidate?.id, a.id,
                           "the final (persistNow) update lifts the exemption")
        }
    }
}
