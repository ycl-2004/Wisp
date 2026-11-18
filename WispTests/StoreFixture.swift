import XCTest
@testable import Wisp

/// A ConversationStore over a throwaway defaults suite and directory, both
/// removed when `body` returns. `prewritten` seeds conversations.json first,
/// for the load-path tests. One definition for every store test file.
@MainActor
func withStore(prewritten: Data? = nil,
               _ body: (ConversationStore, URL, AppSettings) throws -> Void) throws {
    let suite = "wisp-store-" + UUID().uuidString
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
