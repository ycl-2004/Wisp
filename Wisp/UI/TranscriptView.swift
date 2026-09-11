import SwiftUI

/// 转写原文。和 AI 回答共用同一块展开区域，一键来回切换：
/// 回答区永远只放回答，要核对原话时才把这一页调出来。
struct TranscriptView: View {
    @ObservedObject private var listening = ListeningModel.shared
    @EnvironmentObject private var model: AssistantModel

    var body: some View {
        TranscriptPage(transcript: listening.transcript,
                       onBack: { model.showsTranscript = false },
                       onCopy: { listening.copyText(listening.transcript?.text ?? "") },
                       onOpenFiles: { listening.showFiles() })
    }
}

/// 这一页的外观。转写整份传进来，所以空的、录到一半的、录完的都能单独渲染出来看。
struct TranscriptPage: View {
    var transcript: ListeningTranscript?
    var onBack: () -> Void
    var onCopy: () -> Void
    var onOpenFiles: () -> Void

    private var segments: [ListeningSegment] { transcript?.segments ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            if segments.isEmpty {
                empty
            } else {
                lines
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 头

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
            .buttonStyle(IconButtonStyle())
            .help("回到 AI 回答")
            .accessibilityLabel("回到 AI 回答")

            Text("转写原文").font(DS.title)

            if let subtitle {
                Text(subtitle)
                    .font(DS.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 2)

            Button(action: onCopy) { Image(systemName: "doc.on.doc") }
            .buttonStyle(IconButtonStyle())
            .disabled(segments.isEmpty)
            .help("复制全部转写文字")
            .accessibilityLabel("复制全部转写文字")

            Button(action: onOpenFiles) { Image(systemName: "folder") }
                .buttonStyle(IconButtonStyle())
                .help("打开本地录音与文字记录")
                .accessibilityLabel("打开本地录音与文字记录")
        }
        .padding(.horizontal, DS.gutter)
        .padding(.vertical, 6)
        .background(alignment: .bottom) { Rectangle().fill(DS.hairline).frame(height: 0.5) }
    }

    private var subtitle: String? {
        guard let transcript else { return nil }
        var parts: [String] = []
        if let name = transcript.applicationName { parts.append(name) }
        parts.append(String(localized: "\(segments.count) 段"))
        if transcript.savesAudio { parts.append(String(localized: "含音频")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 正文

    private var lines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        // 音源只在换人时标一次，同一个人连说三段不必写三遍。
                        row(segment, labelled: index == 0 || segments[index - 1].source != segment.source)
                            .id(segment.id)
                    }
                    Color.clear.frame(height: 2).id("transcript-bottom")
                }
                .padding(.horizontal, DS.gutter)
                .padding(.vertical, 10)
                .textSelection(.enabled)
            }
            .scrollIndicators(.never)
            .onAppear { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            .onChange(of: segments.last?.text) {
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            }
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.96),
                .init(color: .black.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
    }

    private func row(_ segment: ListeningSegment, labelled: Bool) -> some View {
        // 谁在说写在话的上面，像一份会议记录；话本身是这一行里最重的东西。
        HStack(alignment: .top, spacing: 8) {
            Text(ListeningSegment.clock(segment.start))
                .font(DS.code)
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .leading)
                .fixedSize()
                .padding(.top, labelled || !segment.isFinal ? 15 : 1)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color(for: segment.source))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                if labelled || !segment.isFinal {
                    HStack(spacing: 4) {
                        if labelled { Text(segment.source.title) }
                        if labelled, !segment.isFinal { Text(verbatim: "·") }
                        if !segment.isFinal { Text("临时文字，可能修正") }
                    }
                    .font(DS.label)
                    .foregroundStyle(.secondary)
                }
                Text(segment.text)
                    .font(DS.body)
                    // 临时结果还会被改写，读的人得看得出来这一句不是定稿。
                    .foregroundStyle(segment.isFinal ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func color(for source: ListeningSource) -> Color {
        source == .microphone ? Color.accentColor.opacity(0.55) : Color.orange.opacity(0.45)
    }

    // MARK: - 空

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tertiary)
            Text("这次还没有转写文字。")
                .font(DS.meta)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
