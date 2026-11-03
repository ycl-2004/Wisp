import XCTest
@testable import Wisp

/// Audit round 4, #48: QuickCommandStore.init decoded the stored blob
/// with try? and fell back to the seeded defaults on any failure —
/// indistinguishable from a first run. The user's own commands looked
/// "reset", and the first later edit overwrote the stored blob, so the
/// original data was gone for good. A failed decode now sets loadFailed,
/// suppresses saving, and only an explicit Restore Defaults clears it.
///
/// CI-pending: QuickCommandStore depends on KeyboardShortcuts and is
/// not part of the Linux harness surface.
@MainActor
final class Round4QuickCommandStoreTests: XCTestCase {

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "wisp-round4-qc-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testCorruptBlobIsNotOverwrittenUntilExplicitReset() throws {
        try withDefaults { defaults in
            let corrupt = Data("{\"not\":\"a command list\"}".utf8)
            defaults.set(corrupt, forKey: QuickCommandStore.key)
            let store = QuickCommandStore(defaults: defaults)
            XCTAssertTrue(store.loadFailed)
            XCTAssertEqual(store.commands.count, QuickCommand.defaults.count,
                           "the UI still shows the seeded defaults in memory")

            // Any edit routes through didSet -> save(); while loadFailed
            // the stored blob must survive untouched.
            store.commands = store.commands
            XCTAssertEqual(defaults.data(forKey: QuickCommandStore.key), corrupt)

            // The explicit escape: Restore Defaults discards and saves.
            store.restoreDefaults()
            XCTAssertFalse(store.loadFailed)
            let saved = try XCTUnwrap(defaults.data(forKey: QuickCommandStore.key))
            XCTAssertEqual(try JSONDecoder().decode([QuickCommand].self, from: saved).count,
                           QuickCommand.defaults.count)
        }
    }

    func testMissingKeySeedsDefaultsWithoutFailure() throws {
        try withDefaults { defaults in
            let store = QuickCommandStore(defaults: defaults)
            XCTAssertFalse(store.loadFailed)
            XCTAssertEqual(store.commands.count, QuickCommand.defaults.count)
        }
    }

    func testValidBlobLoads() throws {
        try withDefaults { defaults in
            let custom = [QuickCommand(title: "Mine", prompt: "Do the thing", mode: nil)]
            defaults.set(try JSONEncoder().encode(custom), forKey: QuickCommandStore.key)
            let store = QuickCommandStore(defaults: defaults)
            XCTAssertFalse(store.loadFailed)
            XCTAssertEqual(store.commands.map(\.title), ["Mine"])
        }
    }
}
