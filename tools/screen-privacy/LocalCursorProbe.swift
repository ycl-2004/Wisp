// Independent recorder + synthetic fixture using production cursor/resize code.
// No Wisp settings, models or user content. Persist only the fixture rectangle.
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreImage

private struct FixtureInfo: Codable { let frame: CGRect; let windowID: CGWindowID }
private enum Failure: Error { case permissions, display, handshake, image, frames }
private func writeJSON(_ object: [String: Any], _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}
private func pixels(_ image: CGImage) -> [String: Int] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    return data.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var dark = 0, magenta = 0, cyan = 0
        let p = bytes.bindMemory(to: UInt8.self)
        for i in stride(from: 0, to: p.count, by: 4) {
            if p[i] < 80 && p[i+1] < 80 && p[i+2] < 80 { dark += 1 }
            if p[i] > 200 && p[i+1] < 80 && p[i+2] > 200 { magenta += 1 }
            if p[i] < 80 && p[i+1] > 180 && p[i+2] > 180 { cyan += 1 }
        }
        return ["dark": dark, "magenta": magenta, "cyan": cyan, "total": w*h]
    }
}
private func save(_ image: CGImage, _ url: URL) throws {
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure.image }
    try png.write(to: url)
}
private final class Frames: NSObject, SCStreamOutput, @unchecked Sendable {
    let crop: CGRect
    let context = CIContext()
    var measurements: [[String: Int]] = []
    var last: CGImage?
    init(crop: CGRect) { self.crop = crop }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixel = sample.imageBuffer,
              let a = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = a.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        let ci = CIImage(cvPixelBuffer: pixel)
        guard let image = context.createCGImage(ci, from: ci.extent)?.cropping(to: crop) else { return }
        measurements.append(pixels(image)); last = image
    }
}
@MainActor private final class ActionTarget: NSObject {
    var clicks = 0
    @objc func clicked(_ sender: Any?) { clicks += 1 }
}
private final class FixturePanel: NSPanel { override var canBecomeKey: Bool { true } }

