import AppKit
import XCTest
@testable import Wisp

@MainActor
final class AuditFixes20261118Tests: XCTestCase {

    // MARK: - Arrow-only cursor policy

    func testArrowCursorPolicyLocksSetPushAndCursorRectsToArrow() {
        let wasEnabled = ArrowCursorPolicy.isEnabled
        defer { ArrowCursorPolicy.setEnabled(wasEnabled) }

        ArrowCursorPolicy.setEnabled(true)
        XCTAssertTrue(ArrowCursorPolicy.effectiveCursor(for: .iBeam) === NSCursor.arrow)
        XCTAssertTrue(ArrowCursorPolicy.effectiveCursor(for: .pointingHand) === NSCursor.arrow)
        XCTAssertTrue(ArrowCursorPolicy.effectiveCursor(for: .resizeLeftRight) === NSCursor.arrow)

        NSCursor.iBeam.set()
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)

        NSCursor.pointingHand.push()
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
        NSCursor.pop()
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)

        ArrowCursorPolicy.setEnabled(false)
        XCTAssertTrue(ArrowCursorPolicy.effectiveCursor(for: .iBeam) === NSCursor.iBeam)
    }

    func testPlaceholderTextViewSupportsSelectionWhileKeepingArrowCursor() {
        let wasEnabled = ArrowCursorPolicy.isEnabled
        defer { ArrowCursorPolicy.setEnabled(wasEnabled) }
        ArrowCursorPolicy.setEnabled(true)

        let text = PlaceholderTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        text.isRichText = false
        let window = NSWindow(contentRect: text.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = text
        defer { window.close() }

        window.makeFirstResponder(text)
        text.insertText("Hello Wisp world", replacementRange: NSRange(location: 0, length: 0))
        // Double-click word selection range and programmatic selection continue working normally.
        text.setSelectedRange(NSRange(location: 6, length: 4))
        XCTAssertEqual((text.string as NSString).substring(with: text.selectedRange()), "Wisp")

        text.resetCursorRects()
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
    }

    // MARK: - Settings window level & Space behavior

    func testSettingsWindowPresenterElevatesWindowAboveNormalAndAssistantPanel() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        XCTAssertEqual(window.level, .normal)
        SettingsWindowPresenter.configure(window, bringToFront: false)

        XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.floating.rawValue)
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.popUpMenu.rawValue)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    // MARK: - Local image file path extraction & PromptBuilder attachment

    func testExtractAndLoadLocalImagePathsHandlesSpacesAndIgnoresNonImages() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-image-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let jpeg = try XCTUnwrap(ScreenCapturer.tinyTestJPEG())
        let imgURL = dir.appendingPathComponent("Screenshot 2026-11-18 at 19-13-02.png")
        let txtURL = dir.appendingPathComponent("notes.txt")
        try jpeg.write(to: imgURL)
        try Data("not an image".utf8).write(to: txtURL)

        let prompt = """
        Summarize the key points of this page.

        \(imgURL.path)
        \(txtURL.path)
        /nonexistent/file.png
        \(imgURL.absoluteString)
        """

        let paths = ScreenCapturer.extractLocalImagePaths(from: prompt)
        XCTAssertEqual(paths, [imgURL.path], "should extract readable image once and ignore text/missing files")

        let loaded = ScreenCapturer.loadReferencedImages(in: prompt)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertFalse(loaded[0].isEmpty)

        let msg = Message(role: .user, text: prompt, context: nil, sentScreenshot: true)
        let payload = PromptBuilder.build(messages: [msg], liveScreenshot: nil, attachedImages: loaded, mode: .deep)
        let userBlocks = try XCTUnwrap(payload.last?["content"] as? [[String: Any]])
        let imageBlocks = userBlocks.filter { ($0["type"] as? String) == "image_url" }
        XCTAssertEqual(imageBlocks.count, 1)
    }

    // MARK: - PanelResize corner does not overlap composer send button

    func testPanelResizeCornerDoesNotOverlapSendButtonAtGutter() {
        let size = NSSize(width: 620, height: 180)
        // Composer right gutter is 12pt; send button sits at x <= 620 - 12 = 608.
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 620 - DS.gutter, y: 12), in: size), [])
        // Bottom-right corner inside cornerSize still resizes both edges.
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 610, y: 10), in: size), [.right, .bottom])
    }

    // MARK: - Hiding toggle does not silently create a virtual extended display

    func testEnablingHidingDoesNotAutoStartPresentationDisplay() {
        let saved = AppSettings.shared.hideFromScreenCapture
        defer {
            PresentationDisplay.shared.stop()
            ScreenPrivacy.setEnabled(saved)
        }
        PresentationDisplay.shared.stop()
        PresentationDisplay.shared.setHiding(true)
        XCTAssertTrue(AppSettings.shared.hideFromScreenCapture)
        XCTAssertFalse(PresentationDisplay.shared.isOpen)
    }
}
