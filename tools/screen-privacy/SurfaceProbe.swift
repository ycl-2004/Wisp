// Surface-level capture probe. The window probe in Probe.swift covers Wisp's own
// panels; this one covers the surfaces AppKit creates on their behalf — menus,
// popovers, sheets and alerts — and reports every on-screen window the fixture
// process owns, so a surface that no protection path reaches cannot hide in the gap.
//
// Compile with Wisp/Support/ScreenPrivacy.swift. The settings double keeps the
// installed app's preferences, credentials and providers out of the test.
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage

@MainActor
final class AppSettings {
    static let shared = AppSettings()
    var hideFromScreenCapture = true
}

struct AppWindowRecord: Codable {
    let number: Int
    let sharingType: Int
    let visible: Bool
    let title: String
}

struct FixtureHandshake: Codable {
    let pid: Int32
    let appWindows: [AppWindowRecord]
}

enum SurfaceProbeError: Error { case permissionRequired, noDisplay, handshakeFailed }

@MainActor private var statusItemHolder: NSStatusItem?
@MainActor private var missionControlPanels: [NSPanel] = []
@MainActor private var missionControlWindows: [NSWindow] = []

@main
struct SurfaceProbe {

    // MARK: - Entry

    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "fixture" {
            runFixture(hidden: args.contains("hidden"))
            return
        }
        guard args.count == 3, args[1] == "hidden" || args[1] == "visible" else {
            print("Usage: surface-probe hidden|visible OUTPUT_DIRECTORY")
            return
        }
        guard CGPreflightScreenCaptureAccess() else { throw SurfaceProbeError.permissionRequired }

        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: args[0])
        fixture.arguments = ["fixture", args[1]]
        let pipe = Pipe()
        fixture.standardOutput = pipe
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !buffer.contains(UInt8(ascii: "\n")) {
            buffer.append(pipe.fileHandleForReading.availableData)
        }
        guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")),
              let handshake = try? JSONDecoder().decode(FixtureHandshake.self, from: buffer[..<newline])
        else { throw SurfaceProbeError.handshakeFailed }

        // The menu opens after the handshake and runs a nested tracking loop.
        try await Task.sleep(for: .milliseconds(1200))

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SurfaceProbeError.noDisplay }
        // The recorder's own path: full display, nothing excluded.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        config.capturesAudio = false
        let screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        // Older capture paths, still reachable at runtime by tools built against older
        // SDKs — remote-control agents and legacy recorders. The current SDK marks both
        // unavailable, so they are resolved dynamically. A nil result is recorded as null.
        let legacyList = legacyWindowListImage()
        let legacyDisplay = legacyDisplayImage(display.displayID)

        // Every on-screen window the fixture owns, including surfaces AppKit made itself.
        let listed = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let owned = listed.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == handshake.pid }

        let known = Set(handshake.appWindows.map(\.number))
        var surfaces: [[String: Any]] = []
        for window in owned {
            guard let number = window[kCGWindowNumber as String] as? Int,
                  let raw = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
            else { continue }
            let crop = CGRect(x: bounds.minX - display.frame.minX, y: bounds.minY - display.frame.minY,
                              width: bounds.width, height: bounds.height)
                .intersection(CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height))
            var fraction: Any = NSNull()
            if !crop.isNull, crop.width >= 2, crop.height >= 2, let region = screenshot.cropping(to: crop) {
                fraction = magentaFraction(region)
                // Only fixture-window rectangles are written out, never the whole desktop.
                try save(region, to: output.appendingPathComponent("window-\(number).png"))
            }
            surfaces.append([
                "windowNumber": number,
                "layer": window[kCGWindowLayer as String] as? Int ?? -1,
                "name": window[kCGWindowName as String] as? String ?? "",
                "bounds": ["x": bounds.minX, "y": bounds.minY, "w": bounds.width, "h": bounds.height],
                "reachableByAppKitProtection": known.contains(number),
                "markerFraction": fraction,
                "markerFractionWindowListImage": marker(in: legacyList, bounds: bounds, display: display.frame),
                "markerFractionDisplayImage": marker(in: legacyDisplay, bounds: bounds, display: display.frame),
            ])
        }

        // The menu bar strip itself. Only the magenta fraction is reported; the strip
        // holds the user's other status items, so no image of it is written out.
        var menuBarMarker: Any = NSNull()
        let strip = CGRect(x: 0, y: 0, width: Double(screenshot.width), height: 40)
        if let region = screenshot.cropping(to: strip) { menuBarMarker = magentaFraction(region) }

        let report: [String: Any] = [
            "mode": args[1],
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "fixtureUsesProductionScreenPrivacy": true,
            "fixturePid": handshake.pid,
            "appWindows": handshake.appWindows.map {
                ["number": $0.number, "sharingType": $0.sharingType, "visible": $0.visible, "title": $0.title]
            },
            "onScreenWindowsOwnedByFixture": surfaces.count,
            "menuBarStripMarkerFraction": menuBarMarker,
            "capturePaths": [
                "screenCaptureKit": true,
                "cgWindowListCreateImage": legacyList != nil,
                "cgDisplayCreateImage": legacyDisplay != nil,
            ],
            "surfaces": surfaces,
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("result.json"))
        print(String(decoding: json, as: UTF8.self))
    }

    // MARK: - Fixture

    @MainActor static func runFixture(hidden: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AppSettings.shared.hideFromScreenCapture = hidden
        ScreenPrivacy.start()

        guard let screen = NSScreen.screens.first else { exit(2) }
        let origin = CGPoint(x: screen.frame.midX - 260, y: screen.frame.midY - 120)

        // Mission Control check: Wisp's real panel behavior on the left (magenta), the
        // same panel plus .transient on the right (cyan). Space thumbnails are drawn by
        // the system, so whether the hiding request reaches them has to be measured.
        if CommandLine.arguments.contains("missioncontrol") {
            // Left, magenta: the panel configuration Wisp's assistant panel and island use.
            let wisp = NSPanel(contentRect: CGRect(x: origin.x - 360, y: origin.y, width: 300, height: 200),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            wisp.level = .floating
            wisp.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            wisp.isReleasedWhenClosed = false
            wisp.contentView = marker("wisp-panel", color: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1),
                                      size: CGSize(width: 300, height: 200))
            ScreenPrivacy.apply(to: wisp)
            wisp.orderFrontRegardless()

            // Wisp's Settings window is an ordinary titled window, unlike the panels.
            let settings = NSWindow(contentRect: CGRect(x: origin.x + 400, y: origin.y, width: 300, height: 200),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.title = "WispSurfaceProbe-settings"
            settings.isReleasedWhenClosed = false
            settings.contentView = marker("wisp-settings", color: NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1),
                                          size: CGSize(width: 300, height: 200))
            ScreenPrivacy.apply(to: settings)
            settings.orderFrontRegardless()
            missionControlPanels = [wisp]
            missionControlWindows = [settings]
            FileHandle.standardError.write(Data("mission control up: panel=\(wisp.sharingType.rawValue) visible=\(wisp.isVisible) settings=\(settings.sharingType.rawValue) visible=\(settings.isVisible)\n".utf8))
            RunLoop.current.run()
            return
        }

        // Menu bar item: the question is which process owns its window, since only
        // this process's own windows can carry the hiding request.
        let statusItem = NSStatusBar.system.statusItem(withLength: 30)
        if let button = statusItem.button {
            let icon = NSImage(size: CGSize(width: 18, height: 18))
            icon.lockFocus()
            NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 18, height: 18).fill()
            icon.unlockFocus()
            icon.isTemplate = false
            button.image = icon
        }
        statusItemHolder = statusItem

        let host = NSWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 320, height: 240)),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.title = "WispSurfaceProbe-host"
        host.isReleasedWhenClosed = false
        host.level = .floating
        host.contentView = marker("host")
        ScreenPrivacy.apply(to: host)
        host.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        // Popover: AppKit creates its own window for the content.
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        let controller = NSViewController()
        controller.view = marker("popover", size: CGSize(width: 200, height: 90))
        popover.contentViewController = controller
        popover.show(relativeTo: CGRect(x: 10, y: 10, width: 40, height: 40),
                     of: host.contentView!, preferredEdge: .maxX)

        // First-frame check: read the popover's window before the run loop turns, i.e.
        // before NSWindow.didUpdateNotification can reach the fallback observer.
        let popoverWindow = popover.contentViewController?.view.window
        FileHandle.standardError.write(Data("popover firstFrame sharingType=\(popoverWindow.map { String($0.sharingType.rawValue) } ?? "no-window") inAppWindows=\(popoverWindow.map { NSApp.windows.contains($0) } ?? false)\n".utf8))

        // Sheet: a separate window attached to the host.
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 280, height: 120),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = marker("sheet")
        host.beginSheet(sheet)

        FileHandle.standardError.write(Data("sheet firstFrame sharingType=\(sheet.sharingType.rawValue) visible=\(sheet.isVisible) inAppWindows=\(NSApp.windows.contains(sheet))\n".utf8))

        // Alert presented as a sheet, so it does not block this run loop.
        let alert = NSAlert()
        alert.messageText = "WispSurfaceProbe"
        alert.accessoryView = marker("alert", size: CGSize(width: 220, height: 60))
        alert.beginSheetModal(for: sheet)

        // Let AppKit place every surface on screen before reporting.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        if let statusWindow = statusItem.button?.window {
            ScreenPrivacy.applyToAllWindows()
            let frame = statusWindow.frame
            let visible = statusItem.button?.isHiddenOrHasHiddenAncestor == false && statusItem.isVisible
            FileHandle.standardError.write(Data("status item window #\(statusWindow.windowNumber) sharingType=\(statusWindow.sharingType.rawValue) inAppWindows=\(NSApp.windows.contains(statusWindow)) visible=\(visible) frame=\(frame) screenTop=\(NSScreen.screens.first?.frame.maxY ?? 0)\n".utf8))
        } else {
            FileHandle.standardError.write(Data("status item has no window in this process\n".utf8))
        }

        let records = NSApp.windows.map {
            AppWindowRecord(number: $0.windowNumber, sharingType: Int($0.sharingType.rawValue),
                            visible: $0.isVisible, title: $0.title)
        }
        let handshake = FixtureHandshake(pid: ProcessInfo.processInfo.processIdentifier, appWindows: records)
        FileHandle.standardOutput.write(try! JSONEncoder().encode(handshake))
        FileHandle.standardOutput.write(Data("\n".utf8))

        // Menus run a nested tracking loop, so this call does not return until the
        // menu closes. Everything above is already on screen by now.
        let menu = NSMenu()
        let item = NSMenuItem()
        item.view = marker("menu", size: CGSize(width: 200, height: 70))
        menu.addItem(item)
        menu.popUp(positioning: nil,
                   at: CGPoint(x: origin.x + 380, y: origin.y + 200), in: nil)
        app.run()
    }

    // MARK: - Helpers

    @MainActor static func marker(_ label: String, color: NSColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1),
                                  size: CGSize = CGSize(width: 320, height: 240)) -> NSView {
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        let field = NSTextField(labelWithString: label)
        field.frame = CGRect(x: 8, y: 8, width: size.width - 16, height: 20)
        view.addSubview(field)
        return view
    }

    /// CGWindowListCreateImage(CGRectInfinite, kCGWindowListOptionOnScreenOnly,
    /// kCGNullWindowID, kCGWindowImageBestResolution), resolved at runtime.
    static func legacyWindowListImage() -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        let call = unsafeBitCast(symbol, to: Fn.self)
        return call(.infinite, 1, 0, 1 << 3)?.takeRetainedValue()
    }

    /// CGDisplayCreateImage(displayID), resolved at runtime.
    static func legacyDisplayImage(_ displayID: CGDirectDisplayID) -> CGImage? {
        typealias Fn = @convention(c) (UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGDisplayCreateImage") else { return nil }
        let call = unsafeBitCast(symbol, to: Fn.self)
        return call(displayID)?.takeRetainedValue()
    }

    /// Crops a point-space window rectangle out of a capture whose pixel size may differ.
    static func marker(in image: CGImage?, bounds: CGRect, display: CGRect) -> Any {
        guard let image, display.width > 0, display.height > 0 else { return NSNull() }
        let scaleX = Double(image.width) / display.width
        let scaleY = Double(image.height) / display.height
        let crop = CGRect(x: (bounds.minX - display.minX) * scaleX, y: (bounds.minY - display.minY) * scaleY,
                          width: bounds.width * scaleX, height: bounds.height * scaleY)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isNull, crop.width >= 2, crop.height >= 2,
              let region = image.cropping(to: crop) else { return NSNull() }
        return magentaFraction(region)
    }

    static func save(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    static func magentaFraction(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let hits = pixels.withUnsafeMutableBytes { buffer -> Int in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).reduce(0) { count, i in
                count + (bytes[i] > 200 && bytes[i + 1] < 70 && bytes[i + 2] > 200 ? 1 : 0)
            }
        }
        return Double(hits) / Double(width * height)
    }
}
