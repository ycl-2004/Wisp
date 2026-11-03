import XCTest
@testable import Wisp

/// Audit issue #53: CLI scratch directories orphaned by a force-quit can
/// contain captured screenshots. `sweepOrphans` runs at launch and must
/// remove exactly the stale Wisp-prefixed directories — nothing fresh,
/// nothing foreign, nothing that is a file.
final class CLITempSweepTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WispSweepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEntry(_ name: String, ageHours: Double, isDirectory: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: isDirectory)
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            // Give the directory content, like a real orphaned request dir.
            try Data("screenshot".utf8).write(to: url.appendingPathComponent("shot.png"))
        } else {
            try Data("x".utf8).write(to: url)
        }
        let mtime = now.addingTimeInterval(-ageHours * 3600)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testRemovesOldDirectoriesOfAllThreeProviders() throws {
        let claude = try makeEntry("Wisp-claude-AAAA", ageHours: 25)
        let codex = try makeEntry("Wisp-codex-BBBB", ageHours: 72)
        let agy = try makeEntry("Wisp-agy-CCCC", ageHours: 24.5)
        let removed = CLITemporaryDirectory.sweepOrphans(now: now, in: root)
        XCTAssertEqual(removed, 3)
        XCTAssertFalse(exists(claude)); XCTAssertFalse(exists(codex)); XCTAssertFalse(exists(agy))
    }

    func testKeepsFreshDirectoriesEvenWithKnownPrefixes() throws {
        let fresh = try makeEntry("Wisp-claude-LIVE", ageHours: 1)
        let borderline = try makeEntry("Wisp-codex-EDGE", ageHours: 23.9)
        let removed = CLITemporaryDirectory.sweepOrphans(now: now, in: root)
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(exists(fresh)); XCTAssertTrue(exists(borderline))
    }

    func testKeepsForeignAndNonDirectoryEntries() throws {
        let foreign = try makeEntry("OtherApp-scratch", ageHours: 100)
        let unknownWisp = try makeEntry("Wisp-notes-DDDD", ageHours: 100)
        let file = try makeEntry("Wisp-claude-FILE", ageHours: 100, isDirectory: false)
        let removed = CLITemporaryDirectory.sweepOrphans(now: now, in: root)
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(exists(foreign)); XCTAssertTrue(exists(unknownWisp)); XCTAssertTrue(exists(file))
    }

    func testMissingDirectoryIsNotAnError() {
        let gone = root.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(CLITemporaryDirectory.sweepOrphans(now: now, in: gone), 0)
    }
}
