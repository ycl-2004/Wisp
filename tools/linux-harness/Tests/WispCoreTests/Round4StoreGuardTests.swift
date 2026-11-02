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
}
