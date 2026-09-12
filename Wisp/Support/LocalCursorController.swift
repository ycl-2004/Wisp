import AppKit
import ObjectiveC
import QuartzCore

/// One private moving arrow replaces the hidden system cursor. Never manufacture
/// a shared stationary cursor: a window behind translucent/moving UI is visible
/// locally too, and can coexist with a recorder's own cursor. Native input stays native.
@MainActor
final class LocalCursorController {
    static let shared = LocalCursorController()

    private let hideCursor: @MainActor () -> Void
    private let showCursor: @MainActor () -> Void
    private var timer: Timer?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var enabled = false
    private weak var dragOwner: NSWindow?
    private weak var owner: NSWindow?
    /// The app remembers its external capture target before an explicit click
    /// activates a nonactivating panel. Hover alone must never steal focus.
    var beforeActivating: (() -> Void)?
    private(set) var isReplacingCursor = false
    let localWindow = CursorPresentationWindow()
    var overlay: LocalCursorView { localWindow.pointer }

    init(hideCursor: @escaping @MainActor () -> Void = { WispCursorPolicy.hidePrivateCursor() },
         showCursor: @escaping @MainActor () -> Void = { WispCursorPolicy.showPrivateCursor() }) {
        self.hideCursor = hideCursor
        self.showCursor = showCursor
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        WispCursorPolicy.setEnabled(enabled)
        if !enabled {
            stop()
            return
        }

        // Common modes keep the pointer following native text selection, window
        // dragging and live resizing, which may run nested event loops.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Establish the presentation before controls handle the first click.
        // Refresh again after native controls update their cursor.
        // https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel
        ]) { [weak self] event in
            self?.prepare(for: event)
            DispatchQueue.main.async { self?.refresh() }
            return event
        }
        observe(NSApplication.didResignActiveNotification) { $0.restore() }
        observe(NSApplication.didBecomeActiveNotification) { $0.refresh() }
        observe(NSApplication.didHideNotification) { $0.restore() }
        observe(NSApplication.didChangeScreenParametersNotification) { $0.restore() }
        observe(NSApplication.willTerminateNotification) { $0.stop() }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.owner else { return }
                self.restore()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willMiniaturizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.owner else { return }
                self.restore()
            }
        })
        // Menus hosted by this process are protected by the same window policy.
        // A foreign/system menu naturally restores the pointer in the hit check.
        observe(NSMenu.didBeginTrackingNotification) { $0.refresh() }
        observe(NSMenu.didEndTrackingNotification) { $0.refresh() }
        refresh()
    }

    private func observe(_ name: Notification.Name, action: @escaping (LocalCursorController) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    func stop() {
        enabled = false
        WispCursorPolicy.setEnabled(false)
        timer?.invalidate()
        timer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        dragOwner = nil
        restore()
    }

    func prepare(for event: NSEvent) {
        guard enabled else { return }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !NSApp.isActive, let window = event.window, window.isVisible,
               window.sharingType == .none, !(window is CursorPresentationWindow) {
                beforeActivating?()
                NSApp.activate(ignoringOtherApps: true)
            }
            refresh()
            dragOwner = isReplacingCursor ? owner : nil
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            dragOwner = nil
            refresh()
        default:
            refresh()
        }
    }

    func refresh() {
        guard enabled else { restore(); return }
        let point = NSEvent.mouseLocation
        // Check the actual window under the pointer, not merely our window's rect:
        // another app, an input-method candidate or a menu may cover the same rect.
        // https://developer.apple.com/documentation/appkit/nswindow/windownumber(at:belowwindowwithwindownumber:)
        let window = dragOwner ?? windowUnderPointer(at: point)
        update(window: window, screenPoint: point,
               applicationActive: NSApp.isActive)
    }

    private func windowUnderPointer(at point: NSPoint) -> NSWindow? {
        var number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        // Click-through windows can still occur in WindowServer's ordering query.
        while let window = NSApp.window(withWindowNumber: number), window is CursorPresentationWindow {
            number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: number)
        }
        return NSApp.window(withWindowNumber: number)
    }

    /// Internal entry point also used by the synthetic interaction/capture probes.
    func update(window: NSWindow?, screenPoint: NSPoint, applicationActive: Bool) {
        // A nonactivating key panel can receive input while this app is in the
        // background, but that does not give it control over the system cursor.
        // Native capture probes show the real cursor still moves in that state.
        // Keep the normal pointer until activation instead of drawing a false lock.
        guard enabled, applicationActive, let window, window.isVisible, !window.isMiniaturized,
              !(window is CursorPresentationWindow),
              window.sharingType == .none else {
            restore()
            return
        }
        // Include native title bars, resize borders, menus and popovers. During a
        // native drag its owner keeps receiving events even outside its frame.
        guard window === dragOwner || window.frame.contains(screenPoint) else {
            restore()
            return
        }

        if !isReplacingCursor {
            // Hide before ordering ANY replacement on screen. Ordering the local
            // window first briefly displayed it alongside the system cursor.
            // https://developer.apple.com/documentation/appkit/nscursor/hide()
            hideCursor()
            isReplacingCursor = true
        }
        if owner !== window {
            localWindow.orderOut(nil)
            localWindow.parent?.removeChildWindow(localWindow)
            owner = window
            // Ordering out the host also orders out its child, including before
            // the next timer tick. A detached overlay could linger over other apps.
            // https://developer.apple.com/documentation/appkit/nswindow/addchildwindow(_:ordered:)
            // AppKit owns transient menu ordering; attaching children to a menu
            // can disturb dismissal and the ordering of the underlying panel.
            if window.level.rawValue < NSWindow.Level.popUpMenu.rawValue {
                window.addChildWindow(localWindow, ordered: .above)
            }
        }
        // Do not replace the last cursor requested by a native control: disabling
        // the policy needs that request to restore the text/resize cursor.
        NSCursor.arrow.wisp_setArrow()
        // A separate protected window remains above layer-backed SwiftUI content
        // and is not clipped at the host's edge. It never receives input or focus.
        let level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        if localWindow.level != level { localWindow.level = level }
        localWindow.placeArrow(at: screenPoint)
        if !localWindow.isVisible { localWindow.orderFrontRegardless() }
    }

    func restore() {
        if localWindow.isVisible { localWindow.orderOut(nil) }
        localWindow.parent?.removeChildWindow(localWindow)
        owner = nil
        dragOwner = nil
        guard isReplacingCursor else { return }
        // Commit removal before releasing the system cursor, avoiding an overlap
        // while layer-backed presentation is still being flushed.
        // https://developer.apple.com/documentation/quartzcore/catransaction/flush()
        CATransaction.flush()
        // NSCursor maintains a hide count. Release only the hide owned by us;
        // never unhide repeatedly or cancel an NSTextView's independent hide.
        // https://developer.apple.com/documentation/appkit/nscursor/hide()
        showCursor()
        isReplacingCursor = false
    }
}

