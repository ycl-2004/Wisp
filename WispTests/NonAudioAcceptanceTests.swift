import AppKit
import SwiftUI
import XCTest
@testable import Wisp

@MainActor
final class NonAudioAcceptanceTests: XCTestCase {
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
