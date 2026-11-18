import AVFoundation
import SwiftUI
import XCTest
@testable import Wisp

final class ListeningTests: XCTestCase {
    func testMenuRemovalRecoveryPreservesExplicitOptOutAndIsBounded() {
        var presence = MenuBarPresence(isInserted: true)
        presence.isInserted = false // SwiftUI removal callback, not a settings edit.
        XCTAssertTrue(presence.recoverIfNeeded(wantsVisible: true))
        XCTAssertTrue(presence.isInserted)
        presence.isInserted = false // OS refuses the retry; do not spin forever.
        XCTAssertFalse(presence.recoverIfNeeded(wantsVisible: true))
        XCTAssertFalse(presence.isInserted)
        presence.setPreference(false)
        XCTAssertFalse(presence.recoverIfNeeded(wantsVisible: false))
        XCTAssertFalse(presence.isInserted)
        presence.setPreference(true)
        XCTAssertTrue(presence.isInserted)
        XCTAssertFalse(presence.attemptedRecovery)
    }

    @MainActor
    func testOpeningTranscriptExpandsCollapsedPanelAndLeavesHistoryList() {
        let model = AssistantModel.shared
        let collapsed = model.isCollapsed, list = model.showsConversationList, transcript = model.showsTranscript
        defer {
            model.setCollapsedSilently(collapsed)
            model.showsConversationList = list
            model.showsTranscript = transcript
        }
        model.setCollapsedSilently(true)
        model.showsConversationList = true
        model.showsTranscript = false
        model.toggleTranscriptView()
        XCTAssertTrue(model.showsTranscript)
        XCTAssertFalse(model.isCollapsed)
        XCTAssertFalse(model.showsConversationList)
        model.toggleTranscriptView()
        XCTAssertFalse(model.showsTranscript)
        XCTAssertFalse(model.isCollapsed)
    }

    @MainActor
    func testOpeningHistoryExpandsCollapsedPanel() {
        let model = AssistantModel.shared
        let collapsed = model.isCollapsed, list = model.showsConversationList, transcript = model.showsTranscript
        defer {
            model.setCollapsedSilently(collapsed)
            model.showsConversationList = list
            model.showsTranscript = transcript
        }
        model.setCollapsedSilently(true)
        model.showsConversationList = false
        model.showsTranscript = false

        model.toggleConversationList()

        XCTAssertTrue(model.showsConversationList)
        XCTAssertFalse(model.showsTranscript)
        XCTAssertFalse(model.isCollapsed)
    }

