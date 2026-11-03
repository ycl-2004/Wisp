import AppKit
import XCTest
@testable import Wisp

/// The main panel and the recording-notes panel are borderless, and AppKit
/// will not make a borderless window key — its text fields then take no
/// typing. Both panels are KeyablePanel for that reason.
@MainActor
final class KeyablePanelTests: XCTestCase {
    private let frame = NSRect(x: 0, y: 0, width: 320, height: 200)

    func testABorderlessPanelCannotTakeTypingWithoutKeyablePanel() {
        let plain = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        XCTAssertFalse(plain.canBecomeKey, "the reason KeyablePanel exists")

        let keyable = KeyablePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: true)
        XCTAssertTrue(keyable.canBecomeKey)
        XCTAssertFalse(keyable.canBecomeMain)
    }

    func testEscapeRunsThePanelsOwnCancel() {
        let panel = KeyablePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        var cancelled = 0
        panel.onCancel = { cancelled += 1 }
        panel.cancelOperation(nil)
        XCTAssertEqual(cancelled, 1)
    }
}
