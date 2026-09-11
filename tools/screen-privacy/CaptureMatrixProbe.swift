import AVFoundation
// Independent-process, synthetic-only capture matrix. Compile with production
// ScreenPrivacy.swift; no Wisp preferences, models, screen images or credentials are saved.
import AppKit
import CoreImage
import ScreenCaptureKit

@MainActor final class AppSettings {
  static let shared = AppSettings()
  var hideFromScreenCapture = true
}

private struct Target: Codable {
  let name: String
  let id: CGWindowID
  let frame: CGRect
}
private struct Handshake: Codable {
  let targets: [Target]
  let displays: Int
}
private enum Failure: Error { case permission, display, handshake, sample }

private func fractions(_ image: CGImage, size: Int = 80) -> [String: Double] {
  // Downsample only the synthetic target rectangle. Never retain a full desktop frame.
  var bytes = [UInt8](repeating: 0, count: size * size * 4)
  return bytes.withUnsafeMutableBytes { raw in
    let ctx = CGContext(
      data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
      bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let p = raw.bindMemory(to: UInt8.self)
    var magenta = 0
    var cyan = 0
    for i in stride(from: 0, to: p.count, by: 4) {
      if p[i] > 200 && p[i + 1] < 70 && p[i + 2] > 200 { magenta += 1 }
      if p[i] < 70 && p[i + 1] > 200 && p[i + 2] > 200 { cyan += 1 }
    }
    return [
      "magenta": Double(magenta) / Double(size * size), "cyan": Double(cyan) / Double(size * size),
    ]
  }
}
private func measure(_ image: CGImage, targets: [Target], display: CGRect) -> [String: [String:
  Double]]
{
  var result: [String: [String: Double]] = [:]
  let sx = Double(image.width) / display.width
  let sy = Double(image.height) / display.height
  for target in targets {
    let f = target.frame.insetBy(dx: 12, dy: 12)
    let crop = CGRect(
      x: (f.minX - display.minX) * sx, y: (f.minY - display.minY) * sy,
      width: f.width * sx, height: f.height * sy)
    if let region = image.cropping(to: crop) { result[target.name] = fractions(region) }
  }
  return result
}
private final class Frames: NSObject, SCStreamOutput, @unchecked Sendable {
  let targets: [Target]
  let display: CGRect
  let context = CIContext()
  var rows: [[String: [String: Double]]] = []
  init(_ targets: [Target], _ display: CGRect) {
    self.targets = targets
    self.display = display
  }
  func stream(
    _ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType
  ) {
    guard type == .screen, sample.isValid,
      let items = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let raw = items.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
      let pixel = sample.imageBuffer
    else { return }
    let ci = CIImage(cvPixelBuffer: pixel)
    guard let image = context.createCGImage(ci, from: ci.extent) else { return }
    rows.append(measure(image, targets: targets, display: display))
  }
}

@main struct MatrixProbe {
  @MainActor static func main() async throws {
    let args = CommandLine.arguments
    if args.contains("fixture") {
      try fixture(hidden: args.contains("hidden"))
      return
    }
    guard args.count >= 3, ["visible", "hidden"].contains(args[1]) else {
      print("Usage: probe visible|hidden OUTPUT.json [panel-settings] [mission-control]")
      return
    }
    guard CGPreflightScreenCaptureAccess() else { throw Failure.permission }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: args[0])
    child.arguments = ["fixture", args[1]]
    if args.contains("panel-settings") { child.arguments?.append("panel-settings") }
    let pipe = Pipe()
    child.standardOutput = pipe
    try child.run()
    defer {
      if child.isRunning {
        child.terminate()
        child.waitUntilExit()
      }
    }
    let data = pipe.fileHandleForReading.availableData
    let fixture = try JSONDecoder().decode(Handshake.self, from: data)
    guard fixture.displays == 1 else { throw Failure.display }  // fail explicitly, never silently pick the wrong display
    try await Task.sleep(for: .milliseconds(600))
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard content.displays.count == 1, let display = content.displays.first else {
      throw Failure.display
    }
    let config = SCStreamConfiguration()
    config.width = display.width
    config.height = display.height
    config.showsCursor = false
    config.capturesAudio = false
    config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
    let filters: [(String, SCContentFilter)] = [
      ("exclude-no-windows", SCContentFilter(display: display, excludingWindows: [])),
      (
        "include-all-applications",
        SCContentFilter(display: display, including: content.applications, exceptingWindows: [])
      ),
      (
        "exclude-no-applications",
        SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
      ),
      ("include-all-windows", SCContentFilter(display: display, including: content.windows)),
    ]
    var shots: [[String: Any]] = []
    var streams: [[String: Any]] = []
    var direct: [[String: Any]] = []
    for (name, filter) in filters {
      do {
        let shot = try await SCScreenshotManager.captureImage(
          contentFilter: filter, configuration: config)
        shots.append([
          "path": name, "targets": measure(shot, targets: fixture.targets, display: display.frame),
        ])
      } catch { shots.append(["path": name, "error": error.localizedDescription]) }
    }
    let frames = Frames(fixture.targets, display.frame)
    let queue = DispatchQueue(label: "matrix.frames")
    let stream = SCStream(filter: filters[0].1, configuration: config, delegate: nil)
    try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
    try await stream.startCapture()
    for (index, item) in filters.enumerated() {
      queue.sync { frames.rows = [] }
      // Clear before updating so no transition callback is discarded.
      if index > 0 { try await stream.updateContentFilter(item.1) }
      try await Task.sleep(for: .seconds(1))
      let rows = queue.sync { frames.rows }
      streams.append([
        "path": item.0, "liveUpdate": index > 0, "completeFrames": rows.count, "frames": rows,
      ])
    }
    try await stream.stopCapture()
    for target in fixture.targets {
      guard let window = content.windows.first(where: { $0.windowID == target.id }) else {
        direct.append(["target": target.name, "listed": false])
        continue
      }
      do {
        let c = SCStreamConfiguration()
        c.width = Int(window.frame.width)
        c.height = Int(window.frame.height)
        c.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
          contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: c)
        direct.append(["target": target.name, "listed": true, "pixels": fractions(image)])
      } catch {
        direct.append(["target": target.name, "listed": true, "error": error.localizedDescription])
      }
    }
    // The system movie recorder is a separate capture route from our SCStream.
    // Record only the synthetic-window bounding box, with no audio, then remove it.
    let recordingRect = fixture.targets.reduce(CGRect.null) { $0.union($1.frame) }
    let movie = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wisp-matrix-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: movie) }
    let recorder = Process()
    recorder.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    recorder.arguments = [
      "-x", "-v", "-V2",
      "-R\(Int(recordingRect.minX)),\(Int(recordingRect.minY)),\(Int(recordingRect.width)),\(Int(recordingRect.height))",
      movie.path,
    ]
    try recorder.run()
    let deadline = Date().addingTimeInterval(15)
    while recorder.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
    if recorder.isRunning { recorder.terminate() }
    recorder.waitUntilExit()
    var systemMovie: [String: Any] = ["exitStatus": recorder.terminationStatus]
    if recorder.terminationStatus == 0 {
      do {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.appliesPreferredTrackTransform = true
        var samples: [[String: [String: Double]]] = []
        for tenth in [2, 6, 10, 14, 18] {
          let frame = try await generator.image(at: CMTime(value: Int64(tenth), timescale: 10))
          samples.append(measure(frame.image, targets: fixture.targets, display: recordingRect))
        }
        systemMovie["sampledFrames"] = samples
      } catch { systemMovie["error"] = error.localizedDescription }
    }
    var mission: [String: Any] = [:]
    if args.contains("mission-control") {
      // Explicit opt-in: temporarily enters Mission Control, then sends Escape.
      let opened = NSWorkspace.shared.open(
        URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
      mission["openRequested"] = opened
      try await Task.sleep(for: .seconds(1))
      do {
        let image = try await SCScreenshotManager.captureImage(
          contentFilter: filters[0].1, configuration: config)
        mission["wholeDisplayMarkerFractions"] = fractions(image, size: 1200)
      } catch { mission["error"] = error.localizedDescription }
      CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
      CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    }
    let report: [String: Any] = [
      "mode": args[1], "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "syntheticOnly": true, "separateProcesses": true, "displayCount": content.displays.count,
      "shots": shots, "streams": streams, "directWindowShots": direct, "systemMovie": systemMovie,
      "settingsUsesPanel": args.contains("panel-settings"), "missionControl": mission,
      "scope":
        "Zero markers without a visible paired control is inconclusive. Not a universal hiding verdict.",
    ]
    let json = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: args[2]))
    print("Saved matrix: \(args[2])")
  }

  @MainActor static func fixture(hidden: Bool) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let screen = NSScreen.screens.first else { throw Failure.display }
    AppSettings.shared.hideFromScreenCapture = hidden
    // No global observer: the unprotected cyan control and video layer must stay .readOnly.
    var windows: [NSWindow] = []
    var targets: [Target] = []
    for (i, name) in ["control", "panel", "settings", "video"].enumerated() {
      let rect = CGRect(
        x: screen.frame.midX - 460 + Double(i) * 230, y: screen.frame.midY - 100, width: 210,
        height: 160)
      let window: NSWindow =
        (name == "panel"
          || (name == "settings" && CommandLine.arguments.contains("panel-settings")))
        ? NSPanel(
          contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
          defer: false)
        : NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = "Wisp Matrix \(name)"
      window.level = .floating
      let view = NSView(frame: CGRect(origin: .zero, size: rect.size))
      view.wantsLayer = true
      view.layer?.backgroundColor = (name == "control" ? NSColor.cyan : NSColor.magenta).cgColor
      window.contentView = view
      if name == "panel" || name == "settings" { ScreenPrivacy.apply(to: window) }
      if name == "video" {
        view.layer?.backgroundColor = NSColor.black.cgColor
        let video = AVSampleBufferDisplayLayer()
        video.frame = view.bounds
        video.videoGravity = .resize
        video.preventsCapture = hidden
        view.layer?.addSublayer(video)
        video.sampleBufferRenderer.enqueue(try videoSample())
      }
      window.orderFrontRegardless()
      windows.append(window)
      targets.append(
        Target(
          name: name, id: CGWindowID(window.windowNumber),
          frame: CGRect(
            x: rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height))
      )
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    let handshake = Handshake(targets: targets, displays: NSScreen.screens.count)
    FileHandle.standardOutput.write(try JSONEncoder().encode(handshake))
    withExtendedLifetime(windows) { app.run() }
  }
  static func videoSample() throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, 210, 160, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
      let pixel
    else { throw Failure.sample }
    CVPixelBufferLockBaseAddress(pixel, [])
    let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<160 {
      for x in 0..<210 {
        let p = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
        base[p] = 255
        base[p + 1] = 0
        base[p + 2] = 255
        base[p + 3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format!,
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample
    else { throw Failure.sample }
    let attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)! as NSArray
    (attachments[0] as! NSMutableDictionary)[kCMSampleAttachmentKey_DisplayImmediately] = true
    return sample
  }
}