    func testMicrophoneBufferCopyOwnsSamplesAndPreservesBothChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let original = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        original.frameLength = 128
        for channel in 0..<2 {
            for frame in 0..<128 { original.floatChannelData![channel][frame] = Float(channel * 128 + frame) }
        }
        let copy = try XCTUnwrap(ListeningAudioSink.copy(original))
        original.floatChannelData![0][1] = -999
        XCTAssertEqual(copy.frameLength, 128)
        XCTAssertEqual(copy.floatChannelData![0][1], 1)
        XCTAssertEqual(copy.floatChannelData![1][127], 255)
    }

    func testSchedulerSerializesSourcesAndRejectsLateCallbacks() throws {
        let queue = DispatchQueue(label: "listening-test")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        var starts: [ListeningSource] = []
        var callbacks: [(ListeningSpeechScheduler.Update) -> Void] = []
        var segments: [ListeningSegment] = []
        var cancellations = 0
        let scheduler = ListeningSpeechScheduler(queue: queue, recognize: { batch, callback in
            starts.append(batch.source)
            callbacks.append(callback)
            return { cancellations += 1 }
        }, onSegment: { segments.append($0) }, onFailure: { XCTFail($0) })
        queue.sync {
            scheduler.enqueue(.init(source: .microphone, offset: 10, duration: 1, buffers: [buffer]))
            scheduler.enqueue(.init(source: .application, offset: 11, duration: 1, buffers: [buffer]))
            XCTAssertEqual(starts, [.microphone])
            callbacks[0](.init(text: "my voice", start: 0.2, end: 0.8, isFinal: true))
        }
        queue.sync {
            XCTAssertEqual(starts, [.microphone, .application])
            XCTAssertEqual(segments.first?.start, 10.2)
            callbacks[0](.init(text: "late text", isFinal: true))
            scheduler.cancel()
            callbacks[1](.init(text: "after stop", isFinal: true))
        }
        queue.sync {
            XCTAssertEqual(segments.count, 1)
            XCTAssertEqual(cancellations, 1)
            XCTAssertTrue(scheduler.isDrained)
        }
    }

    func testSchedulerStopsAtBoundedBacklogAndDoesNotStartMoreRequests() throws {
        let queue = DispatchQueue(label: "listening-overload-test")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        var starts = 0
        var failures: [String] = []
        let scheduler = ListeningSpeechScheduler(queue: queue, recognize: { _, _ in
            starts += 1
            return {}
        }, onSegment: { _ in }, onFailure: { failures.append($0) })
        queue.sync {
            for _ in 0..<20 {
                scheduler.enqueue(.init(source: .application, offset: 0, duration: 1, buffers: [buffer]))
            }
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(failures.count, 1)
            XCTAssertTrue(scheduler.isDrained)
        }
    }

    func testQuietBoundaryChecksAllChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        for channel in 0..<2 { for frame in 0..<16 { buffer.floatChannelData![channel][frame] = 0 } }
        XCTAssertTrue(ListeningSpeechTrack.isQuiet(buffer))
        buffer.floatChannelData![1][0] = 0.5
        XCTAssertFalse(ListeningSpeechTrack.isQuiet(buffer))
    }

    func testTracksFlushTrailingAudioAndRetentionIsOptIn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "listening-retention-test")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        for frame in 0..<1600 { buffer.floatChannelData![0][frame] = 0.25 }
        var starts: [ListeningSource] = []
        let scheduler = ListeningSpeechScheduler(queue: queue, recognize: { batch, callback in
            starts.append(batch.source)
            callback(.init(text: "fixture", isFinal: true))
            return {}
        }, onSegment: { _ in }, onFailure: { XCTFail($0) })
        queue.sync {
            let retained = ListeningSpeechTrack(source: .microphone, scheduler: scheduler,
                                                 directory: directory, onFailure: { XCTFail($0) })
            let ephemeral = ListeningSpeechTrack(source: .application, scheduler: scheduler,
                                                  directory: nil, onFailure: { XCTFail($0) })
            retained.append(buffer, offset: 0)
            ephemeral.append(buffer, offset: 0)
            XCTAssertTrue(starts.isEmpty)
            retained.finish()
            ephemeral.finish()
        }
        queue.sync { XCTAssertEqual(starts, [.microphone, .application]) }
        queue.sync { scheduler.cancel() }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["microphone-1.caf"])
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("microphone-1.caf"))
        XCTAssertEqual(file.length, 1600)
        let restored = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600))
        try file.read(into: restored)
        XCTAssertEqual(restored.floatChannelData![0][1599], 0.25)
    }

    /// Common device formats are saved as AAC (≈8 KB/s per channel instead of 192 KB/s),
    /// so a two-hour session fits under the per-track cap; others stay PCM.
    func testCommonDeviceFormatsSaveCompressedAndOthersStayPCM() throws {
        let mono48 = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let aac = ListeningSpeechTrack.fileSettings(for: mono48)
        XCTAssertEqual(aac.settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(aac.bytesPerSecond, 8_000)
        XCTAssertLessThan(aac.bytesPerSecond * 2 * 3600, Double(ListeningSpeechTrack.audioByteLimit))
        let mono16 = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let pcm = ListeningSpeechTrack.fileSettings(for: mono16)
        XCTAssertNotEqual(pcm.settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(pcm.bytesPerSecond, 16_000 * 4)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "listening-aac-test")
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mono48, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        for frame in 0..<4_800 { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.05) * 0.3 }
        let scheduler = ListeningSpeechScheduler(queue: queue, recognize: { _, callback in
            callback(.init(text: "fixture", isFinal: true))
            return {}
        }, onSegment: { _ in }, onFailure: { XCTFail($0) })
        queue.sync {
            let track = ListeningSpeechTrack(source: .microphone, scheduler: scheduler,
                                             directory: directory, onFailure: { XCTFail($0) })
            for _ in 0..<10 { track.append(buffer, offset: 0) }
            track.finish()
        }
        queue.sync { scheduler.cancel() }
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("microphone-1.caf"))
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(file.length, 48_000)
    }

    /// Reaching the audio cap used to throw and stop the whole session, transcription
    /// included, about 22 minutes into a meeting. Now it stops saving audio only.
    func testAudioCapStopsSavingButNotTranscription() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "listening-cap-test")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        for frame in 0..<1600 { buffer.floatChannelData![0][frame] = 0.25 }
        var batches = 0
        var notices: [String] = []
        let scheduler = ListeningSpeechScheduler(queue: queue, recognize: { _, callback in
            batches += 1
            callback(.init(text: "fixture", isFinal: true))
            return {}
        }, onSegment: { _ in }, onFailure: { XCTFail($0) })
        queue.sync {
            // One 0.1 s PCM buffer is 6,400 bytes: the second one crosses a 10,000-byte cap.
            let track = ListeningSpeechTrack(source: .microphone, scheduler: scheduler, directory: directory,
                                             onFailure: { XCTFail("the cap must not stop recording: \($0)") },
                                             onNotice: { notices.append($0) }, audioByteLimit: 10_000)
            for _ in 0..<5 { track.append(buffer, offset: 0) }
            track.finish()
        }
        queue.sync { XCTAssertEqual(batches, 1, "all five buffers still reach recognition") }
        queue.sync { scheduler.cancel() }
        XCTAssertEqual(notices.count, 1)
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("microphone-1.caf"))
        XCTAssertEqual(file.length, 1600, "only what fit under the cap was saved")
    }

    func testDraftPreservesExistingTextAndDoesNotFollowLaterRecognition() {
        var transcript = transcript()
        let part = segment(start: 0, end: 1, text: "first version", final: false)
        transcript.upsert(part)
        let draft = ListeningTranscript.appendingToDraft(transcript.unstagedDraft(excluding: []).text, existing: "My question")!
        transcript.upsert(segment(id: part.id, start: 0, end: 2, text: "corrected version"))
        XCTAssertTrue(draft.hasPrefix("My question\n\n"))
        XCTAssertTrue(draft.contains("first version"))
        XCTAssertFalse(draft.contains("corrected version"))
        XCTAssertNil(ListeningTranscript.appendingToDraft("more", existing: String(repeating: "x", count: 12_000)))
    }

    func testCompletedBatchReleasesAudioBeforeTimeoutFires() throws {
        let queue = DispatchQueue(label: "listening-release-test")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        var buffer: AVAudioPCMBuffer? = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer?.frameLength = 16
        weak var retained = buffer
        let scheduler = ListeningSpeechScheduler(queue: queue, recognize: { _, callback in
            callback(.init(text: "done", isFinal: true))
            return {}
        }, onSegment: { _ in }, onFailure: { XCTFail($0) })
        queue.sync {
            scheduler.enqueue(.init(source: .microphone, offset: 0, duration: 1, buffers: [buffer!]))
        }
        buffer = nil
        queue.sync { XCTAssertTrue(scheduler.isDrained) }
        XCTAssertNil(retained, "Completed PCM must not be retained by the ten-second timeout closure")
    }

    @MainActor
    func testStagingDoesNotSendPersistOrCopyAndClearingRestoresNormalDraftMode() {
        let model = AssistantModel.shared
        let previous = model.input
        let previousSpeechMode = model.isSpeechDraft
        let previousTranscript = model.showsTranscript
        let previousList = model.showsConversationList
        let previousCollapsed = model.isCollapsed
        defer {
            model.input = ""
            if previousSpeechMode { _ = model.stageSpeechDraft(previous) } else { model.input = previous }
            model.showsTranscript = previousTranscript
            model.showsConversationList = previousList
            model.setCollapsedSilently(previousCollapsed)
        }
        let count = model.store.conversations.reduce(0) { $0 + $1.messages.count }
        let clipboardVersion = NSPasteboard.general.changeCount
        model.input = "Please review"
        let focusRevision = model.speechDraftRevision
        XCTAssertTrue(model.stageSpeechDraft("Only selected speech"))
        XCTAssertEqual(model.input, "Please review\n\nOnly selected speech")
        XCTAssertTrue(model.isSpeechDraft)
        XCTAssertEqual(model.speechDraftRevision, focusRevision + 1)
        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(model.store.conversations.reduce(0) { $0 + $1.messages.count }, count)
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardVersion)
        model.input = ""
        XCTAssertFalse(model.isSpeechDraft)
    }

    @MainActor
    func testAudioAndDataSettingsRenderWithoutStartingCapture() throws {
        let wasActive = ListeningModel.shared.isActive
        try render(AudioSettingsView(), filename: "wisp-audio-settings.png")
        try render(AudioSettingsView(), filename: "wisp-audio-settings-full.png", height: 660)
        try render(DataSettingsView(wipeResult: .constant(nil)).environmentObject(AssistantModel.shared),
                   filename: "wisp-data-settings.png")
        XCTAssertEqual(ListeningModel.shared.isActive, wasActive)
    }

    /// 总开关关掉之后不能再开始录音，转写页也得让出来——那一页只有语音条能退出。
    @MainActor
    func testDisablingVoiceInputBlocksStartAndClosesTheTranscriptPage() {
        let listening = ListeningModel.shared
        let assistant = AssistantModel.shared
        let wasEnabled = listening.isEnabled
        let wasMode = listening.mode
        let wasShowingTranscript = assistant.showsTranscript
        defer {
            listening.isEnabled = wasEnabled
            listening.mode = wasMode
            assistant.showsTranscript = wasShowingTranscript
        }

        listening.isEnabled = true
        listening.mode = .microphone
        assistant.showsTranscript = true
        XCTAssertTrue(listening.canStart)

        listening.isEnabled = false
        XCTAssertFalse(listening.canStart)
        XCTAssertFalse(assistant.showsTranscript)

        listening.isEnabled = true
        XCTAssertTrue(listening.canStart)
    }

    /// 所有界面截图都走这里：写到 /private/tmp 方便肉眼看，同时留成测试附件。
    @MainActor
    @discardableResult
    private func render<V: View>(_ view: V, filename: String,
                                 width: CGFloat = 620, height: CGFloat = 520) throws -> NSImage {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/" + filename))
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(image.size.width, width)
        return image
    }

    func testContinuousDraftTransferExcludesAlreadyStagedSpeech() {
        var transcript = transcript()
        let first = segment(start: 0, end: 4, text: "first question", final: false)
        transcript.upsert(first)
        XCTAssertTrue(transcript.unstagedDraft(excluding: []).text.contains("first question"))
        transcript.upsert(segment(id: first.id, start: 0, end: 4, text: "corrected first question"))
        XCTAssertEqual(transcript.unstagedDraft(excluding: [first.id]).text, "")
        let next = segment(start: 5, end: 9, text: "next question")
        transcript.upsert(next)
        let pending = transcript.unstagedDraft(excluding: [first.id]).text
        XCTAssertTrue(pending.contains("next question"))
        XCTAssertFalse(pending.contains("first question"))
    }

    @MainActor
    func testIntegratedCompactChatRenders() throws {
        let model = AssistantModel.shared
        let collapsed = model.isCollapsed
        let enabled = ListeningModel.shared.isEnabled
        model.setCollapsedSilently(true)
        defer {
            model.setCollapsedSilently(collapsed)
            ListeningModel.shared.isEnabled = enabled
        }
        for voiceEnabled in [true, false] {
            ListeningModel.shared.isEnabled = voiceEnabled
            try render(ChatView().environmentObject(model).environmentObject(model.store),
                       filename: "wisp-integrated-chat-\(voiceEnabled).png", height: PanelController.collapsedHeight)
        }
    }

    @MainActor
    func testLongHeaderFitsNarrowPanelInBothLanguagesAndAppearances() throws {
        let model = AssistantModel.shared
        let settings = AppSettings.shared
        let originalPacket = model.packet
        let originalKind = settings.providerKind
        let originalModel = settings.model
        let originalOverrides = UserDefaults.standard.object(forKey: "responseModels")
        defer {
            model.packet = originalPacket
            settings.providerKind = originalKind
            settings.model = originalModel
            UserDefaults.standard.set(originalOverrides, forKey: "responseModels")
        }
        settings.providerKind = ProviderKind.openAICompatible.rawValue
        settings.model = "Gemini 3.6 Flash (Low) — a deliberately long model name"
        settings.setResponseModel("", for: settings.responseMode,
                                  connection: ProviderConfig.selection().responseConnectionKey)
        var packet = ContextPacket(appName: "System Settings", bundleID: "com.apple.systempreferences")
        packet.screenshotJPEG = ScreenCapturer.tinyTestJPEG()
        packet.pageText = String(repeating: "x", count: 13229)
        packet.notes = [.info("Fixture capture detail")]
        model.packet = packet
        for width: CGFloat in [380, 620] {
            let language = Bundle.main.preferredLocalizations.first ?? "en"
            for scheme: ColorScheme in [.light, .dark] {
                let name = "wisp-header-\(Int(width))-\(language)-\(scheme == .light ? "light" : "dark").png"
                try render(ContextHeaderView().environmentObject(model).environmentObject(model.store)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, scheme), filename: name, width: width, height: 60)
            }
        }
    }

    @MainActor
    func testPanelHostingDoesNotImposeContentDrivenResizeLimits() throws {
        let host = PanelController.makePanelContentView(ListeningView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 180),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.minSize = NSSize(width: 380, height: 144)
        window.maxSize = NSSize(width: 2400, height: 1000)
        XCTAssertTrue(try XCTUnwrap(host.subviews.first as? NSHostingView<ListeningView>).sizingOptions.isEmpty)
        for size in [NSSize(width: 380, height: 152), NSSize(width: 900, height: 700), NSSize(width: 620, height: 180)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(window.frame.size.width, size.width, accuracy: 1)
            XCTAssertEqual(window.frame.size.height, size.height, accuracy: 1)
            XCTAssertEqual(window.minSize.width, 380)
        }
    }

    @MainActor
    func testListeningViewRendersAtPanelWidth() throws {
        for width in [PanelController.width, 380] {
            try render(ListeningView().environmentObject(AssistantModel.shared)
                        .background(Color(nsColor: .windowBackgroundColor)),
                       filename: "wisp-listening-ui-\(Int(width)).png", width: width, height: 34)
        }
    }

    /// 语音条每一种状态都要能在面板宽度和最窄宽度下看：录音时右边多两个控件，
    /// 字幕被挤没了就说明这一行设计不成立。
    @MainActor
    func testListeningBarRendersEveryStateAtBothWidths() throws {
        let states: [(String, ListeningBar)] = [
            ("idle", bar(state: .idle, caption: String(localized: "语音输入"))),
            ("recording", bar(state: .recording,
                              startedAt: Date().addingTimeInterval(-95),
                              caption: "那这版就按上周的方案走，周一之前给一个结论。",
                              hasTranscript: true, canTransfer: true)),
            ("stopped", bar(state: .idle, caption: "周一之前给一个结论。",
                            hasTranscript: true, canTransfer: true)),
            ("transcript", bar(state: .idle, caption: "周一之前给一个结论。",
                               hasTranscript: true, canTransfer: true, showsTranscript: true)),
            ("busy", bar(state: .stopping, caption: String(localized: "正在保存末尾文字…"))),
            ("error", bar(state: .idle, caption: "",
                          error: String(localized: "请在系统设置 → 隐私与安全性 → 麦克风中允许 Wisp。"))),
        ]
        for (name, view) in states {
            for width in [PanelController.width, 380] {
                try render(view.background(Color(nsColor: .windowBackgroundColor)),
                           filename: "wisp-listening-bar-\(name)-\(Int(width)).png",
                           width: width, height: 32)
            }
        }
    }

    @MainActor
    func testTranscriptPageRendersFilledAndEmpty() throws {
        var filled = transcript()
        let script = [("远端音频", "我们把语音这块的验收标准定一下。", true),
                      ("我方麦克风", "我这边先补一版测试，明天给结论。", true),
                      ("远端音频", "行，那窗口长度就按九十秒来。", false)]
        for (index, item) in script.enumerated() {
            filled.upsert(segment(source: item.0 == "远端音频" ? .application : .microphone,
                                  start: Double(index * 6), end: Double(index * 6 + 5),
                                  text: item.1, final: item.2))
        }
        try render(page(filled), filename: "wisp-transcript-filled.png", height: 260)
        try render(page(transcript()), filename: "wisp-transcript-empty.png", height: 160)
        try render(page(nil), filename: "wisp-transcript-none.png", height: 160)
    }

    private func page(_ transcript: ListeningTranscript?) -> some View {
        TranscriptPage(transcript: transcript, onBack: {}, onCopy: {}, onOpenFiles: {})
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func bar(state: ListeningModel.State, startedAt: Date? = nil, caption: String = "",
                     error: String? = nil, mode: ListeningMode = .both, hasTranscript: Bool = false,
                     canTransfer: Bool = false, showsTranscript: Bool = false,
                     perform: @escaping (ListeningBar.Action) -> Void = { _ in }) -> ListeningBar {
        ListeningBar(state: state, startedAt: startedAt, caption: caption, error: error, mode: mode,
                     hasTranscript: hasTranscript, canTransfer: canTransfer,
                     showsTranscript: showsTranscript, perform: perform)
    }

    func testElapsedLabelStaysTwoDigitsUntilAnHour() {
        XCTAssertEqual(ElapsedLabel.text(for: 0), "00:00")
        XCTAssertEqual(ElapsedLabel.text(for: 59.9), "00:59")
        XCTAssertEqual(ElapsedLabel.text(for: 95), "01:35")
        XCTAssertEqual(ElapsedLabel.text(for: 3_600), "1:00:00")
        XCTAssertEqual(ElapsedLabel.text(for: 7_384), "2:03:04")
    }

    // MARK: - 一键分析

    @MainActor
    func testOneKeyAnalysisAsksAQuestionOnlyWhenTheUserDidNotTypeOne() {
        let model = AssistantModel.shared
        let previousInput = model.input
        let previousCollapsed = model.isCollapsed
        let previousTranscript = model.showsTranscript
        defer {
            model.input = previousInput
            model.showsTranscript = previousTranscript
            model.setCollapsedSilently(previousCollapsed)
        }
        let count = model.store.conversations.reduce(0) { $0 + $1.messages.count }

        model.input = ""
        XCTAssertTrue(model.stageSpeechDraft("[00:00:00–00:00:04] 远端音频: 下周一给结论",
                                             fallbackQuestion: ListeningModel.analysisQuestion))
        XCTAssertTrue(model.input.hasPrefix(ListeningModel.analysisQuestion))
        XCTAssertTrue(model.input.hasSuffix("下周一给结论"))
        XCTAssertTrue(model.isSpeechDraft)

        // 只打了空格也算没写问题。
        model.input = "  \n "
        XCTAssertTrue(model.stageSpeechDraft("第二段", fallbackQuestion: ListeningModel.analysisQuestion))
        XCTAssertTrue(model.input.hasPrefix(ListeningModel.analysisQuestion))

        // 用户自己写了问题就用他的，默认问题不许挤进去。
        model.input = "这段里他们答应了什么？"
        XCTAssertTrue(model.stageSpeechDraft("第三段", fallbackQuestion: ListeningModel.analysisQuestion))
        XCTAssertEqual(model.input, "这段里他们答应了什么？\n\n第三段")

        // 放草稿这一步永远不发送。
        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(model.store.conversations.reduce(0) { $0 + $1.messages.count }, count)
    }

    @MainActor
    func testOneKeyAnalysisBudgetsForDefaultAndTypedQuestions() {
        let model = AssistantModel.shared
        let previous = (model.input, model.isSpeechDraft, model.isCollapsed, model.showsTranscript, model.showsConversationList)
        defer {
            if previous.1 { _ = model.stageSpeechDraft(previous.0) } else { model.input = previous.0 }
            model.setCollapsedSilently(previous.2)
            model.showsTranscript = previous.3
            model.showsConversationList = previous.4
        }
        var meeting = transcript()
        for index in 0..<100 {
            let text = index == 99 ? "Final decision" : String(repeating: "x", count: 126)
            XCTAssertTrue(meeting.upsert(.init(id: UUID(), source: .application, start: Double(index * 4),
                                               end: Double(index * 4 + 4), text: text, isFinal: true)))
        }
        let fallback = ListeningModel.analysisQuestion
        let typed = "What did the team decide? " + String(repeating: "a", count: 500)
        for (input, question) in [("", fallback), (typed, typed)] {
            model.input = input
            let consumed = model.stageSpeechDraft(meeting, excluding: [], fallbackQuestion: fallback)
            XCTAssertEqual(consumed, Set(meeting.segments.map(\.id)))
            XCTAssertEqual(model.input.components(separatedBy: "\n\n").first, question)
            XCTAssertLessThanOrEqual(model.input.count, ListeningTranscript.draftLimit)
            XCTAssertTrue(model.input.hasSuffix("Final decision"))
        }

        let full = String(repeating: "x", count: ListeningTranscript.draftLimit)
        model.input = full
        XCTAssertNil(model.stageSpeechDraft(meeting, excluding: [], fallbackQuestion: fallback))
        XCTAssertEqual(model.input, full)
    }

    @MainActor
    func testAnalysisDraftIsRefusedWhileAnAnswerIsStreaming() {
        let model = AssistantModel.shared
        let previousInput = model.input
        let wasStreaming = model.isStreaming
        defer {
            model.isStreaming = wasStreaming
            model.input = previousInput
        }
        model.input = ""
        model.isStreaming = true
        XCTAssertFalse(model.stageSpeechDraft("会议内容", fallbackQuestion: ListeningModel.analysisQuestion))
        XCTAssertEqual(model.input, "")
    }

    @MainActor
    func testCopyingAWholeTranscriptIsNotCappedByTheDraftBudget() {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
        // 一份长会议的全文远超发给模型的那 12,000 字预算，复制仍然要拿到整份。
        let whole = String(repeating: "会议", count: ListeningTranscript.draftLimit)
        ListeningModel.shared.copyText(whole)
        XCTAssertEqual(pasteboard.string(forType: .string)?.count, whole.count)
        let version = pasteboard.changeCount
        ListeningModel.shared.copyText("")
        XCTAssertEqual(pasteboard.changeCount, version)
    }

    /// 面板一展开，中间就被消息列表占满，`isMovableByWindowBackground` 在那儿不起作用。
    /// 头部标题这一段必须是真的能拖走窗口的，按钮不受影响。
    @MainActor
    func testHeaderTitleAreaDragsTheWindowWhileButtonsKeepTheirClicks() throws {
        let host = NSHostingView(rootView: ContextHeaderView()
            .environmentObject(AssistantModel.shared)
            .environmentObject(ConversationStore.shared)
            .frame(width: 620, height: 60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // 标题和它右边的空白：拖这里等于拖窗口。
        let title = try XCTUnwrap(host.hitTest(NSPoint(x: 200, y: 38)))
        XCTAssertTrue(title is WindowDragArea.DragView, "标题区应该命中拖动层，实际是 \(type(of: title))")
        XCTAssertTrue(title.mouseDownCanMoveWindow)
        XCTAssertTrue(title.acceptsFirstMouse(for: nil), "非活跃面板的第一次按下也应该开始拖动")
        // 最左边是对话记录按钮，它不能被拖动层盖住。
        let button = host.hitTest(NSPoint(x: 22, y: 38))
        XCTAssertFalse(button is WindowDragArea.DragView)
    }

    // MARK: - 面板缩放

    func testResizeGrabsOnlyTheEdgesAndWidensAtTheCorners() {
        let size = NSSize(width: 620, height: 180)
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 310, y: 90), in: size), [])
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 2, y: 90), in: size), .left)
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 618, y: 90), in: size), .right)
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 310, y: 178), in: size), .top)
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 310, y: 2), in: size), .bottom)
        // 角上放宽到 16 点，斜着拖才抓得住。
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 610, y: 10), in: size), [.right, .bottom])
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 8, y: 172), in: size), [.left, .top])
        // 界外和退化尺寸都不该报边。
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: -1, y: 90), in: size), [])
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 310, y: 181), in: size), [])
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 0, y: 0), in: .zero), [])
    }

    @MainActor
    func testPanelResizeCursorFollowsPrivacySwitch() {
        WispCursorPolicy.setEnabled(true)
        defer { WispCursorPolicy.setEnabled(false) }
        XCTAssertFalse(PanelController.panelStyleMask.contains(.resizable),
                       "The AppKit resizable style would reinstall the system resize cursor")
        XCTAssertEqual(PanelResize.guideInset, 4)
        let edgeCombinations: [PanelResize.Edges] = [
            [], .left, .right, .top, .bottom,
            [.left, .top], [.right, .top], [.left, .bottom], [.right, .bottom]
        ]
        for edges in edgeCombinations {
            XCTAssertTrue(PanelResize.cursor(for: edges) === NSCursor.arrow)
        }
        WispCursorPolicy.setEnabled(false)
        XCTAssertTrue(PanelResize.cursor(for: []) === NSCursor.arrow)
        for edges in edgeCombinations where !edges.isEmpty {
            XCTAssertFalse(PanelResize.cursor(for: edges) === NSCursor.arrow)
        }
    }

    func testResizeKeepsTheOppositeEdgeFixedAndObeysWindowLimits() {
        let start = NSRect(x: 200, y: 400, width: 620, height: 180)
        let minSize = NSSize(width: 380, height: 144)
        let maxSize = NSSize(width: 2400, height: 1000)
        func resized(_ edges: PanelResize.Edges, _ dx: CGFloat, _ dy: CGFloat) -> NSRect {
            PanelResize.frame(from: start, edges: edges, translation: NSSize(width: dx, height: dy),
                              minSize: minSize, maxSize: maxSize)
        }
        let wider = resized(.right, 100, 0)
        XCTAssertEqual(wider.width, 720)
        XCTAssertEqual(wider.minX, start.minX)
        let leftward = resized(.left, -100, 0)
        XCTAssertEqual(leftward.width, 720)
        XCTAssertEqual(leftward.maxX, start.maxX)
        let taller = resized(.top, 0, 120)
        XCTAssertEqual(taller.height, 300)
        XCTAssertEqual(taller.minY, start.minY)
        let lower = resized(.bottom, 0, -120)
        XCTAssertEqual(lower.height, 300)
        XCTAssertEqual(lower.maxY, start.maxY)
        // 撞到下限时对边仍然钉住，窗口不会被拖着跑。
        let squeezed = resized([.left, .bottom], 900, 900)
        XCTAssertEqual(squeezed.size, minSize)
        XCTAssertEqual(squeezed.maxX, start.maxX)
        XCTAssertEqual(squeezed.maxY, start.maxY)
        let stretched = resized([.right, .top], 5_000, 5_000)
        XCTAssertEqual(stretched.size, maxSize)
        XCTAssertEqual(stretched.origin, start.origin)
    }

    @MainActor
    func testResizeOverlayInterceptsEdgesAndLetsContentKeepItsClicks() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 180))
        let host = PanelController.makePanelContentView(ListeningView())
        host.frame = root.bounds
        root.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? PanelResizeOverlay }.first)
        XCTAssertEqual(overlay.frame, host.bounds)
        // 缩放层必须盖在内容之上，否则边缘会被 SwiftUI 先吃掉。
        XCTAssertEqual(host.subviews.last, overlay)
        XCTAssertTrue(host.hitTest(NSPoint(x: 618, y: 90)) is PanelResizeOverlay)
        XCTAssertTrue(host.hitTest(NSPoint(x: 612, y: 6)) is PanelResizeOverlay)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 310, y: 90)))
        XCTAssertFalse(host.hitTest(NSPoint(x: 310, y: 90)) is PanelResizeOverlay)
        // 发送键在右下角，离边 12 点：它的位置不能被缩放层吞掉。
        XCTAssertFalse(host.hitTest(NSPoint(x: 620 - 25, y: 22)) is PanelResizeOverlay)
    }

    @MainActor
    func testResizeOverlayDoesNotStealTitleEdgeDrags() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 180))
        let drag = WindowDragArea.DragView(frame: NSRect(x: 100, y: 174, width: 420, height: 6))
        root.addSubview(drag)
        let overlay = PanelResizeOverlay(frame: root.bounds)
        root.addSubview(overlay)

        // The title drag strip is allowed to overlap the top resize edge without
        // being converted into a resize gesture.
        XCTAssertTrue(root.hitTest(NSPoint(x: 200, y: 178)) === drag)
        XCTAssertTrue(root.hitTest(NSPoint(x: 20, y: 178)) === overlay)
    }
}
