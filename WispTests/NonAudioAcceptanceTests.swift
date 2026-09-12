import AppKit
import SwiftUI
import XCTest
@testable import Wisp

@MainActor
final class NonAudioAcceptanceTests: XCTestCase {
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

    func testConversationCreateStreamReloadSelectAndDelete() throws {
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

    func testConversationLimitsRequireExplicitEviction() throws {
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

    func testNewerConversationFormatIsPreservedUntilExplicitArchive() throws {
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

    func testCorruptHistoryIsBackedUpAndSurvivingMessagesRemainReadable() throws {
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

    func testComposerTypingSelectionSubmitAndEscapeKeepArrowArtwork() throws {
        WispCursorPolicy.setEnabled(true)
        defer { WispCursorPolicy.setEnabled(false) }
        let text = PlaceholderTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 90))
        text.isRichText = false
        let window = NSWindow(contentRect: text.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = text
        defer { window.close() }
        window.makeFirstResponder(text)
        var submits = 0, escapes = 0
        text.onSubmit = { submits += 1 }
        text.onEscape = { escapes += 1 }
        text.insertText("Synthetic input", replacementRange: NSRange(location: 0, length: 0))
        text.setSelectedRange(NSRange(location: 0, length: 9))
        XCTAssertEqual(text.selectedRange().length, 9)
        NSCursor.iBeam.set()
        text.resetCursorRects()
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .cursorUpdate, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        text.cursorUpdate(with: event)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submits, 1)
        XCTAssertEqual(text.string, "Synthetic input")
        text.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(escapes, 1)
    }

    func testRepeatedCursorSessionsReleaseWindowsAndDoNotAccumulateHideCounts() {
        class ProtectedWindow: NSWindow, CursorSharingSurface {
            var cursorSharingType: NSWindow.SharingType { .none }
        }
        let window = ProtectedWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.orderFront(nil)
        var hides = 0, shows = 0
        let controller = LocalCursorController(hideCursor: { hides += 1 }, showCursor: { shows += 1 })
        defer { controller.stop(); window.close() }
        let point = window.convertPoint(toScreen: NSPoint(x: 60, y: 60))
        for _ in 0..<50 {
            controller.setEnabled(true)
            controller.update(window: window, screenPoint: point, applicationActive: true)
            XCTAssertTrue(controller.localWindow.isVisible)
            controller.setEnabled(false)
            XCTAssertFalse(controller.localWindow.isVisible)
            XCTAssertNil(controller.localWindow.parent)
        }
        XCTAssertEqual(hides, shows)
        controller.refresh()
        XCTAssertFalse(controller.isReplacingCursor)
    }

    func testNonAudioSettingsTabsRenderAtTheirActualWindowSize() throws {
        let saved = UserDefaults.standard.object(forKey: "settingsTab")
        defer { UserDefaults.standard.set(saved, forKey: "settingsTab") }
        for tab in ["model", "panel", "commands", "capture", "privacy", "data", "general"] {
            UserDefaults.standard.set(tab, forKey: "settingsTab")
            try render(SettingsView().environmentObject(AssistantModel.shared)
                .environmentObject(ConversationStore.shared),
                       name: "settings-\(tab)", size: NSSize(width: 620, height: 520))
        }
    }

    func testDismissBeforePresentationCompletesDoesNotReopenOrRunAction() async {
        let settings = AppSettings.shared
        let model = AssistantModel.shared
        let saved = (settings.sendScreenshot, settings.responseMode, settings.panelFrame,
                     model.isCollapsed, model.ownWindowIDs, model.targetApp)
        let controller = PanelController()
        defer {
            controller.hide()
            settings.sendScreenshot = saved.0; settings.responseMode = saved.1
            settings.panelFrame = saved.2; model.setCollapsedSilently(saved.3)
            model.ownWindowIDs = saved.4; model.targetApp = saved.5
        }
        settings.sendScreenshot = false; settings.responseMode = .quick
        var actions = 0
        controller.show { actions += 1 }
        controller.hide()
        // captureShot returns without capture in this mode. The queued show task
        // still runs after hide, reproducing the race without reading the desktop.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(actions, 0)
    }

    func testChatEmptyAnswerStreamingErrorAndHistoryRenderWithoutAudio() throws {
        try withStore { store, _, _ in
            let model = AssistantModel.shared
            let saved = (model.packet, model.input, model.isCollapsed, model.showsConversationList,
                         model.errorText, model.isStreaming)
            defer {
                model.packet = saved.0; model.input = saved.1
                model.setCollapsedSilently(saved.2); model.showsConversationList = saved.3
                model.errorText = saved.4; model.isStreaming = saved.5
            }
            model.packet = ContextPacket(appName: "Synthetic fixture", bundleID: "test.fixture")
            model.input = ""; model.showsConversationList = false
            model.errorText = nil; model.isStreaming = false
            model.setCollapsedSilently(false)
            @MainActor func draw(_ state: String) throws {
                for width: CGFloat in [380, 620] {
                    try render(ChatView().environmentObject(model).environmentObject(store),
                               name: "chat-\(state)-\(Int(width))", size: NSSize(width: width, height: 560))
                }
            }
            try draw("empty")
            let conversation = try XCTUnwrap(store.createNew())
            store.append(Message(role: .user, text: "Explain this synthetic example"), to: conversation.id)
            store.append(Message(role: .assistant, text: "## Result\n\nA **synthetic** answer.\n\n```swift\nlet answer = 42\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |", mode: .quick), to: conversation.id)
            try draw("answer")
            model.isStreaming = true
            try draw("streaming")
            model.isStreaming = false
            model.errorText = "Synthetic offline error — retry available"
            try draw("error")
            model.errorText = nil; model.showsConversationList = true
            try draw("history")
        }
    }

    private func render<V: View>(_ root: V, name: String, size: NSSize) throws {
        let view = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(view.bounds.size, size)
        let directory = URL(fileURLWithPath: "/private/tmp/wisp-nonaudio-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }
}
