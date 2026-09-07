// Compile with Wisp/Support/ScreenPrivacy.swift; the settings double avoids
// touching the installed app's preferences, credentials, or model providers.
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage

@MainActor
final class AppSettings {
    static let shared = AppSettings()
    var hideFromScreenCapture = true
}

struct Fixture: Codable {
    let name: String
    let id: CGWindowID
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

enum ProbeError: Error { case permissionRequired, noDisplay, noFrames, fixtureFailed }

final class Frames: NSObject, SCStreamOutput, @unchecked Sendable {
    // Accessed only on the output queue; read after stopCapture + queue.sync.
    var images: [CGImage] = []
    private let context = CIContext()
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixel = sample.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixel)
        if images.count < 60, let cg = context.createCGImage(image, from: image.extent) {
            images.append(cg)
        }
    }
}

@main
struct CaptureProbe {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "lifecycle" {
            runLifecycleChecks()
            return
        }
        if args.count > 1, args[1] == "fixture" {
            runFixture(hidden: args.contains("hidden"))
            return
        }
        guard args.count == 3 else {
            print("Usage: probe hidden|visible OUTPUT_DIRECTORY, or probe lifecycle")
            return
        }
        guard CGPreflightScreenCaptureAccess() else { throw ProbeError.permissionRequired }
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: args[0])
        fixture.arguments = ["fixture", args[1]]
        let pipe = Pipe()
        fixture.standardOutput = pipe
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        let data = pipe.fileHandleForReading.availableData
        let fixtures = try JSONDecoder().decode([Fixture].self, from: data)
        try await Task.sleep(for: .milliseconds(500))

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ProbeError.noDisplay }
        // No window/app exclusions: this is the recorder's full-display path.
        // Source: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        config.capturesAudio = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        let screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let frames = Frames()
        let queue = DispatchQueue(label: "Wisp.capture-probe.frames")
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(2))
        try await stream.stopCapture()
        let captured = queue.sync { frames.images }
        guard !captured.isEmpty else { throw ProbeError.noFrames }
        var results: [[String: Any]] = []
        for item in fixtures {
            let crop = CGRect(x: item.x - display.frame.minX, y: item.y - display.frame.minY,
                              width: item.width, height: item.height)
            // Save only test-window rectangles, never the full desktop.
            let shot = screenshot.cropping(to: crop)!
            let last = captured.last!.cropping(to: crop)!
            try save(shot, to: output.appendingPathComponent("\(item.name)-screenshot.png"))
            try save(last, to: output.appendingPathComponent("\(item.name)-stream.png"))
            let systemURL = output.appendingPathComponent("\(item.name)-system.png")
            let systemCapture = Process()
            systemCapture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            systemCapture.arguments = ["-x", "-R\(Int(item.x)),\(Int(item.y)),\(Int(item.width)),\(Int(item.height))", systemURL.path]
            try systemCapture.run()
            systemCapture.waitUntilExit()
            var systemFraction: Any = NSNull()
            if systemCapture.terminationStatus == 0,
               let bitmap = NSBitmapImageRep(data: try Data(contentsOf: systemURL)), let image = bitmap.cgImage {
                systemFraction = magentaFraction(image)
            }
            results.append([
                "window": item.name,
                "listedByScreenCaptureKit": content.windows.contains { $0.windowID == item.id },
                "screenshotMagentaFraction": magentaFraction(shot),
                "systemScreenshotExitStatus": systemCapture.terminationStatus,
                "systemScreenshotMagentaFraction": systemFraction,
                "streamFrames": captured.count,
                "streamFramesWithMarker": captured.filter {
                    guard let region = $0.cropping(to: crop) else { return false }
                    return magentaFraction(region) > 0.1
                }.count
            ])
        }
        let report: [String: Any] = ["mode": args[1], "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                    "fixtureUsesProductionScreenPrivacy": true, "results": results]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("result.json"))
        print(String(decoding: json, as: UTF8.self))
    }

    @MainActor static func runLifecycleChecks() {
        _ = NSApplication.shared
        var passed: [String] = []
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            passed.append(name)
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 140),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(string: "input survives toggle")
        window.contentView = field
        let originalFrame = window.frame
        let originalVisibility = window.isVisible
        AppSettings.shared.hideFromScreenCapture = true
        ScreenPrivacy.start()
        check(window.sharingType == .none, "startup applies to existing windows")
        ScreenPrivacy.start()
        ScreenPrivacy.setEnabled(false)
        check(window.sharingType == .readOnly, "disable restores readable windows")
        let attached = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        attached.isReleasedWhenClosed = false
        attached.contentView = ScreenPrivacyWindow.WindowView()
        check(attached.sharingType == .readOnly, "attachment respects disabled preference")
        ScreenPrivacy.setEnabled(true)
        check(window.sharingType == .none && attached.sharingType == .none,
              "re-enable updates every existing window")
        let early = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        early.isReleasedWhenClosed = false
        early.contentView = ScreenPrivacyWindow.WindowView()
        check(early.sharingType == .none && !early.isVisible,
              "attachment applies before window is ordered on screen")
        let late = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        late.isReleasedWhenClosed = false
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: late)
        check(late.sharingType == .none, "observer covers late app-owned windows")
        check(field.stringValue == "input survives toggle" && window.frame == originalFrame
              && window.isVisible == originalVisibility, "toggle preserves input, frame and visibility")
        ScreenPrivacy.setEnabled(false)
        check([window, attached, early, late].allSatisfy { $0.sharingType == .readOnly },
              "disable includes windows attached after startup")
        for name in passed { print("PASS: \(name)") }
        print("\(passed.count) lifecycle checks passed (not a screen-capture verdict)")
        for item in [window, attached, early, late] { item.close() }
    }

    @MainActor static func runFixture(hidden: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first else { exit(2) }
        AppSettings.shared.hideFromScreenCapture = hidden
        ScreenPrivacy.start()
        var fixtures: [Fixture] = []
        var windows: [NSWindow] = []
        for (index, name) in ["panel", "island", "settings"].enumerated() {
            let rect = CGRect(x: screen.frame.midX - 330 + Double(index) * 225,
                              y: screen.frame.midY - 80, width: 200, height: 140)
            let window: NSWindow
            if name == "settings" {
                window = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            } else {
                window = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            }
            window.title = "WispCaptureProbe-\(name)"
            window.level = .floating
            window.isReleasedWhenClosed = false
            let view = NSView(frame: CGRect(origin: .zero, size: rect.size))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).cgColor
            let input = NSTextField(string: "\(name): \(hidden ? "hidden" : "visible")")
            input.frame = CGRect(x: 10, y: 15, width: 180, height: 25)
            view.addSubview(input)
            window.contentView = view
            ScreenPrivacy.apply(to: window)
            window.orderFrontRegardless()
            windows.append(window)
            fixtures.append(Fixture(name: name, id: CGWindowID(window.windowNumber), x: rect.minX,
                                    y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height))
        }
        print(String(decoding: try! JSONEncoder().encode(fixtures), as: UTF8.self))
        fflush(stdout)
        withExtendedLifetime(windows) { app.run() }
    }

    static func save(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    static func magentaFraction(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
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
