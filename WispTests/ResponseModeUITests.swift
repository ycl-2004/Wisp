import XCTest
import AppKit
import SwiftUI
@testable import Wisp

/// The half of ResponseModeTests whose subjects are AppKit/SwiftUI types
/// (PanelController, AssistantModel, ActiveModels, rendered views). Kept in
/// its own file so ResponseModeTests.swift stays Foundation-only and also
/// runs in the Linux harness.
extension ResponseModeTests {
    @MainActor
    func testCollapsedPanelHeightTracksMultilineComposerWithoutExtraDefaultSpace() {
        // One header row plus the composer; a multiline draft grows it point for point, to a cap.
        XCTAssertEqual(PanelController.collapsedHeight, 82)
        XCTAssertEqual(PanelController.collapsedHeight(forInputHeight: ChatInput.defaultHeight), 82)
        XCTAssertEqual(PanelController.collapsedHeight(forInputHeight: ChatInput.defaultHeight - 10), 82)
        XCTAssertEqual(PanelController.collapsedHeight(forInputHeight: ChatInput.defaultHeight + 60), 142)
        XCTAssertEqual(PanelController.collapsedHeight(forInputHeight: 400), 240)
    }

    @MainActor
    func testScreenshotOnlyDeepRetryRequiresMatchingWindowTitle() {
        var packet = ContextPacket(appName: "Browser", bundleID: "test.browser")
        packet.windowTitle = "Original page"
        let quickContext = packet.snapshot()
        packet.url = "https://example.com/original"
        XCTAssertTrue(AssistantModel.isSamePage(packet, quickContext))
        packet.windowTitle = "Different page"
        XCTAssertFalse(AssistantModel.isSamePage(packet, quickContext))
    }

    @MainActor
    func testCameraOffQuickSkipsCaptureAndPreservesChatHistory() async throws {
        let model = AssistantModel.shared
        let previous = model.packet
        defer { model.packet = previous }
        let fixture = ContextPacket(appName: "Capture must not run", bundleID: "test.fixture")
        model.packet = fixture
        await model.captureShot(screenshotOnly: true, attachScreenshot: false)
        XCTAssertEqual(model.packet?.id, fixture.id)
        XCTAssertFalse(model.isCapturing)
        let messages = [Message(role: .user, text: "Meeting topic one"),
                        Message(role: .assistant, text: "Agreed on option A"),
                        Message(role: .user, text: "What about the next topic?")]
        let payload = PromptBuilder.build(messages: messages, liveScreenshot: nil, mode: .quick)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        XCTAssertTrue(text.contains("Meeting topic one"))
        XCTAssertTrue(text.contains("Agreed on option A"))
        XCTAssertTrue(text.contains("What about the next topic?"))
        XCTAssertFalse(text.contains("image_url"))
    }

    @MainActor
    func testModesAndOverridesRemainEditableWhileStreamingAndRender() throws {
        let settings = AppSettings.shared
        let model = AssistantModel.shared
        let oldMode = UserDefaults.standard.object(forKey: "responseMode")
        let oldOverrides = UserDefaults.standard.object(forKey: "responseModels")
        let oldStreaming = model.isStreaming
        defer {
            UserDefaults.standard.set(oldMode, forKey: "responseMode")
            UserDefaults.standard.set(oldOverrides, forKey: "responseModels")
            model.isStreaming = oldStreaming
        }
        let baseline = ProviderConfig.selection()
        model.isStreaming = true
        settings.responseMode = .quick
        settings.setResponseModel("fixture-fast", for: .quick, connection: baseline.responseConnectionKey)
        let sent = baseline.selecting(settings.responseMode, model: settings.responseModel(for: .quick, connection: baseline.responseConnectionKey))
        settings.responseMode = .deep
        settings.setResponseModel("fixture-deep", for: .deep, connection: baseline.responseConnectionKey)
        XCTAssertEqual(sent.model, "fixture-fast")
        XCTAssertEqual(settings.responseMode, .deep)
        XCTAssertEqual(settings.responseModel(for: .deep, connection: baseline.responseConnectionKey), "fixture-deep")
        XCTAssertTrue(model.isStreaming)
        let view = NSHostingView(rootView: ResponseModeSettings().padding(20).frame(width: 620, height: 520)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/wisp-response-settings.png"))
    }

    @MainActor
    func testNarrowComposerFitsWithVoiceAndModeControls() throws {
        let model = AssistantModel.shared
        let collapsed = model.isCollapsed
        let enabled = LiveCaptions.shared.isEnabled
        model.setCollapsedSilently(true)
        LiveCaptions.shared.isEnabled = true
        defer {
            model.setCollapsedSilently(collapsed)
            LiveCaptions.shared.isEnabled = enabled
        }
        let view = NSHostingView(rootView: ChatView().environmentObject(model).environmentObject(model.store)
            .frame(width: 380, height: PanelController.collapsedHeight))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: PanelController.collapsedHeight), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/wisp-response-narrow.png"))
    }

