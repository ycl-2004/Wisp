// Independent recorder + synthetic fixture using production cursor/resize code.
// No Wisp settings, models or user content. Persist only the fixture rectangle.
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreImage
import SwiftUI

// In-memory settings only; compile with production ScreenPrivacy as well.
@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    var hideFromScreenCapture = true
    @Published var localCursorEnabled = false
}

private struct FixtureInfo: Codable { let frame: CGRect; let windowID: CGWindowID }
private enum Failure: Error { case permissions, display, handshake, image, frames }
private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
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
        var darkMask = [Bool](repeating: false, count: w * h)
        var darkMinX = w, darkMaxX = -1, darkMinY = h, darkMaxY = -1
        let p = bytes.bindMemory(to: UInt8.self)
        for i in stride(from: 0, to: p.count, by: 4) {
            if p[i] < 80 && p[i+1] < 80 && p[i+2] < 80 {
                dark += 1
                darkMask[i / 4] = true
                let x = (i / 4) % w, y = (i / 4) / w
                darkMinX = min(darkMinX, x); darkMaxX = max(darkMaxX, x)
                darkMinY = min(darkMinY, y); darkMaxY = max(darkMaxY, y)
            }
            if p[i] > 200 && p[i+1] < 80 && p[i+2] > 200 { magenta += 1 }
            if p[i] < 80 && p[i+1] > 180 && p[i+2] > 180 { cyan += 1 }
        }
        // On the cyan-only recording, connected black regions are cursor artwork.
        // Count every region rather than only one overall bounding box, so an old
        // stationary pointer plus a current pointer cannot pass as one mouse.
        var pointerComponents = 0
        for index in darkMask.indices where darkMask[index] {
            darkMask[index] = false
            var pending = [index], count = 0
            while let current = pending.popLast() {
                count += 1
                let x = current % w, y = current / w
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) {
                        let neighbor = ny * w + nx
                        if darkMask[neighbor] { darkMask[neighbor] = false; pending.append(neighbor) }
                    }
                }
            }
            if count >= 5 { pointerComponents += 1 }
        }
        return ["dark": dark, "pointerComponents": pointerComponents, "magenta": magenta, "cyan": cyan, "total": w*h,
                "darkMinX": darkMinX, "darkMaxX": darkMaxX, "darkMinY": darkMinY, "darkMaxY": darkMaxY]
    }
}
private func save(_ image: CGImage, _ url: URL) throws {
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure.image }
    try png.write(to: url)
}
@MainActor private func feedbackImage(_ view: NSView) -> CGImage? {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap.cgImage
}
private final class Frames: NSObject, SCStreamOutput, @unchecked Sendable {
    let crop: CGRect
    let context = CIContext()
    var measurements: [[String: Int]] = []
    var stage: String?
    var stages: [String: [[String: Int]]] = [:]
    var last: CGImage?
    init(crop: CGRect) { self.crop = crop }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixel = sample.imageBuffer,
              let a = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = a.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        let ci = CIImage(cvPixelBuffer: pixel)
        guard let image = context.createCGImage(ci, from: ci.extent)?.cropping(to: crop) else { return }
        let measured = pixels(image)
        measurements.append(measured); last = image
        if let stage { stages[stage, default: []].append(measured) }
    }
}
@MainActor private final class ActionTarget: NSObject {
    var clicks = 0
    @objc func clicked(_ sender: Any?) { clicks += 1 }
}
private final class FixturePanel: NSPanel {
    var acceptsKey = true
    override var canBecomeKey: Bool { acceptsKey }
}
private final class ControlWindow: NSWindow, CursorSharingSurface {
    var cursorSharingType: NSWindow.SharingType { .readOnly }
}

