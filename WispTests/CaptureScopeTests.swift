import XCTest
@testable import Wisp

final class CaptureScopeTests: XCTestCase {
    func testWholeScreenFollowsTheFocusedWindowThenThePointer() {
        let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        let displays = [builtIn, external]
        // A window straddling both displays belongs to the one holding most of it.
        let straddling = CGRect(x: 1400, y: 0, width: 800, height: 600)
        XCTAssertEqual(ScreenCapturer.displayIndex(for: straddling, cursor: nil, displays: displays), 1)
        let onBuiltIn = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(ScreenCapturer.displayIndex(for: onBuiltIn, cursor: CGPoint(x: 2000, y: 100),
                                                   displays: displays), 0)
        // No window: use the display under the pointer, not merely the first one.
        XCTAssertEqual(ScreenCapturer.displayIndex(for: nil, cursor: CGPoint(x: 2000, y: 100), displays: displays), 1)
        let offscreen = CGRect(x: -5000, y: -5000, width: 10, height: 10)
        XCTAssertEqual(ScreenCapturer.displayIndex(for: offscreen, cursor: CGPoint(x: 2000, y: 100),
                                                   displays: displays), 1)
        XCTAssertEqual(ScreenCapturer.displayIndex(for: nil, cursor: nil, displays: displays), 0)
        XCTAssertNil(ScreenCapturer.displayIndex(for: nil, cursor: nil, displays: []))
    }

    func testWholeScreenGetsALargerImageBudget() {
        XCTAssertGreaterThan(ScreenCapturer.maxLongEdge(for: .screen), ScreenCapturer.maxLongEdge(for: .window))
    }

    func testExcludedAppsAreAlwaysHiddenFromWholeScreenCaptures() throws {
        let settings = AppSettings.shared
        let defaults = UserDefaults.standard
        // The test host shares the installed app's defaults domain. Snapshot only what is
        // persisted: `object(forKey:)` would also return registered defaults and write them back.
        let keys = ["excludedBundleIDs", "screenHiddenBundleIDs", "captureScope"]
        let persisted = defaults.persistentDomain(forName: try XCTUnwrap(Bundle.main.bundleIdentifier)) ?? [:]
        defer {
            for key in keys {
                if let value = persisted[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.removeObject(forKey: "captureScope")
        XCTAssertEqual(settings.captureScope, .window)

        settings.excludedBundleIDs = ["test.password"]
        settings.screenHiddenBundleIDs = ["test.chat"]
        XCTAssertEqual(settings.screenCaptureHiddenBundleIDs, ["test.password", "test.chat"])
        // Hiding an app from whole-screen shots does not stop Wisp reading it when it is in front.
        XCTAssertFalse(settings.isExcluded(bundleID: "test.chat"))
    }

    func testPromptSaysWhenTheScreenshotIsTheWholeScreen() throws {
        var packet = ContextPacket(appName: "FocusApp", bundleID: "test.focus")
        packet.windowTitle = "Notes"
        packet.screenshotJPEG = try XCTUnwrap(ScreenCapturer.tinyTestJPEG())
        let window = packet.snapshot()
        packet.screenshotScope = .screen
        let screen = packet.snapshot()
        XCTAssertEqual(window.screenshotScope, .window)
        XCTAssertEqual(screen.screenshotScope, .screen)

        XCTAssertEqual(PromptBuilder.quickLine(window), "[\(window.summaryLine)]")
        XCTAssertNotEqual(PromptBuilder.quickLine(screen), PromptBuilder.quickLine(window))
        XCTAssertTrue(PromptBuilder.quickLine(screen).contains(screen.summaryLine))

        let windowBlock = PromptBuilder.contextBlock(window, full: true)
        let screenBlock = PromptBuilder.contextBlock(screen, full: true)
        XCTAssertNotEqual(screenBlock, windowBlock)
        // Only the screenshot line differs, and it names the focused app.
        let changed = screenBlock.components(separatedBy: "\n")
            .filter { !windowBlock.components(separatedBy: "\n").contains($0) }
        XCTAssertEqual(changed.count, 1)
        XCTAssertTrue(changed.first?.contains("FocusApp") == true)

        // A turn that did not actually send the image says nothing about its scope.
        var unsent = screen
        unsent.hadScreenshot = false
        var unsentWindow = window
        unsentWindow.hadScreenshot = false
        XCTAssertEqual(PromptBuilder.quickLine(unsent), "[\(unsent.summaryLine)]")
        XCTAssertEqual(PromptBuilder.contextBlock(unsent, full: true),
                       PromptBuilder.contextBlock(unsentWindow, full: true))
    }

    func testSnapshotsKeepTheirScopeAndOlderRecordsReadAsWindow() throws {
        var packet = ContextPacket(appName: "App", bundleID: "test.app")
        packet.screenshotScope = .screen
        let data = try JSONEncoder().encode(packet.snapshot())
        XCTAssertEqual(try JSONDecoder().decode(ContextSnapshot.self, from: data).screenshotScope, .screen)

        let legacy = #"{"appName":"App","iframeURLs":[],"hadScreenshot":true,"capturedAt":0}"#
        let decoded = try JSONDecoder().decode(ContextSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.screenshotScope, .window)
    }
}
