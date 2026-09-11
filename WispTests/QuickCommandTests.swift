import AppKit
import SwiftUI
import XCTest
@testable import Wisp

final class QuickCommandTests: XCTestCase {
    @MainActor
    func testCommandsSeedPersistAndRestore() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "wisp-commands-" + UUID().uuidString))
        let store = QuickCommandStore(defaults: defaults)
        XCTAssertEqual(store.commands.map(\.title), QuickCommand.defaults.map(\.title))
        XCTAssertEqual(store.commands.map(\.mode), [.deep, .quick, .deep, nil])
        XCTAssertTrue(store.commands.allSatisfy(\.isRunnable))

        let added = store.add()
        XCTAssertFalse(added.isRunnable, "a new command has nothing to ask yet")
        store.commands[store.commands.count - 1].prompt = "Fixture prompt"
        store.commands[store.commands.count - 1].mode = .quick
        store.commands.move(fromOffsets: IndexSet(integer: store.commands.count - 1), toOffset: 0)

        let reloaded = QuickCommandStore(defaults: defaults)
        XCTAssertEqual(reloaded.commands, store.commands)
        XCTAssertEqual(reloaded.commands.first?.prompt, "Fixture prompt")
        XCTAssertEqual(reloaded.commands.first?.symbol, ResponseMode.quick.symbol)

        store.delete(added.id)
        XCTAssertFalse(QuickCommandStore(defaults: defaults).commands.contains { $0.id == added.id })
        store.commands = []
        XCTAssertTrue(QuickCommandStore(defaults: defaults).commands.isEmpty, "deleting every command must stick")
        store.restoreDefaults()
        XCTAssertEqual(QuickCommandStore(defaults: defaults).commands.map(\.title), QuickCommand.defaults.map(\.title))
    }

    func testDraftBecomesTheMaterialACommandWorksOn() {
        let command = QuickCommand(title: "Translate", prompt: "Translate this.")
        XCTAssertEqual(command.question(withDraft: "  "), "Translate this.")
        XCTAssertEqual(command.question(withDraft: " Bonjour \n"), "Translate this.\n\nBonjour")
        XCTAssertEqual(command.symbol, "sparkles")
        XCTAssertNotEqual(command.shortcutName.rawValue, QuickCommand(title: "Other", prompt: "x").shortcutName.rawValue)
    }

    func testUnnamedCommandsRemainDiscoverable() {
        XCTAssertFalse(QuickCommand(title: " \n ", prompt: "Ask").displayTitle.isEmpty)
        XCTAssertEqual(QuickCommand(title: "  Translate  ", prompt: "Ask").displayTitle, "Translate")
    }

    @MainActor
    func testCommandSettingsRender() throws {
        let view = NSHostingView(rootView: QuickCommandSettingsView().frame(width: 620, height: 480)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/wisp-commands-settings.png"))
    }
}
