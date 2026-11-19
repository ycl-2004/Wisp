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
    func testOpeningHistoryExpandsCollapsedPanel() {
        let model = AssistantModel.shared
        let collapsed = model.isCollapsed, list = model.showsConversationList
        defer {
            model.setCollapsedSilently(collapsed)
            model.showsConversationList = list
        }
        model.setCollapsedSilently(true)
        model.showsConversationList = false

        model.toggleConversationList()

        XCTAssertTrue(model.showsConversationList)
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

    @MainActor
    func testStagingDoesNotSendPersistOrCopyAndClearingRestoresNormalDraftMode() {
        let model = AssistantModel.shared
        let previous = model.input
        let previousSpeechMode = model.isSpeechDraft
        let previousList = model.showsConversationList
        let previousCollapsed = model.isCollapsed
        defer {
            model.input = ""
            if previousSpeechMode { _ = model.stageSpeechDraft(previous) } else { model.input = previous }
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
        let wasActive = LiveCaptions.shared.isActive
        try render(AudioSettingsView(), filename: "wisp-audio-settings.png")
        try render(AudioSettingsView(), filename: "wisp-audio-settings-full.png", height: 660)
        try render(DataSettingsView(wipeResult: .constant(nil)).environmentObject(AssistantModel.shared),
                   filename: "wisp-data-settings.png")
        XCTAssertEqual(LiveCaptions.shared.isActive, wasActive)
    }

    @MainActor
    func testPrivacySettingsRenderWithoutStartingPresentation() throws {
        let wasOpen = PresentationDisplay.shared.isOpen
        try render(PrivacySettingsView(), filename: "wisp-privacy-settings.png")
        XCTAssertEqual(PresentationDisplay.shared.isOpen, wasOpen)
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

    @MainActor
    func testIntegratedCompactChatRenders() throws {
        let model = AssistantModel.shared
        let collapsed = model.isCollapsed
        let enabled = LiveCaptions.shared.isEnabled
        model.setCollapsedSilently(true)
        defer {
            model.setCollapsedSilently(collapsed)
            LiveCaptions.shared.isEnabled = enabled
        }
        for voiceEnabled in [true, false] {
            LiveCaptions.shared.isEnabled = voiceEnabled
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
        let host = PanelController.makePanelContentView(PushToTalkBar())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 180),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.minSize = NSSize(width: 380, height: 144)
        window.maxSize = NSSize(width: 2400, height: 1000)
        XCTAssertTrue(try XCTUnwrap(host.subviews.first as? NSHostingView<PushToTalkBar>).sizingOptions.isEmpty)
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
    func testSpeechDraftIsRefusedWhileAnAnswerIsStreaming() {
        let model = AssistantModel.shared
        let previousInput = model.input
        let wasStreaming = model.isStreaming
        defer {
            model.isStreaming = wasStreaming
            model.input = previousInput
        }
        model.input = ""
        model.isStreaming = true
        XCTAssertFalse(model.stageSpeechDraft("刚才问的问题"))
        XCTAssertEqual(model.input, "")
    }

    // MARK: - 字幕

    /// 总开关关掉时字幕停下、快捷键开不起来。
    @MainActor
    func testDisablingVoiceStopsCaptionsAndBlocksTheShortcut() {
        let captions = LiveCaptions.shared
        let wasEnabled = captions.isEnabled
        defer { captions.isEnabled = wasEnabled; captions.stop() }
        captions.isEnabled = false
        captions.toggleFromUser()
        XCTAssertFalse(captions.isActive)
        XCTAssertFalse(captions.showsStrip)
    }

    @MainActor
    func testDisablingVoiceCancelsMicrophoneStartupAndQueuedSpeech() async {
        let captions = LiveCaptions.shared
        let microphone = PushToTalk.shared
        let model = AssistantModel.shared
        let settings = model.settings
        let saved = (captions.isEnabled, model.input, settings.providerKind, settings.ollamaBaseURL,
                     settings.ollamaModel, settings.responseMode, settings.sendScreenshot, model.isCollapsed)
        defer {
            PanelController.shared.hide()
            model.stopStreaming()
            captions.isEnabled = saved.0
            model.input = saved.1
            settings.providerKind = saved.2
            settings.ollamaBaseURL = saved.3
            settings.ollamaModel = saved.4
            settings.responseMode = saved.5
            settings.sendScreenshot = saved.6
            model.setCollapsedSilently(saved.7)
        }
        settings.providerKind = ProviderKind.ollama.rawValue
        settings.ollamaBaseURL = "http://127.0.0.1:1/v1"
        settings.ollamaModel = "test-model"
        settings.responseMode = .quick
        settings.sendScreenshot = false
        model.input = "Keep this typed draft"
        let messageCount = model.store.conversations.reduce(0) { $0 + $1.messages.count }

        captions.isEnabled = true
        // Both operations are cancelled before the actor can run their queued work.
        microphone.begin()
        XCTAssertEqual(microphone.state, .preparing)
        XCTAssertTrue(model.submitSpeech("Do not send this transcription"))
        XCTAssertTrue(model.isPreparingResponse)
        captions.isEnabled = false
        microphone.end()
        PanelController.shared.hide()
        await Task.yield()

        XCTAssertEqual(microphone.state, .idle)
        XCTAssertTrue(microphone.caption.isEmpty)
        XCTAssertFalse(model.isPreparingResponse)
        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(model.input, "Keep this typed draft")
        XCTAssertEqual(model.store.conversations.reduce(0) { $0 + $1.messages.count }, messageCount)
    }

    @MainActor
    func testCaptionCommandFailureStaysInTheCompactPanel() throws {
        let captions = LiveCaptions.shared
        let model = AssistantModel.shared
        let saved = (captions.isEnabled, model.errorText, model.isCollapsed)
        defer {
            captions.isEnabled = saved.0
            model.errorText = saved.1
            model.setCollapsedSilently(saved.2)
        }
        captions.isEnabled = true
        captions.stop()
        model.setCollapsedSilently(true)
        model.errorText = nil
        let height = PanelController.extraRowsHeight

        model.run(QuickCommand.captionDefaults[0])

        XCTAssertTrue(model.isCollapsed)
        XCTAssertEqual(model.panelError, String(localized: "请先点面板上的字幕按钮，再运行这条指令。"))
        XCTAssertEqual(PanelController.extraRowsHeight, height + ChatView.errorRowHeight)
        try render(ChatView().environmentObject(model).environmentObject(model.store),
                   filename: "wisp-compact-caption-error.png", width: 380,
                   height: PanelController.collapsedHeight + PanelController.extraRowsHeight)
    }

    /// 停字幕要把内存里的话和那个不保存的提问对话一起扔掉。
    @MainActor
    func testStoppingCaptionsDiscardsTheCaptionConversation() {
        let store = ConversationStore.shared
        let previousActive = store.activeID
        defer { store.discardEphemeral(); if let previousActive { store.select(previousActive) } }
        let saved = store.savedCount
        let caption = store.activateEphemeral(title: "会议提问（不保存）")
        XCTAssertEqual(store.activeID, caption.id)
        XCTAssertEqual(store.savedCount, saved, "不保存的对话不占对话上限")
        LiveCaptions.shared.stop()
        XCTAssertFalse(store.conversations.contains { $0.id == caption.id })
        XCTAssertNotEqual(store.activeID, caption.id)
    }

    /// 面板里的字幕条每种状态都在默认宽度和最窄宽度下渲染；最新的字在末尾，两行放不下时丢的是开头。
    @MainActor
    func testCaptionBarRendersEveryStateAtBothWidths() throws {
        let long = "我们这个项目的 RAG 链路是先把文档切块，然后存到向量数据库里面。你能说一下这个 folder 里面的 API 是怎么调用的吗？"
        let states: [(String, CaptionBar)] = [
            ("starting", CaptionBar(state: .starting, text: "")),
            ("listening", CaptionBar(state: .running, text: "", lastChange: Date())),
            ("words", CaptionBar(state: .running, text: long, lastChange: Date())),
            ("quiet", CaptionBar(state: .running, text: long, lastChange: Date().addingTimeInterval(-30))),
            ("message", CaptionBar(state: .idle, text: "", message: "电脑进入睡眠或锁定，字幕已停止。")),
            ("permission", CaptionBar(state: .idle, text: "",
                                      message: "字幕要用「屏幕与系统音频录制」权限才能听电脑的声音。请在系统设置中打开 Wisp，再开字幕。",
                                      openSettings: {})),
        ]
        for (name, bar) in states {
            for width in [PanelController.width, 380] {
                try render(bar.background(Color(nsColor: .windowBackgroundColor)),
                           filename: "wisp-caption-bar-\(name)-\(Int(width)).png",
                           width: width, height: CaptionBar.height)
            }
        }
    }

    @MainActor
    func testPushToTalkRowRendersEveryState() throws {
        for (name, state, caption) in [("preparing", PushToTalk.State.preparing, ""),
                                       ("listening", .listening, "RAG 是什么？"),
                                       ("finishing", .finishing, "RAG 是什么？")] {
            try render(PushToTalkRow(state: state, caption: caption).background(Color(nsColor: .windowBackgroundColor)),
                       filename: "wisp-push-to-talk-\(name).png", width: 380, height: 32)
        }
    }

    /// 字幕条在面板里：收起时面板为它让出高度，关掉字幕就还回去。
    @MainActor
    func testCollapsedPanelMakesRoomForTheCaptionStrip() {
        let captions = LiveCaptions.shared
        captions.stop()
        defer { captions.dismissMessage() }
        let plain = PanelController.collapsedHeight(forInputHeight: ChatInput.defaultHeight)
        let rowsBefore = PanelController.extraRowsHeight
        XCTAssertEqual(plain, PanelController.collapsedHeight)
        captions.stop(reason: "Caption test message")
        XCTAssertEqual(PanelController.extraRowsHeight, rowsBefore + CaptionBar.height)
        XCTAssertEqual(PanelController.collapsedHeight(forInputHeight: ChatInput.defaultHeight + 30), plain + 30)
    }

    /// 展开和收起时底边不动：输入框留在原地，面板向上打开。
    @MainActor
    func testExpandingOpensUpwardFromTheInputBox() {
        let collapsed = NSRect(x: 300, y: 100, width: 620, height: 162)
        let expanded = PanelController.frame(collapsed, resizedTo: 560)
        XCTAssertEqual(expanded.minY, collapsed.minY)
        XCTAssertEqual(expanded.minX, collapsed.minX)
        XCTAssertEqual(expanded.height, 560)
        XCTAssertEqual(PanelController.frame(expanded, resizedTo: 162), collapsed)
    }

    func testPanelReopensOnItsSavedDisplayAndFallsBackWhenDisconnected() {
        let primary = NSRect(x: 0, y: 24, width: 1440, height: 850)
        let external = NSRect(x: -1920, y: 100, width: 1920, height: 1000)
        let displays = [(frame: primary, visibleFrame: primary), (frame: external, visibleFrame: external)]
        let size = NSSize(width: 620, height: 82)
        let savedOrigin = NSPoint(x: -1000, y: 140)

        XCTAssertEqual(ScreenGeometry.panelFrame(size: size, savedOrigin: savedOrigin,
                                                 displays: displays, fallback: primary),
                       NSRect(origin: savedOrigin, size: size))
        let fallback = NSRect(x: 410, y: 40, width: 620, height: 82)
        XCTAssertEqual(ScreenGeometry.panelFrame(size: size, savedOrigin: savedOrigin,
                                                 displays: [displays[0]], fallback: primary), fallback)
        XCTAssertEqual(ScreenGeometry.panelFrame(size: size, savedOrigin: nil,
                                                 displays: displays, fallback: primary), fallback)
    }

    @MainActor
    func testHidingThePanelStopsCaptions() {
        let captions = LiveCaptions.shared
        PanelController.shared.hide()
        XCTAssertFalse(captions.isActive)
    }

    // MARK: - 面板缩放

    func testResizeGrabsTheSideAndBottomEdgesButNotTheTopEdge() {
        let size = NSSize(width: 620, height: 180)
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 310, y: 90), in: size), [])
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 2, y: 90), in: size), .left)
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 618, y: 90), in: size), .right)
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 310, y: 2), in: size), .bottom)
        // 顶边和面板其余空白处一样用来拖动，不缩放——包括两个上角。
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 310, y: 178), in: size), [])
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 2, y: 178), in: size), [])
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 618, y: 174), in: size), [])
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 8, y: 172), in: size), [])
        // 顶上那一条以下，两条侧边照常缩放。
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 2, y: 173), in: size), .left)
        // 下面两个角放宽到 16 点，斜着拖才抓得住。
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 610, y: 10), in: size), [.right, .bottom])
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 8, y: 8), in: size), [.left, .bottom])
        // 界外和退化尺寸都不该报边。
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: -1, y: 90), in: size), [])
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 310, y: 181), in: size), [])
        XCTAssertEqual(PanelResize.edges(at: NSPoint(x: 0, y: 0), in: .zero), [])
    }

    /// The blue guide says where the panel resizes; the pointer itself never changes, on any edge.
    @MainActor
    func testHoveringAResizeEdgeLeavesThePointerAlone() throws {
        XCTAssertFalse(PanelController.panelStyleMask.contains(.resizable),
                       "The AppKit resizable style would reinstall the system resize cursor")
        XCTAssertEqual(PanelResize.guideInset, 4)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let overlay = PanelResizeOverlay(frame: NSRect(x: 0, y: 0, width: 620, height: 180))
        window.contentView = overlay
        NSCursor.arrow.set()
        // Both sides, the bottom, a bottom corner, the top edge and the middle.
        for point in [NSPoint(x: 2, y: 90), NSPoint(x: 618, y: 90), NSPoint(x: 310, y: 2),
                      NSPoint(x: 4, y: 4), NSPoint(x: 310, y: 178), NSPoint(x: 310, y: 90)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            overlay.mouseMoved(with: event)
            XCTAssertTrue(NSCursor.current === NSCursor.arrow, "pointer changed at \(point)")
        }
        overlay.mouseExited(with: try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: -5, y: 90), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
    }

    /// The panel follows the mouse by the distance it travelled and cannot be dragged off screen.
    @MainActor
    func testDraggingMovesTheWindowWithTheMouseAndKeepsItOnScreen() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let window = NSWindow(contentRect: NSRect(x: (visible.midX - 200).rounded(), y: visible.midY.rounded(),
                                                  width: 400, height: 82),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // Whole points, as AppKit placed it.
        let start = window.frame, size = start.size
        let grab = NSPoint(x: start.minX + 100, y: start.minY + 40)

        let move = PanelMove()
        move.changed(mouse: grab, window: window)
        XCTAssertEqual(window.frame.origin, start.origin, "the first event only marks where the drag began")
        move.changed(mouse: NSPoint(x: grab.x + 30, y: grab.y - 20), window: nil)
        XCTAssertEqual(window.frame.origin, NSPoint(x: start.minX + 30, y: start.minY - 20))
        XCTAssertEqual(window.frame.size, size, "moving never resizes")
        // Far past the bottom-right corner: the whole window stays in the visible area.
        move.changed(mouse: NSPoint(x: visible.maxX - 1, y: visible.minY + 1), window: nil)
        XCTAssertTrue(visible.contains(window.frame), "\(window.frame) left \(visible)")

        // Each drag measures from its own start.
        move.ended()
        let before = window.frame.origin
        move.changed(mouse: NSPoint(x: visible.midX, y: visible.midY), window: window)
        XCTAssertEqual(window.frame.origin, before)
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
        let lower = resized(.bottom, 0, -120)
        XCTAssertEqual(lower.height, 300)
        XCTAssertEqual(lower.maxY, start.maxY)
        // 撞到下限时对边仍然钉住，窗口不会被拖着跑。
        let squeezed = resized([.left, .bottom], 900, 900)
        XCTAssertEqual(squeezed.size, minSize)
        XCTAssertEqual(squeezed.maxX, start.maxX)
        XCTAssertEqual(squeezed.maxY, start.maxY)
        let stretched = resized([.right, .bottom], 5_000, -5_000)
        XCTAssertEqual(stretched.size, maxSize)
        XCTAssertEqual(stretched.minX, start.minX)
        XCTAssertEqual(stretched.maxY, start.maxY)
    }

    @MainActor
    func testResizeOverlayInterceptsEdgesAndLetsContentKeepItsClicks() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 180))
        let host = PanelController.makePanelContentView(PushToTalkBar())
        host.frame = root.bounds
        root.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? PanelResizeOverlay }.first)
        XCTAssertEqual(overlay.frame, host.bounds)
        // 缩放层必须盖在内容之上，否则边缘会被 SwiftUI 先吃掉。
        XCTAssertEqual(host.subviews.last, overlay)
        XCTAssertTrue(host.hitTest(NSPoint(x: 618, y: 90)) is PanelResizeOverlay)
        XCTAssertTrue(host.hitTest(NSPoint(x: 612, y: 6)) is PanelResizeOverlay)
        // The top edge is not a resize edge: a press there reaches the content, which drags the panel.
        XCTAssertNil(overlay.hitTest(NSPoint(x: 310, y: 178)))
        XCTAssertFalse(host.hitTest(NSPoint(x: 310, y: 178)) is PanelResizeOverlay)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 310, y: 90)))
        XCTAssertFalse(host.hitTest(NSPoint(x: 310, y: 90)) is PanelResizeOverlay)
        // 发送键在右下角，离边 12 点：它的位置不能被缩放层吞掉。
        XCTAssertFalse(host.hitTest(NSPoint(x: 620 - 25, y: 22)) is PanelResizeOverlay)
    }
}
