// Run as a standalone GUI probe, linking the production monitor, controller and
// ScreenPrivacy. A second bundle supplies a public window. A third process reads
// both whole displays with no exclusions. Only marker counts leave the sampler.
import AppKit
import ScreenCaptureKit

@MainActor final class AppSettings {
    static let shared = AppSettings()
    var hideFromScreenCapture = true
}

private struct Counts: Codable {
    var cyan = 0
    var magenta = 0
    var green = 0
}
private struct Pair: Codable {
    var source: Counts
    var output: Counts
}
private final class DisplayFrames: NSObject, SCStreamOutput {
    private let context = CIContext()
    // Registered on the main queue. Sample downscaled buffers and retain counts only.
    var rows: [Counts] = []
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let status = info[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sample.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        if let image = context.createCGImage(ci, from: ci.extent) { rows.append(DisplayProbe.measure(image)) }
    }
}
private enum ProbeError: Error { case arguments, unavailable, readiness, capture, unexpectedPixels }

@main private struct DisplayProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL", error); exit(1) }
        }
        if CommandLine.arguments.dropFirst().first == "sample" {
            RunLoop.main.run()
        } else {
            app.run()
        }
    }

    @MainActor private static func run() async throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        let app = NSApplication.shared
        if args.dropFirst().first != "sample" { app.setActivationPolicy(.regular) }
        if args.count == 3, args[1] == "control" {
            let marker = window(.cyan, width: 520)
            while !FileManager.default.fileExists(atPath: args[2]) { try await Task.sleep(for: .milliseconds(100)) }
            marker.backgroundColor = .green
            while marker.isVisible { try await Task.sleep(for: .seconds(1)) }
            return
        }
        if args.count == 6, args[1] == "sample", let source = UInt32(args[2]), let output = UInt32(args[3]) {
            print("Receiver enumerating source and presentation display")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            func counts(_ id: CGDirectDisplayID) async throws -> Counts {
                guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ProbeError.unavailable }
                let config = SCStreamConfiguration()
                config.width = 720
                config.height = 480
                config.showsCursor = false
                let frame = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
                return measure(frame)
            }
            print("Receiver sampling main display")
            let local = try await counts(source)
            print("Source control", local, "output screenshot", try await counts(output))
            guard let display = content.displays.first(where: { $0.displayID == output }) else { throw ProbeError.unavailable }
            let config = SCStreamConfiguration()
            config.width = 720
            config.height = 480
            config.showsCursor = false
            let receiver = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
            let frames = DisplayFrames()
            try receiver.addStreamOutput(frames, type: .screen, sampleHandlerQueue: .main)
            print("Starting independent display stream")
            try await receiver.startCapture()
            func waitFor(_ predicate: (Counts) -> Bool) async throws -> Counts {
                for _ in 0..<80 {
                    if let result = frames.rows.last(where: predicate) { return result }
                    try await Task.sleep(for: .milliseconds(100))
                }
                print("last received", frames.rows.last as Any)
                throw ProbeError.capture
            }
            let first = try await waitFor { $0.cyan > 500 }
            let pair = Pair(source: local, output: first)
            print("main", local, "presentation", first)
            guard local.cyan > 500, local.magenta > 500 else { throw ProbeError.unexpectedPixels }
            try Data().write(to: URL(fileURLWithPath: args[5]))
            let second = try await waitFor { $0.green > 500 && $0.cyan < first.cyan / 4 }
            print("after changing the public window", second, "frames", frames.rows.count)
            let beforeOverview = frames.rows.count
            guard NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app")) else { throw ProbeError.unavailable }
            do {
                defer {
                    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
                    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
                }
                try await Task.sleep(for: .milliseconds(1200))
            }
            try await Task.sleep(for: .milliseconds(500))
            let overviewFrames = frames.rows.count - beforeOverview
            print("overview transition frames", overviewFrames, "peak private marker count", frames.rows.map(\.magenta).max() ?? -1)
            guard overviewFrames > 0, frames.rows.allSatisfy({ $0.magenta == 0 }) else { throw ProbeError.unexpectedPixels }
            struct Evidence: Encodable {
                let macOS: String
                let baseline: Pair
                let afterChange: Counts
                let receivedFrames: Int
                let overviewTransitionFrames: Int
                let maximumPrivateMarkerPixels: Int
            }
            let evidence = Evidence(macOS: ProcessInfo.processInfo.operatingSystemVersionString, baseline: pair,
                afterChange: second, receivedFrames: frames.rows.count, overviewTransitionFrames: overviewFrames,
                maximumPrivateMarkerPixels: frames.rows.map(\.magenta).max() ?? -1)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(evidence).write(to: URL(fileURLWithPath: args[4]), options: .atomic)
            try await receiver.stopCapture()
            return
        }
        guard args.count == 4 else { throw ProbeError.arguments }
        let source = CGMainDisplayID()
        let control = Process()
        control.executableURL = URL(fileURLWithPath: args[1])
        let change = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: change) }
        control.arguments = ["control", change.path]
        try control.run()
        defer { if control.isRunning { control.terminate(); control.waitUntilExit() } }
        try await Task.sleep(for: .seconds(1))
        let privateMarker = window(.magenta, width: 200)
        // Deliberately capture-readable locally. Exclusion must come from the
        // production presentation stream, independently of NSWindow.sharingType.
        privateMarker.sharingType = .readOnly
        let presentation = PresentationDisplay.shared
        presentation.start()
        defer { presentation.stop(); privateMarker.orderOut(nil) }
        for _ in 0..<100 {
            if presentation.isReady || presentation.message != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard presentation.isReady else {
            print("Presentation startup:", presentation.message ?? "no complete frame", "source", source, "main", CGMainDisplayID())
            for screen in NSScreen.screens {
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
                print("display", id, screen.localizedName, screen.frame, "mirrored", CGDisplayIsInMirrorSet(id))
            }
            throw ProbeError.readiness
        }
        guard let screen = NSScreen.screens.first(where: { $0.localizedName == "Wisp Presentation" }),
              let output = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { throw ProbeError.unavailable }
        let probeURL = URL(fileURLWithPath: args[3])
        let sampler = Process()
        print("Opening receiver for display", output)
        sampler.executableURL = probeURL
        sampler.arguments = ["sample", String(source), output.stringValue, args[2], change.path]
        try sampler.run()
        let deadline = ContinuousClock.now + .seconds(25)
        while sampler.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard !sampler.isRunning else { sampler.terminate(); throw ProbeError.capture }
        guard sampler.terminationStatus == 0 else {
            print("Presenter state during receiver test:", presentation.isReady, presentation.message ?? "no error")
            throw ProbeError.unexpectedPixels
        }
        presentation.stop()
        func disconnected() throws -> Bool {
            var total: UInt32 = 0
            guard CGGetOnlineDisplayList(0, nil, &total) == .success, total > 0 else { throw ProbeError.unavailable }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(total))
            guard CGGetOnlineDisplayList(total, &ids, &total) == .success else { throw ProbeError.unavailable }
            let online = ids.prefix(Int(total))
            return online.contains(source) && !online.contains(output.uint32Value)
        }
        for _ in 0..<50 {
            if try disconnected() { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !presentation.isReady, !presentation.isOpen, try disconnected() else { throw ProbeError.unavailable }
        print("Presentation display disconnected.")
    }

    @MainActor private static func window(_ color: NSColor, width: CGFloat) -> NSWindow {
        let screen = NSScreen.screens.first!.frame
        let rect = CGRect(x: screen.midX - width / 2, y: screen.midY - 95, width: width, height: 190)
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = color == .magenta ? .popUpMenu : .floating
        window.backgroundColor = color
        window.orderFrontRegardless()
        return window
    }

    fileprivate static func measure(_ image: CGImage) -> Counts {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        return bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let pixels = raw.bindMemory(to: UInt8.self)
            var result = Counts()
            for i in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[i] < 35 && pixels[i+1] > 225 && pixels[i+2] < 35 { result.green += 1 }
                if pixels[i] < 35 && pixels[i+1] > 225 && pixels[i+2] > 225 { result.cyan += 1 }
                if pixels[i] > 225 && pixels[i+1] < 35 && pixels[i+2] > 225 { result.magenta += 1 }
            }
            return result
        }
    }
}
