import XCTest
@testable import Wisp

/// Audit round 4: ConversationStore guard rails — the version probe's
/// typing (#34), load/persist failure surfaces (#35), and duplicate-ID
/// handling (#49). These pin the store's "never silently lose or
/// overwrite the user's only copy" contract at the variants the
/// round-2/round-4 matrices did not reach.
///
/// This is the macOS original; the Linux harness port runs the same
/// bodies behind a @MainActor bridge.
@MainActor
final class Round4StoreGuardTests: XCTestCase {

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
    func testStringVersionBlocksPersistence() throws {
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
    func testFractionalVersionBlocksPersistence() throws {
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
    func testNegativeVersionBlocksPersistence() throws {
        let raw = Data(#"{"version":-1,"conversations":[]}"#.utf8)
        try withStore(prewritten: raw) { store, _, _ in
            XCTAssertTrue(store.isReadOnly)
            guard case .unreadableVersion = store.loadIssue else {
                return XCTFail("negative version must block as unreadable, got \(String(describing: store.loadIssue))")
            }
        }
    }

    @MainActor
    func testMissingVersionStillLoadsAsV1() throws {
        // Files written before versioning existed carry no version key;
        // the tolerant full decode treats them as v1. That must keep
        // working — only a *present* but unreadable version blocks.
        try withStore(prewritten: Data(#"{"conversations":[]}"#.utf8)) { store, _, _ in
            XCTAssertFalse(store.isReadOnly)
            XCTAssertNil(store.loadIssue)
        }
    }
}
