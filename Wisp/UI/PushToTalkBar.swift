import SwiftUI

/// While push-to-talk listens, the panel's second row shows its live words. Clicking the dot gives
/// the question up.
struct PushToTalkBar: View {
    @ObservedObject private var pushToTalk = PushToTalk.shared

    var body: some View {
        PushToTalkRow(state: pushToTalk.state, caption: pushToTalk.caption, cancel: { pushToTalk.cancel() })
    }
}

/// The row's appearance, from plain values so every state renders on its own in tests.
struct PushToTalkRow: View {
    static let height: CGFloat = 30

    var state: PushToTalk.State
    var caption: String
    var cancel: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Button(action: cancel) {
                ZStack {
                    if state == .listening { RecordingDot() }
                    else { ProgressView().controlSize(.small).scaleEffect(0.55) }
                }
                .frame(width: 13, height: 13)
            }
            .buttonStyle(IconButtonStyle())
            .help("松开快捷键就发送；点这里放弃这次")
            .accessibilityLabel(Text("放弃这次提问"))
            Text(text)
                .font(DS.body)
                .foregroundStyle(state == .listening ? Color.primary.opacity(0.85) : Color.secondary)
                .lineLimit(1)
                // 实时字幕越写越长，要看的永远是最后写出来的那几个字。
                .truncationMode(.head)
            Spacer(minLength: 2)
        }
        .padding(.horizontal, DS.gutter)
        .frame(height: Self.height)
        .background(Color.red.opacity(0.055))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("按住说话提问"))
    }

    private var text: String {
        switch state {
        case .idle, .preparing: return String(localized: "正在准备…")
        case .listening: return caption.isEmpty ? String(localized: "正在听你的问题，松开就发送") : caption
        case .finishing: return String(localized: "正在收尾…")
        }
    }
}

/// 红点。呼吸靠动画驱动，视图消失时 SwiftUI 自己停掉，不留计时器。
struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(reduceMotion ? 0.9 : (pulsing ? 1 : 0.45))
            .overlay(
                Circle()
                    .stroke(Color.red.opacity(0.35), lineWidth: 1)
                    .scaleEffect(reduceMotion ? 1 : (pulsing ? 1.9 : 1))
                    .opacity(reduceMotion ? 0 : (pulsing ? 0 : 0.8))
            )
            .animation(reduceMotion ? nil
                                    : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                       value: pulsing)
            .onAppear { if !reduceMotion { pulsing = true } }
            .accessibilityHidden(true)
    }
}
