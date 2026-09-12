import AppKit
import XCTest
@testable import Wisp

@MainActor
final class LocalCursorTests: XCTestCase {
    // The app's lifecycle observer runs in the test host too. Keep synthetic
    // windows protected independently of the user's persisted screen-sharing switch.
    private final class ProtectedWindow: NSWindow, CursorSharingSurface {
        var cursorSharingType: NSWindow.SharingType { .none }
    }

    private func window() -> NSWindow {
        let window = ProtectedWindow(contentRect: NSRect(x: 160, y: 160, width: 360, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.orderFront(nil)
        return window
    }

    func testCursorLockCanBeEnabledFromVisibleWindowsAndDisabledIndependently() throws {
        let suite = "wisp-cursor-settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.hideFromScreenCapture = false
        XCTAssertFalse(settings.localCursorEnabled)

        settings.localCursorEnabled = true
        XCTAssertTrue(settings.hideFromScreenCapture, "Enabling lock must satisfy its window-hiding dependency")
        XCTAssertTrue(settings.localCursorEnabled)
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.hideFromScreenCapture)
        XCTAssertTrue(reloaded.localCursorEnabled)

        settings.localCursorEnabled = false
        XCTAssertFalse(settings.localCursorEnabled)
        XCTAssertTrue(settings.hideFromScreenCapture, "Disabling the lock must not expose Wisp windows")

        settings.localCursorEnabled = true
        settings.hideFromScreenCapture = false
        XCTAssertFalse(settings.localCursorEnabled, "Window hiding off must not leave a checked but inactive lock")
        settings.hideFromScreenCapture = true
        XCTAssertFalse(settings.localCursorEnabled, "Window hiding alone must not opt into cursor lock")
    }

    func testPrivacySettingTransitionsRestoreSingleCursorAndAllowReentry() throws {
        let suite = "wisp-cursor-lifecycle-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let window = window()
        var hides = 0, shows = 0
        let controller = LocalCursorController(hideCursor: { hides += 1 }, showCursor: { shows += 1 })
        defer { controller.stop(); window.close() }
        let point = window.convertPoint(toScreen: NSPoint(x: 60, y: 60))

        for disableHiding in [false, true] {
            settings.localCursorEnabled = true
            controller.setEnabled(settings.localCursorEnabled && settings.hideFromScreenCapture)
            controller.update(window: window, screenPoint: point, applicationActive: true)
            XCTAssertTrue(controller.isReplacingCursor)
            if disableHiding { settings.hideFromScreenCapture = false }
            else { settings.localCursorEnabled = false }
            controller.setEnabled(settings.localCursorEnabled && settings.hideFromScreenCapture)
            controller.refresh()
            controller.update(window: window, screenPoint: point, applicationActive: true)
            XCTAssertFalse(controller.isReplacingCursor)
            XCTAssertFalse(controller.localWindow.isVisible)
            XCTAssertNil(controller.localWindow.parent)
            XCTAssertEqual(hides, shows)
        }
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
        XCTAssertTrue(controller.overlay.window === controller.localWindow)
        XCTAssertTrue(controller.localWindow.isVisible)
        XCTAssertEqual(controller.localWindow.sharingType, .none)
        XCTAssertTrue(controller.localWindow.ignoresMouseEvents)
        XCTAssertFalse(controller.localWindow.canBecomeKey)
        XCTAssertTrue(controller.localWindow.parent === window)
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
        XCTAssertFalse(controller.localWindow.isVisible)
        XCTAssertNil(controller.localWindow.parent)
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

    func testProtectedMenuKeepsCursorAndAppDeactivationReleasesIt() {
        let window = window()
        var hides = 0, shows = 0
        let controller = LocalCursorController(hideCursor: { hides += 1 }, showCursor: { shows += 1 })
        defer { controller.stop(); window.close() }
        let point = window.convertPoint(toScreen: NSPoint(x: 60, y: 60))
        controller.setEnabled(true)
        controller.update(window: window, screenPoint: point, applicationActive: true)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        controller.update(window: window, screenPoint: point, applicationActive: true)
        XCTAssertTrue(controller.isReplacingCursor, "A protected app menu must not force the lock off")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        controller.update(window: window, screenPoint: point, applicationActive: true)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(controller.isReplacingCursor)
        XCTAssertEqual(hides, shows)
    }

    func testSinglePrivateArrowMovesWithoutLeavingAStationaryWindow() {
        let window = window()
        window.contentView?.wantsLayer = true
        let controller = LocalCursorController(hideCursor: {}, showCursor: {})
        defer { controller.stop(); window.close() }
        controller.setEnabled(true)
        let start = window.convertPoint(toScreen: NSPoint(x: 60, y: 60))
        controller.update(window: window, screenPoint: start, applicationActive: true)
        let local = controller.localWindow.frame
        let moved = NSPoint(x: start.x + 90, y: start.y + 40)
        controller.update(window: window, screenPoint: moved, applicationActive: true)
        XCTAssertEqual(controller.localWindow.frame.minX, local.minX + 90)
        XCTAssertEqual(controller.localWindow.frame.minY, local.minY + 40)
        XCTAssertGreaterThan(controller.localWindow.level.rawValue, window.level.rawValue)
        XCTAssertEqual(window.convertPoint(fromScreen: moved), NSPoint(x: 150, y: 100))
        XCTAssertTrue(controller.overlay.wantsLayer)
        ScreenPrivacy.apply(to: controller.localWindow)
        XCTAssertEqual(controller.localWindow.sharingType, .none)
        let arrows = NSApp.windows.compactMap { $0 as? CursorPresentationWindow }.filter(\.isVisible)
        XCTAssertEqual(arrows.count, 1, "There must be no stationary arrow hiding under the host")
        XCTAssertTrue(arrows.first === controller.localWindow)
    }

    func testTransientMenuKeepsOneArrowWithoutChangingItsChildOrdering() {
        let panel = window()
        let menu = window()
        menu.level = .popUpMenu
        let controller = LocalCursorController(hideCursor: {}, showCursor: {})
        defer { controller.stop(); menu.close(); panel.close() }
        controller.setEnabled(true)
        let point = panel.convertPoint(toScreen: NSPoint(x: 60, y: 60))
        controller.update(window: panel, screenPoint: point, applicationActive: true)
        XCTAssertTrue(controller.localWindow.parent === panel)
        controller.update(window: menu, screenPoint: point, applicationActive: true)
        XCTAssertTrue(controller.isReplacingCursor)
        XCTAssertTrue(controller.localWindow.isVisible)
        XCTAssertNil(controller.localWindow.parent, "AppKit owns transient menu child ordering")
        controller.update(window: panel, screenPoint: point, applicationActive: true)
        XCTAssertTrue(controller.localWindow.parent === panel)
        XCTAssertEqual(NSApp.windows.filter { $0 is CursorPresentationWindow && $0.isVisible }.count, 1)
    }

    func testSystemCursorIsHiddenBeforeLocalArrowAndShownOnlyAfterRemoval() {
        let window = window()
        var controller: LocalCursorController!
        var transitions: [String] = []
        controller = LocalCursorController(hideCursor: {
            XCTAssertFalse(controller.localWindow.isVisible, "Never show the overlay before hiding the system pointer")
            transitions.append("hide")
        }, showCursor: {
            XCTAssertFalse(controller.localWindow.isVisible, "Never unhide the system pointer beside an overlay")
            XCTAssertNil(controller.localWindow.parent)
            transitions.append("show")
        })
        defer { controller.stop(); window.close() }
        controller.setEnabled(true)
        controller.restore()
        transitions.removeAll()
        let point = NSPoint(x: window.frame.midX, y: window.frame.midY)
        for _ in 0..<10 {
            controller.update(window: window, screenPoint: point, applicationActive: true)
            XCTAssertTrue(controller.localWindow.isVisible)
            controller.restore()
        }
        XCTAssertEqual(transitions, (0..<10).flatMap { _ in ["hide", "show"] })
    }

    func testTranslucentMovedResizedAndSwitchedHostsCannotLeaveASecondArrow() {
        let first = window(), second = window()
        let controller = LocalCursorController(hideCursor: {}, showCursor: {})
        defer { controller.stop(); first.close(); second.close() }
        controller.setEnabled(true)
        for host in [first, second, first] {
            host.isOpaque = false
            host.backgroundColor = .clear
            host.alphaValue = 0.35
            host.orderFrontRegardless()
            for offset in [0.0, 140.0, -100.0] {
                host.setFrame(NSRect(x: 160 + offset, y: 160, width: 260 + offset, height: 180), display: true)
                let point = NSPoint(x: host.frame.midX, y: host.frame.midY)
                controller.update(window: host, screenPoint: point, applicationActive: true)
                let arrows = NSApp.windows.compactMap { $0 as? CursorPresentationWindow }.filter(\.isVisible)
                XCTAssertEqual(arrows.count, 1)
                XCTAssertTrue(arrows.first === controller.localWindow)
                XCTAssertTrue(controller.localWindow.parent === host)
                XCTAssertEqual(controller.localWindow.sharingType, .none)
            }
        }
        first.orderOut(nil)
        XCTAssertFalse(controller.localWindow.isVisible, "Host dismissal hides the child without waiting for a timer")
        controller.refresh()
        XCTAssertFalse(controller.isReplacingCursor)
    }

    func testClosingAndMiniaturizingOwnersRemoveThePrivateArrow() {
        let host = window()
        let controller = LocalCursorController(hideCursor: {}, showCursor: {})
        defer { controller.stop(); host.close() }
        controller.setEnabled(true)
        let point = NSPoint(x: host.frame.midX, y: host.frame.midY)
        for event in [NSWindow.willMiniaturizeNotification, NSWindow.willCloseNotification] {
            controller.update(window: host, screenPoint: point, applicationActive: true)
            XCTAssertTrue(controller.localWindow.isVisible)
            NotificationCenter.default.post(name: event, object: host)
            XCTAssertFalse(controller.isReplacingCursor)
            XCTAssertFalse(controller.localWindow.isVisible)
            XCTAssertNil(controller.localWindow.parent)
        }
    }

    func testKeyPanelWaitsForAppActivationBeforeReplacingTheSystemPointer() {
        class KeyPanel: NSPanel, CursorSharingSurface {
            override var canBecomeKey: Bool { true }
            var cursorSharingType: NSWindow.SharingType { .none }
        }
        let panel = KeyPanel(contentRect: NSRect(x: 160, y: 160, width: 360, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.makeKeyAndOrderFront(nil)
        let controller = LocalCursorController(hideCursor: {}, showCursor: {})
        defer { controller.stop(); panel.close() }
        controller.setEnabled(true)
        let point = panel.convertPoint(toScreen: NSPoint(x: 60, y: 60))
        XCTAssertTrue(panel.isKeyWindow)
        controller.update(window: panel, screenPoint: point, applicationActive: false)
        XCTAssertFalse(controller.isReplacingCursor, "Key focus alone cannot hide the system cursor in a background app")
        XCTAssertFalse(controller.localWindow.isVisible)
        controller.update(window: panel, screenPoint: point, applicationActive: true)
        XCTAssertTrue(controller.isReplacingCursor)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        controller.update(window: panel, screenPoint: point, applicationActive: true)
        XCTAssertTrue(controller.isReplacingCursor)
    }

    func testCursorArtworkAndNativeCursorStackFollowTheLockSwitch() {
        WispCursorPolicy.install()
        WispCursorPolicy.install()
        WispCursorPolicy.setEnabled(true)
        defer { WispCursorPolicy.setEnabled(false); NSCursor.arrow.set() }
        for cursor in [NSCursor.iBeam, .pointingHand, .resizeLeftRight, .crosshair, .closedHand] {
            cursor.set()
            XCTAssertTrue(NSCursor.current === NSCursor.arrow)
            cursor.push()
            XCTAssertTrue(NSCursor.current === NSCursor.arrow)
            NSCursor.pop()
        }
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        NSCursor.iBeam.set()
        WispCursorPolicy.setEnabled(false)
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam, "Disabling restores the last native cursor request")
        for cursor in [NSCursor.iBeam, .pointingHand, .resizeLeftRight] {
            cursor.set()
            XCTAssertTrue(NSCursor.current === cursor)
            cursor.push()
            XCTAssertTrue(NSCursor.current === cursor)
            NSCursor.pop()
        }
    }

    func testNonKeyFloatingPanelAndNativeTitleBarAreIncluded() {
        let panel = NSPanel(contentRect: NSRect(x: 160, y: 160, width: 360, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.orderFrontRegardless()
        let titled = ProtectedWindow(contentRect: panel.frame,
                                     styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        titled.isReleasedWhenClosed = false
        titled.sharingType = .none
        let controller = LocalCursorController(hideCursor: {}, showCursor: {})
        defer { controller.stop(); panel.close(); titled.close() }
        controller.setEnabled(true)
        XCTAssertFalse(panel.isKeyWindow)
        controller.update(window: panel, screenPoint: NSPoint(x: panel.frame.midX, y: panel.frame.midY),
                          applicationActive: false)
        XCTAssertFalse(controller.isReplacingCursor, "Background hover must not claim a lock that the system cannot honor")
        controller.update(window: panel, screenPoint: NSPoint(x: panel.frame.midX, y: panel.frame.midY),
                          applicationActive: true)
        XCTAssertTrue(controller.isReplacingCursor, "Non-key floating panels are included while Wisp is active")
        titled.orderFrontRegardless()
        let titlePoint = NSPoint(x: titled.frame.midX, y: titled.frame.maxY - 5)
        controller.update(window: titled, screenPoint: titlePoint, applicationActive: true)
        XCTAssertTrue(controller.isReplacingCursor, "Native settings title bars must keep the lock")
        controller.update(window: nil, screenPoint: titlePoint, applicationActive: true)
        XCTAssertFalse(controller.isReplacingCursor, "A foreign window still releases the cursor")
    }
}