    /// Sending, Test Connection, the header menu and Settings all read one `ActiveModels`: Quick
    /// sends the default model itself, Deep following the default takes its High thinking level
    /// on Antigravity, an explicit per-mode choice always wins, and each connection keeps its own.
    @MainActor
    func testQuickUsesTheDefaultModelAndDeepItsHighThinkingLevel() throws {
        let keys = ["providerKind", "cliProvider", "agyModel", "agyPath", "codexModel", "responseModels", "responseMode"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let settings = AppSettings.shared, state = ModelMenuState.shared
        settings.providerKind = ProviderKind.codexCLI.rawValue
        settings.cliProvider = .agy
        settings.agyPath = "/fixture/agy"
        UserDefaults.standard.removeObject(forKey: "responseModels")
        settings.agyModel = "gemini-3.6-flash-low"

        var models = ActiveModels(settings: settings, state: state)
        XCTAssertEqual(models.connectionTitle, CLIProvider.agy.title)
        XCTAssertEqual(models.effectiveModel(for: .quick), "gemini-3.6-flash-low")
        XCTAssertEqual(models.effectiveModel(for: .deep), "gemini-3.6-flash-high")
        XCTAssertEqual(models.config(for: .deep).model, "gemini-3.6-flash-high")
        XCTAssertEqual(models.config(for: .deep).responseMode, .deep)
        XCTAssertEqual(models.config(for: .quick).model, "gemini-3.6-flash-low")
        XCTAssertFalse(models.defaultRaisesThinking(for: .quick))
        XCTAssertTrue(models.defaultRaisesThinking(for: .deep))
        XCTAssertTrue(models.defaultChoiceTitle(for: .quick).contains(models.title(of: "gemini-3.6-flash-low")))
        XCTAssertTrue(models.defaultChoiceTitle(for: .deep).contains(models.title(of: "gemini-3.6-flash-high")))

        // An explicit choice wins over the High level, and never moves the default model.
        models.setChoice("fixture-deep", for: .deep)
        XCTAssertEqual(models.effectiveModel(for: .deep), "fixture-deep")
        XCTAssertEqual(models.effectiveModel(for: .quick), "gemini-3.6-flash-low")
        XCTAssertEqual(settings.agyModel, "gemini-3.6-flash-low")
        XCTAssertEqual(models.presets(including: "fixture-deep").last?.slug, "fixture-deep")
        XCTAssertEqual(models.presets(including: "gemini-3.6-flash-low").count, models.presets.count)

        // Another connection starts from its own default; switching back restores the choice.
        settings.cliProvider = .codex
        XCTAssertEqual(ActiveModels(settings: settings, state: state).choice(for: .deep), "")
        settings.cliProvider = .agy
        XCTAssertEqual(ActiveModels(settings: settings, state: state).choice(for: .deep), "fixture-deep")
        models.setChoice("", for: .deep)

        // Models without a listed High level, or already at it, keep the default for Deep.
        for slug in ["gpt-oss-120b-medium", "claude-sonnet-4-6", "gemini-3.8-flash-high"] {
            settings.agyModel = slug
            models = ActiveModels(settings: settings, state: state)
            XCTAssertEqual(models.effectiveModel(for: .deep), slug)
            XCTAssertFalse(models.defaultRaisesThinking(for: .deep), slug)
        }

        // Codex raises thinking through its effort parameter, so both modes keep one model.
        settings.cliProvider = .codex
        settings.codexModel = "gpt-5.6-luna"
        models = ActiveModels(settings: settings, state: state)
        XCTAssertEqual(models.effectiveModel(for: .deep), "gpt-5.6-luna")
        XCTAssertEqual(models.effectiveModel(for: .quick), "gpt-5.6-luna")

        settings.cliProvider = .agy
        settings.agyModel = ""
        let empty = ActiveModels(settings: settings, state: state)
        XCTAssertEqual(empty.defaultTitle, String(localized: "Agy 默认"))
        XCTAssertEqual(empty.effectiveTitle(for: .deep), String(localized: "Agy 默认"))
    }

    @MainActor
    func testModelSettingsPageRenders() throws {
        let keys = ["providerKind", "cliProvider", "responseModels"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        AppSettings.shared.providerKind = ProviderKind.codexCLI.rawValue
        AppSettings.shared.cliProvider = .agy
        let view = NSHostingView(rootView: ModelSettingsView(flat: true).frame(width: 620)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/wisp-model-settings.png"))
    }

    /// A re-answer reads the page again only when the question was about the page still open.
    func testReanswerRereadsOnlyTheSamePage() {
        func snapshot(bundle: String?, url: String?) -> ContextSnapshot {
            ContextSnapshot(appName: "App", bundleID: bundle, windowTitle: nil, url: url, pageTitle: nil, pageText: nil,
                            pageTextTotalChars: nil, selectedText: nil, iframeURLs: [], hadScreenshot: false, capturedAt: Date())
        }
        let page = ContextPacket(appName: "Chrome", bundleID: "com.google.Chrome", url: "https://example.com/a")
        XCTAssertTrue(AssistantModel.isSamePage(page, snapshot(bundle: "com.google.Chrome", url: "https://example.com/a")))
        XCTAssertFalse(AssistantModel.isSamePage(page, snapshot(bundle: "com.google.Chrome", url: "https://example.com/b")))
        XCTAssertFalse(AssistantModel.isSamePage(page, snapshot(bundle: "com.apple.Safari", url: "https://example.com/a")))
        XCTAssertFalse(AssistantModel.isSamePage(page, nil))
        XCTAssertFalse(AssistantModel.isSamePage(nil, snapshot(bundle: "com.google.Chrome", url: "https://example.com/a")))
        let editor = ContextPacket(appName: "Xcode", bundleID: "com.apple.dt.Xcode")
        XCTAssertTrue(AssistantModel.isSamePage(editor, snapshot(bundle: "com.apple.dt.Xcode", url: nil)))
        var excluded = page
        excluded.isExcluded = true
        XCTAssertFalse(AssistantModel.isSamePage(excluded, snapshot(bundle: "com.google.Chrome", url: "https://example.com/a")))
    }

    /// Read-only: what this Mac's saved settings resolve to after the change.
    @MainActor
    func testReportCurrentSettings() throws {
        let models = ActiveModels(settings: .shared, state: .shared)
        let listening = LiveCaptions.shared
        let lines = [
            "connection: \(models.baseline.kind.rawValue) · \(models.connectionTitle)",
            "default model: \(models.baseline.model)",
            "quick choice: '\(models.choice(for: .quick))' → sends \(models.config(for: .quick).model)",
            "deep choice: '\(models.choice(for: .deep))' → sends \(models.config(for: .deep).model)",
            "deep label: \(models.defaultChoiceTitle(for: .deep))",
            "response mode: \(AppSettings.shared.responseMode.rawValue)",
            "voice enabled: \(listening.isEnabled), engine: \(listening.engine.rawValue), language: \(listening.locale), captions ask through API: \(listening.asksThroughAPI)",
            "commands: \(QuickCommandStore.shared.commands.map { "\($0.title)[\($0.mode?.rawValue ?? "current")]" }.joined(separator: ", "))",
        ]
        try lines.joined(separator: "\n").write(to: URL(fileURLWithPath: "/private/tmp/wisp-current-settings.txt"), atomically: true, encoding: .utf8)
    }
}
