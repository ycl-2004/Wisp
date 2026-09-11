import AVFoundation
import SwiftUI
import XCTest
@testable import Wisp

final class ListeningTests: XCTestCase {
    private func transcript() -> ListeningTranscript {
        ListeningTranscript(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_000),
                            locale: "en-US", applicationName: "Fixture", savesAudio: false)
    }

    private func segment(id: UUID = UUID(), source: ListeningSource = .application,
                         start: Double, end: Double, text: String, final: Bool = true) -> ListeningSegment {
        ListeningSegment(id: id, source: source, start: start, end: end, text: text, isFinal: final)
    }

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

    func testStorageAdmissionRejectsRootLinksWithoutTouchingTheirTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let link = root.appendingPathComponent("Listening")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ListeningStorageBudget.validate(root: link, savesAudio: false))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try ListeningStorageBudget.validate(root: dangling, savesAudio: false))
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

    func testPartialRevisionDoesNotDuplicateAndLatePartialCannotUndoFinal() {
        var transcript = transcript()
        let id = UUID()
        transcript.upsert(segment(id: id, start: 1, end: 2, text: "ship", final: false))
        transcript.upsert(segment(id: id, start: 1, end: 3, text: "ship tomorrow"))
        transcript.upsert(segment(id: id, start: 1, end: 2, text: "ship", final: false))
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].text, "ship tomorrow")
        XCTAssertTrue(transcript.segments[0].isFinal)
    }

    func testTwoSourcesRemainSeparateAndOutOfOrderCallbacksAreSorted() {
        var transcript = transcript()
        transcript.upsert(segment(source: .microphone, start: 20, end: 22, text: "My response"))
        transcript.upsert(segment(start: 10, end: 30, text: "Their question"))
        transcript.upsert(segment(start: 0, end: 1, text: "  \n"))
        XCTAssertEqual(transcript.segments.map(\.source), [.application, .microphone])
        XCTAssertEqual(transcript.segments.map(\.start), [10, 20])
    }

    /// 会议里隔几分钟才按一次分析，中间这几分钟必须一起交出去。早先按「最近 90 秒」取，
    /// 间隔一超过 90 秒，中间说的话就再也进不了任何一次发送，只剩本地记录里有。
    func testEverythingSinceTheLastTransferIsSentHoweverLongAgoItWasSaid() {
        var transcript = transcript()
        let staged = segment(start: 0, end: 5, text: "已经交出去的开场")
        transcript.upsert(staged)
        transcript.upsert(segment(start: 40, end: 160, text: "五分钟前说的重点"))
        transcript.upsert(segment(source: .microphone, start: 300, end: 305, text: "刚刚说的最后一句"))
        transcript.stoppedAt = Date(timeIntervalSince1970: 100_000)
        let pending = transcript.unstagedText(excluding: [staged.id])
        XCTAssertTrue(pending.contains("五分钟前说的重点"))
        XCTAssertTrue(pending.contains("刚刚说的最后一句"))
        XCTAssertFalse(pending.contains("已经交出去的开场"))
    }

    func testExplanationBudgetAndUncertainTextArePreserved() {
        var transcript = transcript()
        transcript.upsert(segment(start: 0, end: 5, text: String(repeating: "你好🌤", count: 100), final: false))
        XCTAssertEqual(transcript.spokenText(characterLimit: 60).count, 60)
        XCTAssertTrue(transcript.spokenText().contains(String(localized: "（末尾是临时文字，可能还会修正）")))
        XCTAssertEqual(transcript.spokenText(characterLimit: 0), "")
    }

    func testPersistentSessionAndReadableTextRoundTripWithoutAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var transcript = transcript()
        transcript.upsert(segment(start: 3661, end: 3662, text: "Hello 你好"))
        try transcript.save(in: directory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ListeningTranscript.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        XCTAssertEqual(restored.segments, transcript.segments)
        XCTAssertFalse(restored.savesAudio)
        let text = try String(contentsOf: directory.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("01:01:01"))
        XCTAssertTrue(text.contains("Hello 你好"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["session.json", "transcript.txt"])
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

    /// 输入框里的转写要像一段话，不是一堆 `[00:00:01–00:00:02] 我方麦克风:` 开头的碎行。
    func testDraftTextDropsTimestampsAndMergesEachSpeakersBatches() {
        var single = transcript()
        single.upsert(segment(source: .microphone, start: 0, end: 2, text: "等下帮我看一下什么情况"))
        single.upsert(segment(source: .microphone, start: 2, end: 4, text: "就这种东西"))
        XCTAssertEqual(single.spokenText(), "等下帮我看一下什么情况 就这种东西")
        XCTAssertFalse(single.spokenText().contains("00:00"))
        // 只有一个音源时连说话人都不必标：本来就只有他在说。
        XCTAssertFalse(single.spokenText().contains(ListeningSource.microphone.title))
        // 存到本地的那份仍然带完整时间戳。
        XCTAssertTrue(single.text.contains("[00:00:00–00:00:02]"))

        var both = transcript()
        both.upsert(segment(source: .microphone, start: 0, end: 2, text: "我们下周一给结论"))
        both.upsert(segment(source: .application, start: 2, end: 4, text: "好，那就这么定"))
        both.upsert(segment(source: .application, start: 4, end: 6, text: "我记一下", final: false))
        let turns = both.spokenText().components(separatedBy: "\n")
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0], "\(ListeningSource.microphone.title): 我们下周一给结论")
        XCTAssertTrue(turns[1].hasPrefix("\(ListeningSource.application.title): 好，那就这么定 我记一下"))
        // 临时标记按段落标一次，不是每一批都标。
        let mark = String(localized: "（末尾是临时文字，可能还会修正）")
        XCTAssertEqual(both.spokenText().components(separatedBy: mark).count - 1, 1)
    }

    func testDraftPreservesExistingTextAndDoesNotFollowLaterRecognition() {
        var transcript = transcript()
        let part = segment(start: 0, end: 1, text: "first version", final: false)
        transcript.upsert(part)
        let draft = ListeningTranscript.appendingToDraft(transcript.unstagedText(excluding: []), existing: "My question")!
        transcript.upsert(segment(id: part.id, start: 0, end: 2, text: "corrected version"))
        XCTAssertTrue(draft.hasPrefix("My question\n\n"))
        XCTAssertTrue(draft.contains("first version"))
        XCTAssertFalse(draft.contains("corrected version"))
        XCTAssertNil(ListeningTranscript.appendingToDraft("more", existing: String(repeating: "x", count: 12_000)))
    }

    func testTranscriptRejectsOversizedRevisionWithoutChangingSavedText() {
        var transcript = transcript()
        let part = segment(start: 0, end: 1, text: "preserved", final: false)
        XCTAssertTrue(transcript.upsert(part))
        XCTAssertFalse(transcript.upsert(segment(id: part.id, start: 0, end: 2,
            text: String(repeating: "x", count: ListeningTranscript.maximumCharacters + 1))))
        XCTAssertEqual(transcript.segments, [part])
        // One grapheme can contain many combining marks: character limits alone are insufficient.
        let pathological = "a" + String(repeating: "\u{0301}", count: 1_000_001)
        XCTAssertEqual(pathological.count, 1)
        XCTAssertFalse(transcript.upsert(segment(start: 2, end: 3, text: pathological)))
        XCTAssertEqual(transcript.segments, [part])
        transcript.segments = (0..<ListeningTranscript.maximumSegments).map {
            segment(start: Double($0), end: Double($0 + 1), text: "x")
        }
        XCTAssertFalse(transcript.upsert(segment(start: 9999, end: 10000, text: "too many")))
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

    func testStorageAdmissionReservesSpaceAndNeverDeletesOldRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.caf")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        // Sparse file measures logical storage without allocating gigabytes in the test.
        let size = ListeningStorageBudget.maximumBytes - ListeningStorageBudget.audioReservation + 1
        try handle.truncate(atOffset: UInt64(size))
        XCTAssertThrowsError(try ListeningStorageBudget.validate(root: root, savesAudio: true))
        XCTAssertNoThrow(try ListeningStorageBudget.validate(root: root, savesAudio: false))
        XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(size))
        try handle.truncate(atOffset: 0)
        for _ in 0..<ListeningStorageBudget.maximumSessions {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        }
        XCTAssertThrowsError(try ListeningStorageBudget.validate(root: root, savesAudio: false))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 101)
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

    func testListeningModesKeepMicrophoneOptInAndSourcesSeparate() {
        XCTAssertEqual(ListeningPreferences().mode, .application)
        XCTAssertEqual(ListeningMode.application.sources, [.application])
        XCTAssertEqual(ListeningMode.microphone.sources, [.microphone])
        XCTAssertEqual(Set(ListeningMode.both.sources), Set([.microphone, .application]))
    }

    func testListeningPreferencesPersistAndRejectUnsupportedSavedLocale() throws {
        let suite = "wisp-listening-settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ListeningPreferences.load(from: defaults), ListeningPreferences())
        var preferences = ListeningPreferences(mode: .both, locale: "zh-CN", savesAudio: true)
        preferences.save(to: defaults)
        XCTAssertEqual(ListeningPreferences.load(from: defaults), preferences)
        preferences.locale = "invalid-language"
        preferences.save(to: defaults)
        XCTAssertEqual(ListeningPreferences.load(from: defaults).locale, "en-US")
        defaults.set(Data("broken".utf8), forKey: ListeningPreferences.key)
        XCTAssertEqual(ListeningPreferences.load(from: defaults), ListeningPreferences())
    }

    func testFocusedCleanupRemovesOnlyListeningAndIsSafeToRepeat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("Listening/session")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = root.appendingPathComponent("conversations.json")
        try Data("keep chat".utf8).write(to: chat)
        try Data("fixture speech".utf8).write(to: sessions.appendingPathComponent("transcript.txt"))
        try Data([0, 1, 2]).write(to: sessions.appendingPathComponent("microphone.caf"))
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("link"), withDestinationURL: chat)
        try ListeningStorageBudget.clearRecords(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Listening").path))
        XCTAssertEqual(try Data(contentsOf: chat), Data("keep chat".utf8))
        XCTAssertNoThrow(try ListeningStorageBudget.clearRecords(in: root))
        XCTAssertNoThrow(try ListeningStorageBudget.validate(root: root.appendingPathComponent("Listening"), savesAudio: true))
    }

    @MainActor
    func testAudioAndDataSettingsRenderWithoutStartingCapture() throws {
        let wasActive = ListeningModel.shared.isActive
        try render(AudioSettingsView(), filename: "wisp-audio-settings.png")
        try render(AudioSettingsView(), filename: "wisp-audio-settings-full.png", height: 660)
        try render(DataSettingsView().environmentObject(AssistantModel.shared), filename: "wisp-data-settings.png")
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
        XCTAssertTrue(transcript.unstagedText(excluding: []).contains("first question"))
        transcript.upsert(segment(id: first.id, start: 0, end: 4, text: "corrected first question"))
        XCTAssertEqual(transcript.unstagedText(excluding: [first.id]), "")
        let next = segment(start: 5, end: 9, text: "next question")
        transcript.upsert(next)
        let pending = transcript.unstagedText(excluding: [first.id])
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

    func testDraftBudgetTrimsWholeTurnsFromTheOldestEnd() {
        var transcript = transcript()
        for index in 0..<10 {
            transcript.upsert(segment(source: index.isMultiple(of: 2) ? .application : .microphone,
                                      start: Double(index * 4), end: Double(index * 4 + 4),
                                      text: "第\(index)段会议内容"))
        }
        XCTAssertEqual(transcript.spokenText().components(separatedBy: "\n").count, 10)
        let trimmed = transcript.spokenText(characterLimit: 60)
        XCTAssertFalse(trimmed.isEmpty)
        XCTAssertLessThanOrEqual(trimmed.count, 60)
        for line in trimmed.components(separatedBy: "\n") {
            XCTAssertTrue(line.contains(": 第"), "整轮发言一起丢，不能切出半句话：\(line)")
        }
        XCTAssertTrue(trimmed.contains("第9段"))
        XCTAssertFalse(trimmed.contains("第0段"))
    }

    /// 一场半小时的会议一次没按过分析，停止时能交出去多少：按比日常更快的语速算，
    /// 12,000 字的预算大约装得下最后二十分钟，更早的部分整段丢，且丢的是最旧的。
    func testAWholeMeetingIsCarriedUpToTheDraftBudget() {
        var transcript = transcript()
        // 每 4 秒一批、每批 20 字 ≈ 每秒 5 字，快于日常语速；录满一小时。
        let batch = String(repeating: "会议内容记录要点", count: 2) + "结论待办"
        XCTAssertEqual(batch.count, 20)
        for index in 0..<900 {
            transcript.upsert(segment(start: Double(index * 4), end: Double(index * 4 + 4),
                                      text: "第\(index)句" + batch))
        }
        let whole = transcript.spokenText()
        XCTAssertLessThanOrEqual(whole.count, ListeningTranscript.draftLimit)
        // 一个人连着说，出来是连贯的一段，不是四百多行碎片。
        XCTAssertFalse(whole.contains("\n"))
        // 丢的是开头，留的是最近说的。
        XCTAssertFalse(whole.contains("第0句"))
        XCTAssertTrue(whole.contains("第899句"))
        // 丢的边界落在一句话的开头，不是把某句从中间切开。
        XCTAssertTrue(whole.hasPrefix("第"), "裁剪不能切出半句话：\(whole.prefix(20))")
        let minutes = Double(transcript.segments.count * 4) / 60
        let carried = Double(whole.count) / Double(transcript.spokenText(characterLimit: .max).count)
        let attachment = XCTAttachment(string: "\(Int(minutes)) min at 5 chars/s → "
            + "\(transcript.spokenText(characterLimit: .max).count) chars spoken, "
            + "\(whole.count) carried (\(Int(carried * 100))%), budget=\(ListeningTranscript.draftLimit)")
        attachment.name = "draft budget measurement"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPendingPredicateAgreesWithTheTextThatWouldBeSent() {
        var transcript = transcript()
        let first = segment(start: 0, end: 4, text: "第一句")
        let second = segment(start: 300, end: 304, text: "很久以后的第二句")
        transcript.upsert(first)
        XCTAssertTrue(transcript.hasUnstagedText(excluding: []))
        XCTAssertFalse(transcript.hasUnstagedText(excluding: [first.id]))
        XCTAssertEqual(transcript.unstagedText(excluding: [first.id]), "")
        transcript.upsert(second)
        // 交出去过的那段之外还剩内容：按钮亮着，取到的文字也确实非空。
        XCTAssertTrue(transcript.hasUnstagedText(excluding: [first.id]))
        XCTAssertFalse(transcript.unstagedText(excluding: [first.id]).isEmpty)
        XCTAssertFalse(transcript.hasUnstagedText(excluding: [first.id, second.id]))
        XCTAssertEqual(transcript.unstagedText(excluding: [first.id, second.id]), "")
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
    func testPanelResizeAlwaysUsesArrowCursor() {
        XCTAssertFalse(PanelController.panelStyleMask.contains(.resizable),
                       "The AppKit resizable style would reinstall the system resize cursor")
        let edgeCombinations: [PanelResize.Edges] = [
            [], .left, .right, .top, .bottom,
            [.left, .top], [.right, .top], [.left, .bottom], [.right, .bottom]
        ]
        for edges in edgeCombinations {
            XCTAssertTrue(PanelResize.cursor(for: edges) === NSCursor.arrow)
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
