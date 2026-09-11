import SwiftUI

/// 语音是提问的输入，不是另一个目的地：永远一行，永远不接管回答区域。
struct ListeningView: View {
    @ObservedObject private var listening = ListeningModel.shared
    @ObservedObject private var pushToTalk = PushToTalk.shared
    @ObservedObject private var assistant = AssistantModel.shared

    var body: some View {
        // 关掉语音就整行让位：面板本来就窄，留一行空着的麦克风只是在占地方。
        if listening.isEnabled {
            if pushToTalk.isActive { pushToTalkBar } else { bar }
        }
    }

    private var bar: some View {
        ListeningBar(state: listening.state,
                     startedAt: listening.startedAt,
                     caption: listening.liveLine,
                     error: pushToTalk.error ?? listening.error,
                     mode: listening.mode,
                     hasTranscript: listening.hasTranscript,
                     canTransfer: listening.canTransfer,
                     showsTranscript: assistant.showsTranscript) { action in
            switch action {
            case .toggle:           listening.toggleFromUser()
            case .stopAndAnalyze:   listening.stopAndAnalyze()
            case .analyze:          listening.analyzeRecentSpeech()
            case .stage:            listening.stageRecentSpeech()
            case .copy:             listening.copyText(listening.transcript?.text ?? "")
            case .openFiles:        listening.showFiles()
            case .toggleTranscript: assistant.toggleTranscriptView()
            case .dismissError:     pushToTalk.clearError(); listening.clearError()
            }
        }
    }

    /// 按住说话借用同一行：红点和实时字幕，没有会议那几个动作。点麦克风等于放弃这次。
    private var pushToTalkBar: some View {
        let state: ListeningModel.State
        let caption: String
        switch pushToTalk.state {
        case .idle, .preparing:
            state = .starting
            caption = String(localized: "正在准备…")
        case .listening:
            state = .recording
            caption = pushToTalk.caption.isEmpty ? String(localized: "正在听你的问题，松开就发送") : pushToTalk.caption
        case .finishing:
            state = .stopping
            caption = String(localized: "正在收尾…")
        }
        return ListeningBar(state: state, startedAt: pushToTalk.startedAt, caption: caption, error: nil,
                            mode: .microphone, hasTranscript: false, canTransfer: false,
                            showsTranscript: assistant.showsTranscript, isPushToTalk: true) { action in
            if action == .toggle { pushToTalk.cancel() }
        }
    }
}

/// 语音条的外观。状态全部由外部传入，所以每一种状态都能在测试里单独渲染出来看。
struct ListeningBar: View {
    enum Action {
        case toggle, stopAndAnalyze, analyze, stage, copy, toggleTranscript, openFiles, dismissError
    }

    var state: ListeningModel.State
    var startedAt: Date?
    var caption: String
    var error: String?
    var mode: ListeningMode
    var hasTranscript: Bool
    var canTransfer: Bool
    var showsTranscript: Bool
    /// 按住说话占用这一行时只留状态和字幕。
    var isPushToTalk = false
    var perform: (Action) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRecording: Bool { state == .recording }
    private var isBusy: Bool { state == .starting || state == .stopping }

