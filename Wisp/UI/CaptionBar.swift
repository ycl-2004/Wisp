import SwiftUI

/// Live captions inside the assistant panel, under the header: two lines of the other side's
/// latest words, above the answer they lead to.
struct CaptionStrip: View {
    @ObservedObject private var captions = LiveCaptions.shared

    var body: some View {
        CaptionBar(state: captions.state, text: captions.buffer.text, lastChange: captions.lastChange,
                   message: captions.message,
                   dismissMessage: { captions.dismissMessage() },
                   openSettings: captions.needsScreenPermission ? { Permissions.openScreenRecordingSettings() } : nil,
                   stop: { captions.stop() })
    }
}

/// The strip's appearance, from plain values so every state renders on its own in tests.
struct CaptionBar: View {
    static let height: CGFloat = 52
    /// Two lines of the 15-pt caption font.
    static let textHeight: CGFloat = 40
    /// A silence longer than this dims the words, so old words do not read as new.
    static let dimAfter: TimeInterval = 10

    var state: LiveCaptions.State
    var text: String
    var lastChange: Date?
    var message: String?
    var dismissMessage: () -> Void = {}
    /// Offered with a message that only System Settings can resolve.
    var openSettings: (() -> Void)?
    var stop: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            status.frame(width: 14)
            Group {
                if let message {
                    HStack(spacing: 6) {
                        Text(message)
                            .font(DS.meta)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if let openSettings {
                            Button("打开系统设置", action: openSettings).controlSize(.small)
                        }
                        Button("知道了", action: dismissMessage).controlSize(.small)
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        // Full height, pinned to the bottom of a two-line window: the newest
                        // words are always the last line and older lines scroll off the top.
                        // (Multi-line head truncation would cut the middle of the second line.)
                        Text(displayText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: Self.textHeight, alignment: .bottom)
                            .clipped()
                            .opacity(isDimmed(at: context.date) ? 0.45 : 1)
                            .animation(.easeOut(duration: 0.4), value: isDimmed(at: context.date))
                    }
                    .accessibilityElement()
                    .accessibilityLabel(Text(displayText))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: stop) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 9))
                .help("关闭字幕")
                .accessibilityLabel(Text("关闭字幕"))
        }
        .padding(.horizontal, DS.gutter)
        .frame(height: Self.height)
        .background(DS.subtleBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.hairline).frame(height: 0.5) }
    }

    private func isDimmed(at date: Date) -> Bool {
        guard state == .running, let lastChange else { return false }
        return date.timeIntervalSince(lastChange) > Self.dimAfter
    }

    private var displayText: String {
        if !text.isEmpty { return text }
        switch state {
        case .idle: return ""
        case .starting: return String(localized: "正在准备字幕…")
        case .running: return String(localized: "正在听电脑的声音…")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .running: RecordingDot()
        case .starting: ProgressView().controlSize(.small).scaleEffect(0.6)
        case .idle: Image(systemName: "captions.bubble").foregroundStyle(.secondary)
        }
    }
}
