import AppKit
import XCTest
@testable import Wisp

@MainActor
final class LocalCursorTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 360, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.orderFront(nil)
        return window
    }

    func testLocalCursorDoesNotInterceptNativeControlsAndBalancesRestoration() throws {
        var hides = 0, shows = 0
        let controller = LocalCursorController(hideCursor: { hides += 1 }, showCursor: { shows += 1 })
        let window = window()
        defer { controller.stop(); window.close() }
        let content = try XCTUnwrap(window.contentView)
        let button = NSButton(frame: NSRect(x: 30, y: 30, width: 100, height: 32))
        content.addSubview(button)
        let point = window.convertPoint(toScreen: NSPoint(x: 50, y: 45))
        let originalHit = content.hitTest(NSPoint(x: 50, y: 45))

        controller.setEnabled(true)
        controller.update(window: window, screenPoint: point, applicationActive: true)
        let firstHide = hides
        XCTAssertTrue(controller.isReplacingCursor)
        XCTAssertTrue(controller.overlay.displayedCursor === NSCursor.arrow)
        XCTAssertTrue(controller.overlay.superview === content)
        XCTAssertTrue(content.hitTest(NSPoint(x: 50, y: 45)) === originalHit)
        XCTAssertNil(controller.overlay.hitTest(.zero))
        for _ in 0..<20 {
            controller.update(window: window, screenPoint: point, applicationActive: true)
        }
        XCTAssertEqual(hides, firstHide, "Movement must not increment the cursor hide count")
        controller.setEnabled(false)
        controller.stop()
        controller.restore()
        XCTAssertEqual(hides, shows, "Disable and repeated cleanup must release exactly our hides")
        XCTAssertNil(controller.overlay.superview)
    }

    func testCursorRestoresOnOutsideOccludedInactiveClosedAndPrivacyDisabledWindows() {
        let window = window()
        let controller = LocalCursorController(hideCursor: {}, showCursor: {})
        defer { controller.stop(); window.close() }
        let inside = window.convertPoint(toScreen: NSPoint(x: 50, y: 45))
        controller.setEnabled(true)
        func enter() {
            controller.update(window: window, screenPoint: inside, applicationActive: true)
            XCTAssertTrue(controller.isReplacingCursor)
        }
        enter()
        controller.update(window: window, screenPoint: inside, applicationActive: false)
        XCTAssertFalse(controller.isReplacingCursor)
        enter()
        controller.update(window: nil, screenPoint: inside, applicationActive: true)
        XCTAssertFalse(controller.isReplacingCursor)
        enter()
        controller.update(window: window, screenPoint: NSPoint(x: -1000, y: -1000), applicationActive: true)
        XCTAssertFalse(controller.isReplacingCursor)
        enter()
        controller.setEnabled(false)
        controller.update(window: window, screenPoint: inside, applicationActive: true)
        XCTAssertFalse(controller.isReplacingCursor)
        controller.setEnabled(true)
        enter()
        window.orderOut(nil)
        controller.update(window: window, screenPoint: inside, applicationActive: true)
        XCTAssertFalse(controller.isReplacingCursor)
    }

    func testMenusAndAppDeactivationReleaseCursorImmediately() {
        let window = window()
        var hides = 0, shows = 0
        let controller = LocalCursorController(hideCursor: { hides += 1 }, showCursor: { shows += 1 })
        defer { controller.stop(); window.close() }
        let point = window.convertPoint(toScreen: NSPoint(x: 60, y: 60))
        controller.setEnabled(true)
        controller.update(window: window, screenPoint: point, applicationActive: true)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        XCTAssertFalse(controller.isReplacingCursor)
        XCTAssertEqual(hides, shows)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        controller.update(window: window, screenPoint: point, applicationActive: true)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(controller.isReplacingCursor)
        XCTAssertEqual(hides, shows)
    }
}