@main struct LocalCursorProbe {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("Usage: probe run|fixture OUTPUT_DIRECTORY"); return }
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if args[1] == "fixture" { try fixture(output); return }
        guard CGPreflightScreenCaptureAccess(), CGPreflightPostEventAccess() else { throw Failure.permissions }
        let oldPoint = CGEvent(source: nil)!.location
        let oldApp = NSWorkspace.shared.frontmostApplication
        let child = Process(); child.executableURL = URL(fileURLWithPath: args[0]); child.arguments = ["fixture", output.path]
        let pipe = Pipe(); child.standardOutput = pipe
        try child.run()
        defer {
            try? "quit".write(to: output.appendingPathComponent("phase"), atomically: true, encoding: .utf8)
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            CGWarpMouseCursorPosition(oldPoint)
            oldApp?.activate(options: [])
        }
        let info = try JSONDecoder().decode(FixtureInfo.self, from: pipe.fileHandleForReading.availableData)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard content.displays.count == 1, let display = content.displays.first else { throw Failure.display }
        let config = SCStreamConfiguration()
        config.width = display.width; config.height = display.height; config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        // No app/window exclusion by the recorder. Cursor hiding must be performed by the fixture.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let sx = CGFloat(display.width) / display.frame.width, sy = CGFloat(display.height) / display.frame.height
        let region = info.frame.insetBy(dx: 12, dy: 12)
        let crop = CGRect(x: (region.minX-display.frame.minX)*sx, y: (region.minY-display.frame.minY)*sy,
                          width: region.width*sx, height: region.height*sy)
        let parked = CGPoint(x: info.frame.minX+70, y: info.frame.minY+90)
        var rows: [[String: Any]] = []
        for mode in ["off", "on", "restored"] {
            try mode.write(to: output.appendingPathComponent("phase"), atomically: true, encoding: .utf8)
            move(parked)
            try await Task.sleep(for: .milliseconds(600))
            let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let image = shot.cropping(to: crop) else { throw Failure.image }
            try save(image, output.appendingPathComponent("\(mode)-sck-shot.png"))
            let frames = Frames(crop: crop); let queue = DispatchQueue(label: "cursor.probe.frames")
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            // Real movement makes the positive control exercise motion, not only a parked cursor.
            for n in 0..<12 {
                move(CGPoint(x: parked.x+CGFloat(n), y: parked.y))
                try await Task.sleep(for: .milliseconds(40))
            }
            try await stream.stopCapture()
            let values = queue.sync { frames.measurements }
            guard let last = queue.sync(execute: { frames.last }), !values.isEmpty else { throw Failure.frames }
            try save(last, output.appendingPathComponent("\(mode)-sck-stream.png"))
            let system = Process(); system.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let systemURL = output.appendingPathComponent("\(mode)-system.png")
            let rectArg = "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))"
            system.arguments = ["-x", "-C", rectArg, systemURL.path]
            try system.run(); system.waitUntilExit()
            var row: [String: Any] = ["mode": mode, "sckScreenshot": pixels(image), "sckFrames": values,
                                      "systemExit": system.terminationStatus]
            if system.terminationStatus == 0, let cg = NSImage(contentsOf: systemURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { row["systemScreenshot"] = pixels(cg) }
            let movie = Process(); movie.executableURL = system.executableURL
            let movieURL = output.appendingPathComponent("\(mode)-system.mov")
            movie.arguments = ["-x", "-v", "-V", "1", "-C", rectArg, movieURL.path]
            try movie.run(); movie.waitUntilExit()
            row["systemVideoExit"] = movie.terminationStatus
            if movie.terminationStatus == 0 {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movieURL))
                generator.appliesPreferredTrackTransform = true
                if let frame = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image {
                    row["systemVideo"] = pixels(frame)
                    try save(frame, output.appendingPathComponent("\(mode)-system-video.png"))
                }
            }
            let stateData = try Data(contentsOf: output.appendingPathComponent("state.json"))
            row["fixture"] = try JSONSerialization.jsonObject(with: stateData)
            rows.append(row)
        }
        try "on".write(to: output.appendingPathComponent("phase"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(300))
        // Coordinates use the fixture's top-left CG frame. Native button and NSTextView.
        click(CGPoint(x: info.frame.minX+185, y: info.frame.maxY-67))
        try await Task.sleep(for: .milliseconds(150))
        click(CGPoint(x: info.frame.minX+145, y: info.frame.maxY-125))
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
        let text = Array("cursor test".utf16)
        text.withUnsafeBufferPointer { down.keyboardSetUnicodeString(stringLength: text.count, unicodeString: $0.baseAddress!) }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(250))
        await drag(from: CGPoint(x: info.frame.minX+94, y: info.frame.maxY-156), dx: 92, dy: 0)
        try await Task.sleep(for: .milliseconds(150))
        let selection = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json")))
        let scrollPoint = CGPoint(x: info.frame.minX+240, y: info.frame.maxY-250)
        move(scrollPoint)
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -140, wheel2: 0, wheel3: 0)!
        scroll.location = scrollPoint; scroll.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(300))
        let scrolling = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json")))
        // Exercise production performDrag and custom resize. No intercepted/replayed clicks.
        await drag(from: CGPoint(x: info.frame.minX+230, y: info.frame.minY+15), dx: 35, dy: 20)
        await drag(from: CGPoint(x: info.frame.maxX+35-3, y: info.frame.maxY+20-3), dx: 25, dy: 15)
        try await Task.sleep(for: .milliseconds(200))
        let interaction = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json")))
        move(CGPoint(x: info.frame.minX-60, y: info.frame.minY-60))
        try await Task.sleep(for: .milliseconds(200))
        let outside = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json")))
        let report: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "showsCursor": true, "recorderExcludesWindows": false, "modes": rows,
            "nativeInteraction": interaction, "textSelection": selection, "scrolling": scrolling, "afterLeaving": outside]
        try writeJSON(report, output.appendingPathComponent("result.json"))
        print("Result: \(output.appendingPathComponent("result.json").path)")
    }

    static func move(_ point: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap) }
    static func click(_ point: CGPoint) {
        move(point)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
    static func drag(from point: CGPoint, dx: CGFloat, dy: CGFloat) async {
        move(point)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        for n in 1...12 {
            try? await Task.sleep(for: .milliseconds(25))
            let p = CGPoint(x: point.x+dx*CGFloat(n)/12, y: point.y+dy*CGFloat(n)/12)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: point.x+dx,y: point.y+dy), mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(100))
    }

    @MainActor static func fixture(_ output: URL) throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        guard NSScreen.screens.count == 1, let screen = NSScreen.main else { throw Failure.display }
        let background = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX-330, y: screen.visibleFrame.midY-240, width: 660, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false; background.backgroundColor = .cyan; background.level = .floating
        background.orderFrontRegardless()
        let panel = FixturePanel(contentRect: background.frame.insetBy(dx: 40, dy: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.backgroundColor = .magenta; panel.level = .floating
        panel.sharingType = .none; panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 320, height: 220); panel.maxSize = NSSize(width: 900, height: 700)
        let content = NSView(frame: NSRect(origin: .zero, size: panel.frame.size)); panel.contentView = content
        let target = ActionTarget()
        let button = NSButton(title: "Native click", target: target, action: #selector(ActionTarget.clicked(_:)))
        button.frame = NSRect(x: 130, y: 50, width: 160, height: 34); content.addSubview(button)
        let text = NSTextView(frame: NSRect(x: 90, y: 105, width: 340, height: 65)); text.font = .systemFont(ofSize: 16); content.addSubview(text)
        let scrolling = NSScrollView(frame: NSRect(x: 90, y: 190, width: 340, height: 120))
        let document = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 1400))
        document.string = (1...80).map { "Synthetic row \($0)" }.joined(separator: "\n")
        scrolling.documentView = document; scrolling.hasVerticalScroller = true
        content.addSubview(scrolling)
        let drag = WindowDragArea.DragView(frame: NSRect(x: 30, y: content.bounds.height-30, width: 450, height: 30))
        drag.autoresizingMask = [.width, .minYMargin]; content.addSubview(drag)
        let resize = PanelResizeOverlay(frame: content.bounds); resize.autoresizingMask = [.width, .height]; content.addSubview(resize)
        panel.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        let controller = LocalCursorController()
        let f = panel.frame
        let info = FixtureInfo(frame: CGRect(x: f.minX, y: screen.frame.maxY-f.maxY, width: f.width, height: f.height), windowID: CGWindowID(panel.windowNumber))
        FileHandle.standardOutput.write(try JSONEncoder().encode(info))
        var phase = ""
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let next = (try? String(contentsOf: output.appendingPathComponent("phase"), encoding: .utf8)) ?? "off"
                if next == "quit" { controller.stop(); app.terminate(nil); return }
                if phase != next { phase = next; controller.setEnabled(next == "on") }
                let localFrame = controller.overlay.frame
                try? writeJSON(["phase": phase, "active": app.isActive, "replacing": controller.isReplacingCursor,
                    "clicks": target.clicks, "text": text.string, "selectionLength": text.selectedRange().length, "scrollY": scrolling.contentView.bounds.origin.y,
                    "windowFrame": NSStringFromRect(panel.frame), "cursorFrame": NSStringFromRect(localFrame)], output.appendingPathComponent("state.json"))
                if controller.isReplacingCursor, !FileManager.default.fileExists(atPath: output.appendingPathComponent("local-pointer.png").path),
                   let bitmap = controller.overlay.bitmapImageRepForCachingDisplay(in: controller.overlay.bounds) {
                    controller.overlay.cacheDisplay(in: controller.overlay.bounds, to: bitmap)
                    if let image = bitmap.cgImage { try? save(image, output.appendingPathComponent("local-pointer.png")) }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime([background, panel, target, controller, timer] as [Any]) { app.run() }
    }
}
