import AppKit
import KeyboardShortcuts
import SwiftUI
import XCTest
@testable import Wisp

final class QuickCommandTests: XCTestCase {
    @MainActor
    func testCommandsSeedPersistAndRestore() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "wisp-commands-" + UUID().uuidString))
        let store = QuickCommandStore(defaults: defaults)
        XCTAssertEqual(store.commands.map(\.title), QuickCommand.defaults.map(\.title))
        XCTAssertEqual(store.commands.map(\.mode), [.quick, .quick, .deep, .quick, .deep, nil])
        XCTAssertEqual(store.commands.map(\.attachedSeconds), [10, 30, 0, 0, 0, 0])
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

    func testShortcutNamesAvoidTheDotKeyboardShortcutsReserves() {
        XCTAssertFalse(QuickCommand(title: "Translate", prompt: "Ask").shortcutName.rawValue.contains("."))
    }

    @MainActor
    func testLegacyDottedShortcutMovesToTheCurrentName() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "wisp-commands-migration-" + UUID().uuidString))
        let command = QuickCommand(title: "Translate", prompt: "Ask")
        let recorded = KeyboardShortcuts.Shortcut(.t, modifiers: [.control, .option, .command])
        KeyboardShortcuts.setShortcut(recorded, for: command.legacyShortcutName)
        defaults.set(try JSONEncoder().encode([command]), forKey: QuickCommandStore.key)
        defer {
            KeyboardShortcuts.setShortcut(nil, for: command.shortcutName)
            KeyboardShortcuts.setShortcut(nil, for: command.legacyShortcutName)
        }

        _ = QuickCommandStore(defaults: defaults)
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: command.shortcutName), recorded)
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: command.legacyShortcutName))
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

    // MARK: - Caption commands

    func testCaptionQuestionQuotesTheWordsAfterTheQuestionAndAnyDraft() {
        let command = QuickCommand.captionDefaults[0]
        XCTAssertEqual(command.attachedSeconds, 10)
        XCTAssertEqual(command.includesScreenshot, false)
        XCTAssertEqual(command.mode, .quick)
        let question = command.question(withCaptions: "RAG 是什么？", draft: "用中文回答")
        XCTAssertTrue(question.hasPrefix(command.prompt + "\n\n用中文回答\n\n"))
        XCTAssertTrue(question.hasSuffix("「RAG 是什么？」"))
        let screen = QuickCommand.captionDefaults[1]
        XCTAssertEqual(screen.attachedSeconds, 30)
        XCTAssertEqual(screen.includesScreenshot, true)
    }

    func testAttachedSecondsStayWithinTheBuffer() {
        var command = QuickCommand(title: "x", prompt: "y")
        XCTAssertEqual(command.attachedSeconds, 0)
        command.transcriptSeconds = 300
        XCTAssertEqual(command.attachedSeconds, Int(CaptionBuffer.retention))
        command.transcriptSeconds = -5
        XCTAssertEqual(command.attachedSeconds, 0)
    }

    /// Commands saved before captions existed decode unchanged and get the two caption commands
    /// once, in front; a list that already has caption commands is left alone.
    @MainActor
    func testCaptionCommandsAreSeededOnceIntoOlderLists() throws {
        let suite = "wisp-caption-seed-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = [QuickCommand(title: "总结这一页", prompt: "总结", mode: .deep)]
        defaults.set(try JSONEncoder().encode(old), forKey: QuickCommandStore.key)

        let store = QuickCommandStore(defaults: defaults)
        XCTAssertEqual(store.commands.map(\.title), QuickCommand.captionDefaults.map(\.title) + ["总结这一页"])
        let saved = try JSONDecoder().decode([QuickCommand].self,
                                             from: try XCTUnwrap(defaults.data(forKey: QuickCommandStore.key)))
        XCTAssertEqual(saved.count, 3)

        // Deleting them is respected on the next launch.
        store.commands.removeFirst(2)
        XCTAssertEqual(QuickCommandStore(defaults: defaults).commands.map(\.title), ["总结这一页"])
    }

    @MainActor
    func testFirstLaunchGetsTheCaptionCommandsOnlyOnce() throws {
        let suite = "wisp-caption-first-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuickCommandStore(defaults: defaults)
        XCTAssertEqual(store.commands.filter { $0.attachedSeconds > 0 }.count, 2)
        XCTAssertEqual(store.commands.count, QuickCommand.defaults.count)
    }
}
