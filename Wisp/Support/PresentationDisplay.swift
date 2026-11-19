import AppKit
import CoreImage
import Combine
import ScreenCaptureKit

/// An extended display with an opaque output window. Only the filtered stream
/// enters this window. Its sharing policy stays readable for meeting clients.
private final class PresentationWindow: NSPanel, FixedWindowSharing {
    var fixedSharingType: NSWindow.SharingType { .readOnly }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PresentationDisplay: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    static let shared = PresentationDisplay()
    @Published private(set) var isOpen = false
    @Published private(set) var isReady = false
    @Published private(set) var message: String?

    private var monitor: PresentationMonitor?
    private var output: NSPanel?
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var imageLayer: CALayer?
    private var stream: SCStream?
    private var session: Task<Void, Never>?
    private var sourceID: CGDirectDisplayID = 0
    private var generation = UUID()

    func setHiding(_ enabled: Bool) {
        ScreenPrivacy.setEnabled(enabled)
        if enabled { start() } else { stop() }
    }

    func start() {
        guard !isOpen else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            message = String(localized: "请在系统设置中允许 Wisp 录制屏幕，再启动演示屏。")
            return
        }
        sourceID = CGMainDisplayID()
        guard CGDisplayIsInMirrorSet(sourceID) == 0 else {
            message = String(localized: "请先关闭显示器镜像，再启动独立演示屏。")
            return
        }
        guard let attached = PresentationMonitor(width: 1920, height: 1080) else {
            message = String(localized: "macOS 未能创建演示屏。请勿共享主屏。")
            return
        }
        monitor = attached
        isOpen = true
        message = nil
        let token = UUID()
        generation = token
        NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        session = Task {
            do {
                // WindowServer publishes NSScreen after CoreGraphics attaches the monitor.
                for _ in 0..<40 {
                    try Task.checkCancellation()
                    if outputScreen != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard layoutIsValid, let screen = outputScreen else { throw DisplayError.layout }
                showBlackOutput(on: screen)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                try Task.checkCancellation()
                guard let display = content.displays.first(where: { $0.displayID == sourceID }),
                      layoutIsValid else { throw DisplayError.layout }

                let apps = presentationApps(content)
                var included = Set(apps.map(\.processID))
                let config = SCStreamConfiguration()
                config.width = 1920
                config.height = 1080
                config.scalesToFit = true
                config.preservesAspectRatio = true
                config.backgroundColor = CGColor.black
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.queueDepth = 3
                config.showsCursor = true
                config.capturesAudio = false
                let capture = SCStream(filter: filter(display, apps), configuration: config, delegate: self)
                try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                stream = capture
                try await capture.startCapture()
                if Task.isCancelled {
                    try? await capture.stopCapture()
                    return
                }
                // An application include-list also excludes Dock's Mission Control composites.
                // Newly launched regular apps join the list without ever including Wisp.
                while true {
                    try await Task.sleep(for: .seconds(2))
                    let current = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    try Task.checkCancellation()
                    guard layoutIsValid, let source = current.displays.first(where: { $0.displayID == sourceID })
                        else { throw DisplayError.layout }
                    let apps = presentationApps(current)
                    let pids = Set(apps.map(\.processID))
                    if included != pids {
                        try await capture.updateContentFilter(filter(source, apps))
                        included = pids
                    }
                }
            } catch {
                if !Task.isCancelled, generation == token { fail(error.localizedDescription) }
            }
        }
    }

    /// Explicit disconnection only. A capture error leaves a black, selectable
    /// display so the conference client can keep its chosen source.
    func stop() {
        generation = UUID()
        clearStream()
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        output?.orderOut(nil)
        output = nil
        imageLayer = nil
        monitor = nil
        isOpen = false
        message = nil
    }

    private enum DisplayError: LocalizedError {
        case layout
        var errorDescription: String? { String(localized: "显示器布局已改变。请先结束会议共享，再重新启动演示屏。") }
    }

    private var outputScreen: NSScreen? {
        guard let id = monitor?.displayID else { return nil }
        return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    private var layoutIsValid: Bool {
        guard let id = monitor?.displayID else { return false }
        return id != sourceID && id != CGMainDisplayID() && CGDisplayIsActive(sourceID) > 0
            && CGDisplayIsInMirrorSet(sourceID) == 0 && CGDisplayIsInMirrorSet(id) == 0 && outputScreen != nil
    }

    @objc private func layoutChanged() {
        guard let output else { return }
        guard layoutIsValid, let screen = outputScreen else {
            if let screen = outputScreen, let id = monitor?.displayID,
               id != CGMainDisplayID(), CGDisplayIsInMirrorSet(id) == 0 {
                output.setFrame(screen.frame, display: true)
            } else {
                // Never let WindowServer move the cover onto the user's main display.
                stop()
            }
            fail(DisplayError.layout.localizedDescription)
            return
        }
        output.setFrame(screen.frame, display: true)
    }

    private func presentationApps(_ content: SCShareableContent) -> [SCRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.applications.filter { app in
            app.processID != ownPID && app.bundleIdentifier != Bundle.main.bundleIdentifier
                && NSRunningApplication(processIdentifier: app.processID)?.activationPolicy == .regular
        }
    }

    private func filter(_ source: SCDisplay, _ apps: [SCRunningApplication]) -> SCContentFilter {
        let filter = SCContentFilter(display: source, including: apps, exceptingWindows: [])
        if #available(macOS 14.2, *) { filter.includeMenuBar = false }
        return filter
    }

    private func showBlackOutput(on screen: NSScreen) {
        let window = PresentationWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let layer = CALayer()
        layer.actions = ["contents": NSNull()]
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = CGColor.black
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view
        ScreenPrivacy.apply(to: window)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        output = window
        imageLayer = layer
    }

    private func clearStream() {
        session?.cancel()
        session = nil
        if let old = stream {
            stream = nil
            Task { try? await old.stopCapture() }
        }
        imageLayer?.contents = nil
        isReady = false
    }

    private func fail(_ reason: String) {
        if output == nil { stop() } else { clearStream() }
        message = reason
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            if self.stream === stream { self.fail(error.localizedDescription) }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        // Registered on DispatchQueue.main. Never queue old frames across a stop/restart.
        MainActor.assumeIsolated {
            guard self.stream === stream, type == .screen, let layer = imageLayer,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
            guard status != .idle else { return }
            guard status == .complete, let pixels = sample.imageBuffer else {
                layer.contents = nil
                if isReady { isReady = false }
                return
            }
            // Draw normal window contents. Some whole-display recorders omit a
            // nested video presentation layer even when it displays locally.
            let image = CIImage(cvPixelBuffer: pixels)
            guard let frame = imageContext.createCGImage(image, from: image.extent) else {
                fail(String(localized: "演示画面绘制失败。请结束共享并重新启动演示屏。"))
                return
            }
            layer.contents = frame
            if !isReady { isReady = true }
        }
    }
}
