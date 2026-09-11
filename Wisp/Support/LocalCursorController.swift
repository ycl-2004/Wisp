import AppKit

/// Experimental pointer rendering, not a capture filter. The real mouse position
/// and all input events are untouched. Capture tools may still draw their own pointer.
@MainActor
final class LocalCursorController {
    static let shared = LocalCursorController()

    private let hideCursor: () -> Void
    private let showCursor: () -> Void
    private var timer: Timer?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var menuDepth = 0
    private var enabled = false
    private(set) var isReplacingCursor = false
    let overlay = LocalCursorView()

    init(hideCursor: @escaping () -> Void = { NSCursor.hide() },
         showCursor: @escaping () -> Void = { NSCursor.unhide() }) {
        self.hideCursor = hideCursor
        self.showCursor = showCursor
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
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
        // Observe only our events, without consuming or rewriting them. Refresh
        // after dispatch so the local arrow follows the native hit target.
        // https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel
        ]) { [weak self] event in
            DispatchQueue.main.async { self?.refresh() }
            return event
        }
        observe(NSApplication.didResignActiveNotification) { $0.restore() }
        observe(NSApplication.didHideNotification) { $0.restore() }
        observe(NSApplication.willTerminateNotification) { $0.stop() }
        observe(NSWindow.willCloseNotification) { $0.restore() }
        observe(NSMenu.didBeginTrackingNotification) {
            $0.menuDepth += 1
            $0.restore()
        }
        observe(NSMenu.didEndTrackingNotification) {
            $0.menuDepth = max(0, $0.menuDepth - 1)
            $0.refresh()
        }
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
        timer?.invalidate()
        timer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        menuDepth = 0
        restore()
    }

    func refresh() {
        guard enabled else { restore(); return }
        let point = NSEvent.mouseLocation
        // Check the actual window under the pointer, not merely our window's rect:
        // another app, an input-method candidate or a menu may cover the same rect.
        // https://developer.apple.com/documentation/appkit/nswindow/windownumber(at:belowwindowwithwindownumber:)
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        update(window: NSApp.window(withWindowNumber: number), screenPoint: point,
               applicationActive: NSApp.isActive && menuDepth == 0)
    }

    /// Internal entry point also used by the synthetic interaction/capture probes.
    func update(window: NSWindow?, screenPoint: NSPoint, applicationActive: Bool) {
        guard enabled, applicationActive,
              let window, window.isVisible, !window.isMiniaturized,
              window.sharingType == .none, let content = window.contentView else {
            restore()
            return
        }
        let point = content.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard content.bounds.contains(point), content.hitTest(point) != nil else {
            restore()
            return
        }

        if overlay.superview !== content {
            overlay.removeFromSuperview()
            content.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        // Keep the visible pointer stable. Resize and text-edit gestures still use
        // their native hit targets; only the pointer artwork is intentionally an arrow.
        let cursor = NSCursor.arrow
        cursor.set()
        overlay.setCursor(cursor)
        let size = cursor.image.size
        overlay.frame = NSRect(x: point.x - cursor.hotSpot.x,
                               y: point.y - (content.isFlipped ? cursor.hotSpot.y : size.height - cursor.hotSpot.y),
                               width: size.width, height: size.height)
        overlay.isHidden = false
        if !isReplacingCursor {
            // Draw before hiding: there must be a local pointer when we take ownership.
            overlay.displayIfNeeded()
            hideCursor()
            isReplacingCursor = true
        }
    }

    func restore() {
        overlay.removeFromSuperview()
        guard isReplacingCursor else { return }
        // NSCursor maintains a hide count. Release only the hide owned by us;
        // never unhide repeatedly or cancel an NSTextView's independent hide.
        // https://developer.apple.com/documentation/appkit/nscursor/hide()
        showCursor()
        isReplacingCursor = false
    }
}

/// Lives in the same excluded window as the content, never a second shared window.
/// A small click-through view avoids invalidating the entire chat on every mouse move.
final class LocalCursorView: NSView {
    private(set) var displayedCursor: NSCursor?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
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
