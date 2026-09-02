import AppKit
import SwiftUI

/// 聊天输入框。SwiftUI 的 TextField 在垂直模式下会把 Return 当换行，拿不到「回车即发送」，
/// 所以这里直接包一层 NSTextView，自己接管按键：
/// Return 发送，Shift+Return 或 Option+Return 换行，Esc 收起面板。
/// 占位符由同一个 NSTextView 画，和插入点用的是同一套内边距，不会错位。
struct ChatInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool
    var onSubmit: () -> Void
    var onEscape: () -> Void
    @Binding var focusRequest: Int

    static let minHeight: CGFloat = 18
    static let maxLines = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlaceholderTextView()
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 2, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }
        context.coordinator.parent = self
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        textView.placeholder = placeholder
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled

        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    /// 让 SwiftUI 知道该给多高：跟着内容长，最多 maxLines 行。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? PlaceholderTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let width = proposal.width ?? nsView.bounds.width
        container.containerSize = NSSize(width: max(1, width - textView.textContainerInset.width * 2),
                                         height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 13))
        let maxHeight = lineHeight * CGFloat(Self.maxLines)
        let height = min(max(used, Self.minHeight), maxHeight) + textView.textContainerInset.height * 2
        return CGSize(width: width, height: ceil(height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInput
        weak var textView: PlaceholderTextView?
        weak var scrollView: NSScrollView?
        var lastFocusRequest = -1

        init(_ parent: ChatInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
        }
    }
}

/// 自己画占位符，并接管 Return / Esc。
final class PlaceholderTextView: NSTextView {
    var placeholder: String = ""
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        // 和正文用同一套内边距，占位符和插入点才对得齐。
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        NSString(string: placeholder).draw(at: origin, withAttributes: attributes)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            // Shift+Return / Option+Return 换行，单独 Return 发送。
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit()
            }
            return
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape()
            return
        }
        super.doCommand(by: selector)
    }
}
