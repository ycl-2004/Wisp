import Carbon.HIToolbox
import XCTest
@testable import Wisp

final class AdvancedShortcutTests: XCTestCase {
    func testAdvancedShortcutRoundTripsFunctionAndShiftModifiers() throws {
        let shortcut = AdvancedShortcut(
            keyCode: UInt16(kVK_Space),
            kind: .key,
            modifiers: [.function, .shift]
        )

        let data = try JSONEncoder().encode(shortcut)
        let restored = try JSONDecoder().decode(AdvancedShortcut.self, from: data)

        XCTAssertEqual(restored, shortcut)
        XCTAssertTrue(restored.eventModifiers.contains(.function))
        XCTAssertTrue(restored.eventModifiers.contains(.shift))
    }

    func testShortcutModesExposeExpectedTapCounts() {
        XCTAssertNil(ShortcutTriggerMode.standard.tapCount)
        XCTAssertEqual(ShortcutTriggerMode.enhancedSingle.tapCount, 1)
        XCTAssertEqual(ShortcutTriggerMode.doubleTap.tapCount, 2)
        XCTAssertEqual(ShortcutTriggerMode.tripleTap.tapCount, 3)
    }

    func testFunctionKeyNamesUseCarbonKeyMapInsteadOfNumericOffsets() {
        let cases: [(Int, String)] = [
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F5, "F5"),
            (kVK_F12, "F12"), (kVK_F13, "F13"), (kVK_F20, "F20"),
        ]

        for (keyCode, expected) in cases {
            XCTAssertEqual(ShortcutKeyInfo.name(for: UInt16(keyCode), kind: .key), expected)
        }
    }
}