    var body: some View {
        HStack(spacing: 6) {
            micButton
            if isRecording, let startedAt { ElapsedLabel(startedAt: startedAt) }
            message
            Spacer(minLength: 2)
            ResponseModeToggle()
            actions
        }
        .padding(.horizontal, DS.gutter)
        .padding(.vertical, 5)
        .frame(minHeight: 30)
        .background(background)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isRecording)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("语音输入"))
    }

    // MARK: - 左侧

    /// 录音时是红点，安静时是麦克风。同一个按钮，位置不跳。
    private var micButton: some View {
        Button { perform(.toggle) } label: {
            ZStack {
                if isRecording {
                    RecordingDot()
                } else if isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.55)
                } else {
                    Image(systemName: "mic")
                }
            }
            .frame(width: 13, height: 13)
        }
        .buttonStyle(IconButtonStyle())
        .disabled(state == .stopping)
        .help(micHelp)
        .accessibilityLabel(micHelp)
    }

    private var micHelp: String {
        if isPushToTalk { return String(localized: "松开快捷键就发送；点这里放弃这次") }
        switch state {
        case .idle:      return String(localized: "开始录音（⌃⌥R）")
        case .starting:  return String(localized: "正在准备…")
        case .recording: return String(localized: "停止录音，转写放入输入框（⌃⌥R）")
        case .stopping:  return String(localized: "正在保存末尾文字…")
        }
    }

    // MARK: - 中间

    @ViewBuilder
    private var message: some View {
        if let error {
            HStack(spacing: 4) {
                Text(error)
                    .font(DS.meta)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(error)
                Button { perform(.dismissError) } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 8))
                    .help("知道了")
                    .accessibilityLabel("知道了")
            }
            .layoutPriority(1)
        } else {
            Text(caption)
                .font(DS.body)
                .foregroundStyle(isRecording ? Color.primary.opacity(0.85) : Color.secondary)
                .lineLimit(1)
                // 实时字幕越写越长，要看的永远是最后写出来的那几个字。
                .truncationMode(.head)
                .help(caption)
                .accessibilityLabel(Text(caption))
        }
    }

    // MARK: - 右侧

    @ViewBuilder
    private var actions: some View {
        if isPushToTalk {
            EmptyView()
        } else if isRecording {
            Chip(icon: "sparkles", text: String(localized: "停止并分析"), active: true, enabled: !isBusy) {
                perform(.stopAndAnalyze)
            }
            .fixedSize()
            .help("停止录音，等末尾文字收完，直接发给 AI 分析（⌃⌥↩）")
        } else if canTransfer {
            Chip(icon: "sparkles", text: String(localized: "分析"), active: true) {
                perform(.analyze)
            }
            .fixedSize()
            .help("把刚录到的转写发给 AI 分析（⌃⌥A）")
        }

        if hasTranscript, !isPushToTalk {
            Button { perform(.toggleTranscript) } label: {
                Image(systemName: showsTranscript ? "bubble.left" : "text.alignleft")
            }
            .buttonStyle(IconButtonStyle())
            .help(showsTranscript ? "回到 AI 回答" : "看转写原文")
            .accessibilityLabel(showsTranscript ? "回到 AI 回答" : "看转写原文")
        }

        if !isPushToTalk { menu }
    }

    private var menu: some View {
        Menu {
            if isRecording {
                Button("现在分析一下（不停止录音）") { perform(.analyze) }
                    .disabled(!canTransfer)
            }
            Button("放入输入框") { perform(.stage) }
                .disabled(!canTransfer)
            Button("复制转写") { perform(.copy) }
                .disabled(!hasTranscript)
            Divider()
            Button("打开记录文件夹") { perform(.openFiles) }
            SettingsLink { Text("音频设置…") }
            Divider()
            Text(mode.title)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18)
        .help("更多语音操作")
        .accessibilityLabel("更多语音操作")
    }

    // MARK: - 底

    @ViewBuilder
    private var background: some View {
        if isRecording {
            // 录音是要看得出来的状态，但它坐在头部和回答之间，不能比回答还响。
            Color.red.opacity(0.055)
                .overlay(alignment: .bottom) { Rectangle().fill(DS.hairline).frame(height: 0.5) }
        } else {
            DS.subtleBackground
        }
    }
}

/// 录音红点。呼吸靠动画驱动，视图消失时 SwiftUI 自己停掉，不留计时器。
private struct RecordingDot: View {
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

/// 已经录了多久。等宽数字，秒数跳动时左右不抖。
struct ElapsedLabel: View {
    var startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.text(for: max(0, context.date.timeIntervalSince(startedAt))))
                .font(DS.meta.monospacedDigit())
                .foregroundStyle(.secondary)
                // 面板可以被拖到很窄，但计时和右边的动作都不能被字幕挤没。
                .fixedSize()
        }
        .accessibilityHidden(true)
    }

    static func text(for seconds: TimeInterval) -> String { ListeningSegment.clock(seconds) }
}