@main struct LocalCursorProbe {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("Usage: probe run|fixture OUTPUT_DIRECTORY [--click-effects] [--feedback] [--nonkey] [--translucent]"); return }
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if args[1] == "fixture" { try fixture(output); return }
        guard CGPreflightScreenCaptureAccess(), CGPreflightPostEventAccess() else { throw Failure.permissions }
        let oldPoint = CGEvent(source: nil)!.location
        let oldApp = NSWorkspace.shared.frontmostApplication
        let nonkey = args.contains("--nonkey")
        let child = Process(); child.executableURL = URL(fileURLWithPath: args[0]); child.arguments = ["fixture", output.path]
        if nonkey { child.arguments?.append("--nonkey") }
        if args.contains("--translucent") { child.arguments?.append("--translucent") }
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
        let clickEffects = args.contains("--click-effects")
        if #available(macOS 15.0, *) { config.showMouseClicks = clickEffects }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        // No app/window exclusion by the recorder. Cursor hiding must be performed by the fixture.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let sx = CGFloat(display.width) / display.frame.width, sy = CGFloat(display.height) / display.frame.height
        let region = info.frame.insetBy(dx: 12, dy: 12)
        let crop = CGRect(x: (region.minX-display.frame.minX)*sx, y: (region.minY-display.frame.minY)*sy,
                          width: region.width*sx, height: region.height*sy)
        let parked = CGPoint(x: info.frame.minX+70, y: info.frame.minY+90)
        // Keep an additional stream running across all mode changes and native
        // gestures. No warm-up frames are discarded from this transition trace.
        let transitions = Frames(crop: crop)
        let transitionQueue = DispatchQueue(label: "cursor.probe.transitions")
        let transitionStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try transitionStream.addStreamOutput(transitions, type: .screen, sampleHandlerQueue: transitionQueue)
        try await transitionStream.startCapture()
        var rows: [[String: Any]] = []
        for mode in (nonkey ? ["off", "inactive", "on", "restored"] : ["off", "on", "restored"]) {
            try mode.write(to: output.appendingPathComponent("phase"), atomically: true, encoding: .utf8)
            // Establish native key focus before measuring; launching a regular
            // app from a background runner does not guarantee activation.
            if nonkey && mode == "inactive" {
                // A click can activate even a non-key panel. Test the island's
                // background hover path with a different foreground application.
                try await Task.sleep(for: .milliseconds(150))
                oldApp?.activate(options: [])
                move(parked)
            } else {
                // macOS may defer the first activation during app launch. Wait
                // for the synthetic process to own focus before any measured input.
                for _ in 0..<4 {
                    NSRunningApplication(processIdentifier: child.processIdentifier)?.activate(options: [.activateAllWindows])
                    try await Task.sleep(for: .milliseconds(250))
                    if NSRunningApplication(processIdentifier: child.processIdentifier)?.isActive == true { break }
                }
                guard NSRunningApplication(processIdentifier: child.processIdentifier)?.isActive == true else { throw Failure.handshake }
                click(parked)
            }
            try await Task.sleep(for: .milliseconds(600))
            let before = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json"))) as? [String: Any]
            if nonkey && mode == "inactive" {
                guard before?["active"] as? Bool == false, before?["key"] as? Bool == false else { throw Failure.handshake }
            } else {
                guard before?["active"] as? Bool == true else { throw Failure.handshake }
            }
            let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let image = shot.cropping(to: crop) else { throw Failure.image }
            try save(image, output.appendingPathComponent("\(mode)-sck-shot.png"))
            let frames = Frames(crop: crop); let queue = DispatchQueue(label: "cursor.probe.frames")
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            // ScreenCaptureKit may deliver one buffered frame from before the
            // privacy-mode transition. Warm the stream, then only measure fresh
            // frames produced after the mode is settled.
            try await Task.sleep(for: .milliseconds(220))
            queue.sync {
                frames.measurements.removeAll(keepingCapacity: true)
                frames.last = nil
            }
            // Real movement makes the positive control exercise motion, not only a parked cursor.
            for n in 0..<12 {
                let point = CGPoint(x: parked.x+CGFloat(n)*7, y: parked.y)
                move(point)
                if clickEffects {
                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                    try await Task.sleep(for: .milliseconds(70))
                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
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
                                      "distinctPointerPositions": Set(values.map { "\($0["darkMinX"]!):\($0["darkMinY"]!)" }).count,
                                      "systemExit": system.terminationStatus]
            if system.terminationStatus == 0, let cg = NSImage(contentsOf: systemURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { row["systemScreenshot"] = pixels(cg) }
            let movie = Process(); movie.executableURL = system.executableURL
            let movieURL = output.appendingPathComponent("\(mode)-system.mov")
            movie.arguments = ["-x", "-v", "-V", "2", "-C", rectArg, movieURL.path]
            try movie.run(); movie.waitUntilExit()
            row["systemVideoExit"] = movie.terminationStatus
            if movie.terminationStatus == 0 {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movieURL))
                generator.appliesPreferredTrackTransform = true
                // In private mode the cursor is omitted. Always keep background
                // controls; require a pointer only for the unlocked controls.
                for second in [0.4, 1.0, 1.5] {
                    guard let frame = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image else { continue }
                    let measured = pixels(frame)
                    if measured["cyan", default: 0] > 0 && (mode == "on" || measured["dark", default: 0] > 0) {
                        row["systemVideo"] = measured
                        try save(frame, output.appendingPathComponent("\(mode)-system-video.png"))
                        break
                    }
                }
            }
            let stateData = try Data(contentsOf: output.appendingPathComponent("state.json"))
            row["fixture"] = try JSONSerialization.jsonObject(with: stateData)
            rows.append(row)
        }
        if nonkey {
            try await transitionStream.stopCapture()
            try writeJSON(["os": ProcessInfo.processInfo.operatingSystemVersionString,
                           "presentation": "single-private", "nonKeyOnly": true, "showsCursor": true, "recorderExcludesWindows": false,
                           "transitionFrames": transitionQueue.sync { transitions.measurements },
                           "modes": rows], output.appendingPathComponent("result.json"))
            return
        }
        try "on".write(to: output.appendingPathComponent("phase"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(300))
        transitionQueue.sync { transitions.stage = "button" }
        // Coordinates use the fixture's top-left CG frame. Native button and NSTextView.
        click(CGPoint(x: info.frame.minX+185, y: info.frame.maxY-67))
        try await Task.sleep(for: .milliseconds(150))
        transitionQueue.sync { transitions.stage = "typing" }
        click(CGPoint(x: info.frame.minX+145, y: info.frame.maxY-125))
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
        let text = Array("cursor test".utf16)
        text.withUnsafeBufferPointer { down.keyboardSetUnicodeString(stringLength: text.count, unicodeString: $0.baseAddress!) }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(250))
        transitionQueue.sync { transitions.stage = "text-selection" }
        await drag(from: CGPoint(x: info.frame.minX+94, y: info.frame.maxY-156), dx: 92, dy: 0)
        try await Task.sleep(for: .milliseconds(150))
        let selection = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json")))
        transitionQueue.sync { transitions.stage = "scrolling" }
        let scrollPoint = CGPoint(x: info.frame.minX+240, y: info.frame.maxY-250)
        move(scrollPoint)
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -140, wheel2: 0, wheel3: 0)!
        scroll.location = scrollPoint; scroll.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(300))
        let scrolling = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json")))
        transitionQueue.sync { transitions.stage = "menu-selection" }
        click(CGPoint(x: info.frame.minX+490, y: info.frame.maxY-67))
        try await Task.sleep(for: .milliseconds(200))
        // Complete the native tracking loop with an actual menu-item click.
        // Posting key events from this independent runner does not reliably end
        // popup tracking; the next drag would otherwise only dismiss the menu.
        click(CGPoint(x: info.frame.minX+490, y: info.frame.maxY-67+22))
        try await Task.sleep(for: .milliseconds(500))
        let menuSelection = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json")))
        transitionQueue.sync { transitions.stage = "drag-resize" }
        // Exercise production performDrag and custom resize. No intercepted/replayed clicks.
        await drag(from: CGPoint(x: info.frame.minX+230, y: info.frame.minY+15), dx: 35, dy: 20)
        await drag(from: CGPoint(x: info.frame.maxX+35-3, y: info.frame.maxY+20-3), dx: 25, dy: 15)
        // Coalesced drag events may leave the released pointer just outside the
        // resized edge. Return inside before asserting the in-app lock state.
        move(CGPoint(x: info.frame.midX, y: info.frame.midY))
        try await Task.sleep(for: .milliseconds(200))
        let interaction = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json")))
        transitionQueue.sync { transitions.stage = nil }
        move(CGPoint(x: info.frame.minX-60, y: info.frame.minY-60))
        try await Task.sleep(for: .milliseconds(200))
        let outside = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json")))
        try await transitionStream.stopCapture()
        // Check restoration after native menu tracking too, since AppKit's
        // unmatched unhide must neither expose a second cursor nor consume a
        // hide that leaves the system pointer stuck after Wisp is disabled.
        try "off".write(to: output.appendingPathComponent("phase"), atomically: true, encoding: .utf8)
        move(parked)
        try await Task.sleep(for: .milliseconds(300))
        let restoredShot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let restoredImage = restoredShot.cropping(to: crop) else { throw Failure.image }
        let restoredState = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json")))
        let report: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "presentation": "single-private", "translucent": args.contains("--translucent"),
            "transitionFrames": transitionQueue.sync { transitions.measurements },
            "interactionFrames": transitionQueue.sync { transitions.stages }, "menuSelection": menuSelection,
            "showsCursor": true, "showMouseClicks": clickEffects, "recorderExcludesWindows": false, "modes": rows,
            "nativeInteraction": interaction, "textSelection": selection, "scrolling": scrolling, "afterLeaving": outside,
            "afterMenuRestored": restoredState, "afterMenuScreenshot": pixels(restoredImage)]
        try writeJSON(report, output.appendingPathComponent("result.json"))
        if args.contains("--feedback") {
            var samples: [[String: Any]] = []
            // Return the fixture to its initial frame before testing held buttons.
            for mode in ["feedback-off", "feedback-on"] {
                try mode.write(to: output.appendingPathComponent("phase"), atomically: true, encoding: .utf8)
                try await Task.sleep(for: .milliseconds(350))
                for (index, name) in ["press", "icon", "plain"].enumerated() {
                    let point = CGPoint(x: info.frame.minX + 50, y: info.frame.maxY - 250 + CGFloat(index) * 50)
                    move(point)
                    try await Task.sleep(for: .milliseconds(200))
                    let before = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json"))) as! [String: Any]
                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                    try await Task.sleep(for: .milliseconds(250))
                    let held = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json"))) as! [String: Any]
                    try FileManager.default.copyItem(at: output.appendingPathComponent("feedback.png"), to: output.appendingPathComponent("\(mode)-\(name)-held.png"))
                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                    try await Task.sleep(for: .milliseconds(250))
                    let after = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json"))) as! [String: Any]
                    samples.append(["mode": mode, "style": name, "before": before["feedbackHash"]!, "held": held["feedbackHash"]!,
                                    "beforeClicks": before["feedbackClicks"]!, "afterClicks": after["feedbackClicks"]!])
                }
            }
            try writeJSON(["samples": samples], output.appendingPathComponent("feedback-result.json"))
        }
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
        WispCursorPolicy.install()
        ScreenPrivacy.start()
        guard NSScreen.screens.count == 1, let screen = NSScreen.main else { throw Failure.display }
        let background = ControlWindow(contentRect: NSRect(x: screen.visibleFrame.midX-330, y: screen.visibleFrame.midY-240, width: 660, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false; background.backgroundColor = .cyan; background.level = .floating
        // The control window must stay shared despite the production lifecycle sweep.
        // It uses an explicit test-only sharing override, never app preferences.
        background.orderFrontRegardless()
        let panel = FixturePanel(contentRect: background.frame.insetBy(dx: 40, dy: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.backgroundColor = .magenta; panel.level = .floating
        if CommandLine.arguments.contains("--translucent") {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.alphaValue = 0.35
        }
        panel.hidesOnDeactivate = false
        panel.sharingType = .none; panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 320, height: 220); panel.maxSize = NSSize(width: 900, height: 700)
        let content = NSView(frame: NSRect(origin: .zero, size: panel.frame.size)); panel.contentView = content
        let hosted = NSHostingView(rootView: Color(nsColor: .magenta))
        hosted.frame = content.bounds; hosted.autoresizingMask = [.width, .height]
        hosted.wantsLayer = true; content.addSubview(hosted)
        let target = ActionTarget()
        let button = NSButton(title: "Native click", target: target, action: #selector(ActionTarget.clicked(_:)))
        button.frame = NSRect(x: 130, y: 50, width: 160, height: 34); content.addSubview(button)
        let popup = NSPopUpButton(frame: NSRect(x: 440, y: 50, width: 115, height: 34), pullsDown: false)
        popup.addItems(withTitles: ["Synthetic A", "Synthetic B", "Synthetic C"])
        content.addSubview(popup)
        let text = NSTextView(frame: NSRect(x: 90, y: 105, width: 340, height: 65)); text.font = .systemFont(ofSize: 16); content.addSubview(text)
        let scrolling = NSScrollView(frame: NSRect(x: 90, y: 190, width: 340, height: 120))
        let document = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 1400))
        document.string = (1...80).map { "Synthetic row \($0)" }.joined(separator: "\n")
        scrolling.documentView = document; scrolling.hasVerticalScroller = true
        content.addSubview(scrolling)
        let feedbackTarget = ActionTarget()
        let feedback = NSHostingView(rootView: VStack(spacing: 20) {
            Button { feedbackTarget.clicked(nil) } label: { Text("Press").frame(width: 50, height: 30).background(.green) }
                .buttonStyle(PressFeedbackButtonStyle())
            Button { feedbackTarget.clicked(nil) } label: { Image(systemName: "gearshape").background(.green) }
                .buttonStyle(IconButtonStyle(size: 18))
            Button { feedbackTarget.clicked(nil) } label: { Text("Plain").frame(width: 50, height: 30).background(.green) }
                .buttonStyle(PrivacyPlainButtonStyle())
        }.frame(width: 60, height: 150).background(.white))
        feedback.frame = NSRect(x: 20, y: 115, width: 60, height: 150)
        content.addSubview(feedback)
        let drag = WindowDragArea.DragView(frame: NSRect(x: 30, y: content.bounds.height-30, width: 450, height: 30))
        drag.autoresizingMask = [.width, .minYMargin]; content.addSubview(drag)
        let resize = PanelResizeOverlay(frame: content.bounds); resize.autoresizingMask = [.width, .height]; content.addSubview(resize)
        panel.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        let controller = LocalCursorController()
        let f = panel.frame
        let info = FixtureInfo(frame: CGRect(x: f.minX, y: screen.frame.maxY-f.maxY, width: f.width, height: f.height), windowID: CGWindowID(panel.windowNumber))
        FileHandle.standardOutput.write(try JSONEncoder().encode(info))
        var phase = ""
        var phaseStart = ProcessInfo.processInfo.systemUptime
        var phaseCPUStart = cpuSeconds()
        var cursorSamples = 0, duplicateOverlaySamples = 0
        let cursorSampler = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                let overlays = NSApp.windows.filter { $0 is CursorPresentationWindow && $0.isVisible }.count
                // System-pointer visibility is checked in independent SCK pixels.
                // Counting our surfaces alone must not claim the system is hidden.
                cursorSamples += 1
                if overlays > 1 { duplicateOverlaySamples += 1 }
            }
        }
        RunLoop.main.add(cursorSampler, forMode: .common)
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let next = (try? String(contentsOf: output.appendingPathComponent("phase"), encoding: .utf8)) ?? "off"
                if next == "quit" { controller.stop(); app.terminate(nil); return }
                if phase != next {
                    phase = next
                    phaseStart = ProcessInfo.processInfo.systemUptime
                    phaseCPUStart = cpuSeconds()
                    cursorSamples = 0
                    duplicateOverlaySamples = 0
                    let locked = next == "on" || next == "feedback-on" || next == "inactive"
                    AppSettings.shared.localCursorEnabled = locked
                    controller.setEnabled(locked)
                    if next.hasPrefix("feedback-") { panel.setFrame(f, display: true) }
                    if CommandLine.arguments.contains("--nonkey") {
                        panel.acceptsKey = !locked
                        if next == "inactive" { panel.resignKey(); app.deactivate() }
                        else if !locked { panel.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true) }
                    }
                }
                let localFrame = controller.localWindow.frame
                var feedbackHash = ""
                if next.hasPrefix("feedback-"), let image = feedbackImage(feedback) {
                    try? save(image, output.appendingPathComponent("feedback.png"))
                    if let data = image.dataProvider?.data {
                        feedbackHash = String((data as Data).reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 })
                    }
                }
                try? writeJSON(["phase": phase, "active": app.isActive, "key": panel.isKeyWindow, "replacing": controller.isReplacingCursor,
                    "clicks": target.clicks, "text": text.string, "selectionLength": text.selectedRange().length, "scrollY": scrolling.contentView.bounds.origin.y,
                    "popupSelection": popup.indexOfSelectedItem,
                    "windowFrame": NSStringFromRect(panel.frame), "cursorFrame": NSStringFromRect(localFrame),
                    "localVisible": controller.localWindow.isVisible,
                    "cursorWindowCount": NSApp.windows.filter { $0 is CursorPresentationWindow && $0.isVisible }.count,
                    "cursorSamples": cursorSamples, "duplicateOverlaySamples": duplicateOverlaySamples,
                    "parentAttached": controller.localWindow.parent === panel,
                    "feedbackHash": feedbackHash, "feedbackClicks": feedbackTarget.clicks,
                    "phaseSeconds": ProcessInfo.processInfo.systemUptime - phaseStart,
                    "phaseCPUSeconds": cpuSeconds() - phaseCPUStart,
                    "arrow": NSCursor.current === NSCursor.arrow], output.appendingPathComponent("state.json"))
                if controller.isReplacingCursor, !FileManager.default.fileExists(atPath: output.appendingPathComponent("local-pointer.png").path),
                   let bitmap = controller.overlay.bitmapImageRepForCachingDisplay(in: controller.overlay.bounds) {
                    controller.overlay.cacheDisplay(in: controller.overlay.bounds, to: bitmap)
                    if let image = bitmap.cgImage { try? save(image, output.appendingPathComponent("local-pointer.png")) }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime([background, panel, target, controller, timer, cursorSampler] as [Any]) { app.run() }
    }
}
