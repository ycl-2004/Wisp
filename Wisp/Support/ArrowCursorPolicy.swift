import AppKit
import ObjectiveC

/// Keeps the real system pointer visible and moving normally while preventing any
/// view, text field, selectable text, link, or resize border in Wisp from changing
/// the cursor away from the standard arrow.
///
/// Never calls `NSCursor.hide()` or draws a synthetic pointer: during screen sharing
/// the pointer moves smoothly across Wisp instead of disappearing or freezing at edges.
@MainActor
enum ArrowCursorPolicy {
    private(set) static var isEnabled = false

    static func start() {
        setEnabled(true)
    }

    static func setEnabled(_ enabled: Bool) {
        _ = installation
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            NSCursor.arrow.set()
        }
        // Rebuild cursor rects on existing windows so WindowServer drops any
        // previously registered I-beam / pointing-hand / resize rects.
        for window in NSApp?.windows ?? [] {
            window.resetCursorRects()
        }
    }

    static func effectiveCursor(for requested: NSCursor) -> NSCursor {
        isEnabled ? .arrow : requested
    }

    private static let installation: Void = {
        for (original, replacement) in [
            (#selector(NSCursor.set), #selector(NSCursor.wisp_arrowSet)),
            (#selector(NSCursor.push), #selector(NSCursor.wisp_arrowPush)),
        ] {
            guard let method = class_getInstanceMethod(NSCursor.self, original),
                  let substitute = class_getInstanceMethod(NSCursor.self, replacement) else { continue }
            method_exchangeImplementations(method, substitute)
        }
        if let original = class_getInstanceMethod(NSView.self, #selector(NSView.addCursorRect(_:cursor:))),
           let replacement = class_getInstanceMethod(NSView.self, #selector(NSView.wisp_arrowAddCursorRect(_:cursor:))) {
            method_exchangeImplementations(original, replacement)
        }
    }()
}

private extension NSCursor {
    @objc dynamic func wisp_arrowSet() {
        guard Thread.isMainThread else { wisp_arrowSet(); return }
        let target = MainActor.assumeIsolated { ArrowCursorPolicy.effectiveCursor(for: self) }
        target.wisp_arrowSet()
    }

    @objc dynamic func wisp_arrowPush() {
        guard Thread.isMainThread else { wisp_arrowPush(); return }
        let target = MainActor.assumeIsolated { ArrowCursorPolicy.effectiveCursor(for: self) }
        target.wisp_arrowPush()
    }
}

private extension NSView {
    @objc dynamic func wisp_arrowAddCursorRect(_ rect: NSRect, cursor: NSCursor) {
        guard Thread.isMainThread else { wisp_arrowAddCursorRect(rect, cursor: cursor); return }
        let target = MainActor.assumeIsolated { ArrowCursorPolicy.effectiveCursor(for: cursor) }
        wisp_arrowAddCursorRect(rect, cursor: target)
    }
}