/// This is the only cursor window Wisp creates. It is always private.
final class CursorPresentationWindow: NSPanel, CursorSharingSurface {
    var cursorSharingType: NSWindow.SharingType { .none }
    let pointer = LocalCursorView()
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = true
        ignoresMouseEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = .none
        pointer.setCursor(.arrow)
        contentView = pointer
        setAccessibilityElement(false)
    }

    func placeArrow(at point: NSPoint) {
        let cursor = NSCursor.arrow
        let size = cursor.image.size
        let next = NSRect(x: point.x - cursor.hotSpot.x,
                          y: point.y - (size.height - cursor.hotSpot.y),
                          width: size.width, height: size.height)
        if frame != next { setFrame(next, display: true) }
    }
}

/// A small click-through view avoids invalidating the chat on every mouse move.
final class LocalCursorView: NSView {
    private(set) var displayedCursor: NSCursor?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCursor(_ cursor: NSCursor) {
        guard displayedCursor !== cursor else { return }
        displayedCursor = cursor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        displayedCursor?.image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                                    respectFlipped: true, hints: nil)
    }
}

/// AppKit and SwiftUI install cursor rectangles of their own (including field
/// editors and selectable text). Normalize their requests synchronously, instead
/// of racing them with a timer. This affects NSCursor in this process only.
@MainActor
enum WispCursorPolicy {
    static func install() { _ = installation }
    private(set) static var isEnabled = false
    private static var requestedCursor: NSCursor?
    private static var privateHideCount = 0
    private static var nativeHideCount = 0

    static func hidePrivateCursor() {
        install()
        privateHideCount += 1
        NSCursor.wisp_hide()
    }

    static func showPrivateCursor() {
        guard privateHideCount > 0 else { return }
        privateHideCount -= 1
        NSCursor.wisp_unhide()
    }

    static func nativeHide() {
        nativeHideCount += 1
        NSCursor.wisp_hide()
    }

    static func nativeUnhide() {
        if nativeHideCount > 0 {
            nativeHideCount -= 1
            NSCursor.wisp_unhide()
        } else if privateHideCount == 0 {
            NSCursor.wisp_unhide()
        }
        // AppKit menu tracking issues an unmatched unhide. It must not consume
        // the hide owned by the private overlay and expose a second cursor.
        // Matched native hide/unhide pairs and native text editing remain intact.
    }

    static func setEnabled(_ enabled: Bool) {
        install()
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            requestedCursor = NSCursor.current
        } else {
            requestedCursor?.set()
            requestedCursor = nil
        }
    }

    static func cursor(for requested: NSCursor) -> NSCursor {
        guard isEnabled else { return requested }
        requestedCursor = requested
        return .arrow
    }

    private static let installation: Void = {
        // https://developer.apple.com/documentation/objectivec/method_exchangeimplementations(_:_:)
        for (original, replacement) in [
            (#selector(NSCursor.set), #selector(NSCursor.wisp_setArrow)),
            (#selector(NSCursor.push), #selector(NSCursor.wisp_pushArrow))
        ] {
            guard let method = class_getInstanceMethod(NSCursor.self, original),
                  let substitute = class_getInstanceMethod(NSCursor.self, replacement) else { continue }
            method_exchangeImplementations(method, substitute)
        }
        for (original, replacement) in [
            (#selector(NSCursor.hide), #selector(NSCursor.wisp_hide)),
            (#selector(NSCursor.unhide), #selector(NSCursor.wisp_unhide))
        ] {
            guard let method = class_getClassMethod(NSCursor.self, original),
                  let substitute = class_getClassMethod(NSCursor.self, replacement) else { continue }
            method_exchangeImplementations(method, substitute)
        }
    }()
}

private extension NSCursor {
    @objc dynamic class func wisp_hide() {
        guard Thread.isMainThread else { wisp_hide(); return }
        MainActor.assumeIsolated { WispCursorPolicy.nativeHide() }
    }

    @objc dynamic class func wisp_unhide() {
        guard Thread.isMainThread else { wisp_unhide(); return }
        MainActor.assumeIsolated { WispCursorPolicy.nativeUnhide() }
    }

    @objc dynamic func wisp_setArrow() {
        guard Thread.isMainThread else { wisp_setArrow(); return }
        MainActor.assumeIsolated { WispCursorPolicy.cursor(for: self).wisp_setArrow() }
    }

    @objc dynamic func wisp_pushArrow() {
        guard Thread.isMainThread else { wisp_pushArrow(); return }
        MainActor.assumeIsolated { WispCursorPolicy.cursor(for: self).wisp_pushArrow() }
    }
}
