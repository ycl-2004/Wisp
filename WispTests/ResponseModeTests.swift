import XCTest
import AppKit
import SwiftUI
@testable import Wisp

final class ResponseModeTests: XCTestCase {
    func testCustomerModesAreQuickAndDeepAndLegacyStandardMigratesToQuick() {
        XCTAssertEqual(ResponseMode.allCases, [.quick, .deep])
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "responseMode")
        defer {
            if let previous { defaults.set(previous, forKey: "responseMode") }
            else { defaults.removeObject(forKey: "responseMode") }
        }
        defaults.set(ResponseMode.standard.rawValue, forKey: "responseMode")
        XCTAssertEqual(AppSettings.shared.responseMode, .quick)
        defaults.set(ResponseMode.deep.rawValue, forKey: "responseMode")
        XCTAssertEqual(AppSettings.shared.responseMode, .deep)
    }

    @MainActor
    func testCollapsedPanelHeightTracksMultilineComposerWithoutExtraDefaultSpace() {
        XCTAssertEqual(PanelController.collapsedHeight, 140)
        XCTAssertEqual(PanelController.collapsedHeight(forInputHeight: ChatInput.defaultHeight), 140)
        XCTAssertEqual(PanelController.collapsedHeight(forInputHeight: ChatInput.defaultHeight - 10), 140)
        XCTAssertEqual(PanelController.collapsedHeight(forInputHeight: 80), 200)
        XCTAssertEqual(PanelController.collapsedHeight(forInputHeight: 400), 240)
    }

    func testSelectionFreezesRequestAndIsolatesConnections() {
        let baseline = ProviderConfig(baseURL: "https://example.com/v1", apiKey: "fixture", model: "original")
        let sent = baseline.selecting(.quick, model: "  fast-model  ")
        let next = baseline.selecting(.deep, model: "strong-model")
        XCTAssertEqual(sent.model, "fast-model")
        XCTAssertEqual(sent.responseMode, .quick)
        XCTAssertEqual(next.model, "strong-model")
        XCTAssertEqual(sent.apiKey, baseline.apiKey)
        XCTAssertEqual(baseline.selecting(.standard, model: "ignored").model, "original")
        XCTAssertEqual(baseline.selecting(.quick, model: "  ").model, "original")
        var other = baseline
        other.baseURL += "/other"
        XCTAssertNotEqual(baseline.responseConnectionKey, other.responseConnectionKey)
        var cosmetic = baseline
        cosmetic.baseURL = "  HTTPS://EXAMPLE.COM/v1/  "
        XCTAssertEqual(baseline.responseConnectionKey, cosmetic.responseConnectionKey)
        var cli = ProviderConfig(kind: .codexCLI, cliProvider: .codex, cliPath: "/tmp/../tmp/codex")
        var cliCosmetic = cli
        cliCosmetic.cliPath = "/tmp/codex"
        XCTAssertEqual(cli.responseConnectionKey, cliCosmetic.responseConnectionKey)
        cliCosmetic.cliProvider = .agy
        XCTAssertNotEqual(cli.responseConnectionKey, cliCosmetic.responseConnectionKey)
        XCTAssertFalse(ResponseMode.quick.capturesPageText)
        XCTAssertTrue(ResponseMode.deep.capturesPageText)
    }

    func testSpeedAndReasoningAreIndependent() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.openai.com/v1/chat/completions"))
        for mode in ResponseMode.allCases {
            let body = ResponsePolicy.applying(mode, to: OpenAICompatibleProvider.speedPreferredBody(["model": "gpt-5"], endpoint: endpoint), endpoint: endpoint)
            XCTAssertEqual(body["service_tier"] as? String, "priority")
            XCTAssertEqual(body["reasoning_effort"] as? String, mode == .standard ? nil : mode == .quick ? "low" : "high")
        }
        for model in ["gpt-5-pro", "gpt-5-chat-latest", "o3-pro", "o3-deep-research"] {
            XCTAssertNil(ResponsePolicy.applying(.quick, to: ["model": model], endpoint: endpoint)["reasoning_effort"])
        }
        let custom = try XCTUnwrap(URL(string: "https://example.com/v1/chat/completions"))
        let body = ResponsePolicy.applying(.deep, to: ["model": "gpt-5"], endpoint: custom)
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["service_tier"])
    }

    func testQuickRoutingPreservesFreeModel() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://openrouter.ai/api/v1/chat/completions"))
        let body = ResponsePolicy.applying(.quick, to: OpenAICompatibleProvider.speedPreferredBody(["model": "fixture:free"], endpoint: endpoint), endpoint: endpoint)
        XCTAssertEqual(body["model"] as? String, "fixture:free")
        XCTAssertNil(body["service_tier"])
        XCTAssertEqual((body["provider"] as? [String: Any])?["sort"] as? String, "latency")
        XCTAssertEqual((body["provider"] as? [String: Any])?["allow_fallbacks"] as? Bool, true)
    }

    func testPriorityRetryIsNarrowAndOnlyOnce() throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["service_tier": "priority"])
        let rejection = Data(#"{"error":{"message":"service_tier priority is not supported for this model"}}"#.utf8)
        XCTAssertTrue(OpenAICompatibleProvider.rejectsPriority(status: 400, data: rejection, request: request))
        for status in [401, 429, 500] {
            XCTAssertFalse(OpenAICompatibleProvider.rejectsPriority(status: status, data: rejection, request: request))
        }
        let unrelated = Data(#"{"error":{"message":"image input is not supported"}}"#.utf8)
        XCTAssertFalse(OpenAICompatibleProvider.rejectsPriority(status: 400, data: unrelated, request: request))
        request.httpBody = Data("{}".utf8)
        XCTAssertFalse(OpenAICompatibleProvider.rejectsPriority(status: 400, data: rejection, request: request))
    }

    func testCodexAdvertisedFastSurvivesEveryMode() throws {
        for mode in ResponseMode.allCases {
            var session = CodexCLIProvider.AppServerSession(prompt: "fixture", imagePaths: [], directory: "/tmp", model: "fixture", responseMode: mode)
            _ = try session.receive(["id": 0, "result": [:]])
            let listing = try session.receive(["id": 3, "result": ["data": [["model": "fixture", "serviceTiers": [["id": "priority", "name": "Fast"]], "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"]]]]]])
            let params = try XCTUnwrap(listing.requests.first?["params"] as? [String: Any])
            XCTAssertEqual(params["serviceTier"] as? String, "priority")
            let turn = try session.receive(["id": 1, "result": ["thread": ["id": "fixture-thread"]]])
            let turnParams = try XCTUnwrap(turn.requests.first?["params"] as? [String: Any])
            XCTAssertEqual(turnParams["effort"] as? String, mode == .standard ? nil : mode == .quick ? "low" : "high")
        }
    }

    func testTimingIgnoresWhitespaceAndSeparatesPreparation() {
        var timing = ResponseTiming(mode: .quick, model: "fixture", startedAt: 100)
        timing.requestStartedAt = 102
        timing.receive(" \n", at: 103)
        XCTAssertNil(timing.firstTextAt)
        timing.receive("Answer", at: 104)
        timing.receive(" more", at: 105)
        timing.finishedAt = 110
        XCTAssertEqual(timing.preparationSeconds, 2)
        XCTAssertEqual(timing.firstAnswerSeconds, 4)
        XCTAssertEqual(timing.providerFirstTextSeconds, 2)
        XCTAssertEqual(timing.totalSeconds, 10)
    }

    func testPromptIncludesEvidenceAndSkippedCoverage() {
        let payload = PromptBuilder.build(messages: [], liveScreenshot: nil, mode: .quick, skippedPageCapture: true)
        let system = payload.first?["content"] as? String ?? ""
        XCTAssertTrue(system.contains(ResponsePolicy.evidenceInstructions))
        XCTAssertTrue(system.contains(ResponsePolicy.skippedContextNotice))
        XCTAssertTrue(system.contains(ResponseMode.quick.prompt))
    }
}

private final class PriorityFallbackProtocol: URLProtocol {
    static var payloads: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.payloads.append(body)
        let priority = body["service_tier"] as? String == "priority"
        let response = HTTPURLResponse(url: request.url!, statusCode: priority ? 400 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let text = priority ? #"{"error":{"message":"service_tier priority is not available for this model"}}"#
            : "data: {\"choices\":[{\"delta\":{\"content\":\"fixture answer\"}}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension ResponseModeTests {
    func testStreamingRetriesRejectedPriorityWithSameModelAndContext() async throws {
        PriorityFallbackProtocol.payloads = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PriorityFallbackProtocol.self]
        let provider = OpenAICompatibleProvider(configuration: configuration)
        let config = ProviderConfig(baseURL: "https://api.openai.com/v1", apiKey: "synthetic", model: "gpt-5", responseMode: .deep)
        var answer = ""
        for try await chunk in provider.stream(messages: [["role": "user", "content": "fixture question"]], config: config) {
            answer += chunk
        }
        XCTAssertEqual(answer, "fixture answer")
        let requests = PriorityFallbackProtocol.payloads
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?["service_tier"] as? String, "priority")
        XCTAssertNil(requests.last?["service_tier"])
        for body in requests {
            XCTAssertEqual(body["model"] as? String, "gpt-5")
            XCTAssertEqual(body["reasoning_effort"] as? String, "high")
            XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "fixture question")
        }
    }
}


extension ResponseModeTests {
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
}


extension ResponseModeTests {
    @MainActor
    func testNarrowComposerFitsWithVoiceAndModeControls() throws {
        let model = AssistantModel.shared
        let collapsed = model.isCollapsed
        let enabled = ListeningModel.shared.isEnabled
        model.setCollapsedSilently(true)
        ListeningModel.shared.isEnabled = true
        defer {
            model.setCollapsedSilently(collapsed)
            ListeningModel.shared.isEnabled = enabled
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
}

extension ResponseModeTests {
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

    func testHighThinkingSiblingOnlyNamesListedModels() {
        let presets = ["gemini-3.6-flash-low", "gemini-3.6-flash-medium", "gemini-3.6-flash-high",
                       "gemini-3.1-pro-low", "gemini-3.1-pro-high", "gpt-oss-120b-medium", "claude-sonnet-4-6"]
            .map { ModelCatalog.Preset(slug: $0, title: $0, note: "") }
        XCTAssertEqual(ModelCatalog.highThinkingSibling(of: "gemini-3.6-flash-low", in: presets), "gemini-3.6-flash-high")
        XCTAssertEqual(ModelCatalog.highThinkingSibling(of: "gemini-3.6-flash-medium", in: presets), "gemini-3.6-flash-high")
        XCTAssertEqual(ModelCatalog.highThinkingSibling(of: "gemini-3.1-pro-low", in: presets), "gemini-3.1-pro-high")
        XCTAssertEqual(ModelCatalog.highThinkingSibling(of: "gemini-3.6-flash-high", in: presets), "gemini-3.6-flash-high")
        XCTAssertNil(ModelCatalog.highThinkingSibling(of: "gpt-oss-120b-medium", in: presets))
        XCTAssertNil(ModelCatalog.highThinkingSibling(of: "claude-sonnet-4-6", in: presets))
        XCTAssertNil(ModelCatalog.highThinkingSibling(of: "", in: presets))
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
}

extension ResponseModeTests {
    /// Deep re-answer is offered only on answers Quick wrote, so the mode has to survive saving;
    /// history written before the field existed still loads.
    func testAnswerModeRoundTripsAndOldHistoryStillLoads() throws {
        let old = try JSONDecoder().decode(Message.self, from: Data(#"{"role":"assistant","text":"Old answer"}"#.utf8))
        XCTAssertNil(old.mode)
        let quick = Message(role: .assistant, text: "Quick answer", mode: .quick)
        let decoded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(quick))
        XCTAssertEqual(decoded.mode, .quick)
        let unknown = try JSONDecoder().decode(Message.self, from: Data(#"{"role":"assistant","text":"x","mode":"future"}"#.utf8))
        XCTAssertNil(unknown.mode, "a mode from a newer build must not drop the message")
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
        let listening = ListeningModel.shared
        let lines = [
            "connection: \(models.baseline.kind.rawValue) · \(models.connectionTitle)",
            "default model: \(models.baseline.model)",
            "quick choice: '\(models.choice(for: .quick))' → sends \(models.config(for: .quick).model)",
            "deep choice: '\(models.choice(for: .deep))' → sends \(models.config(for: .deep).model)",
            "deep label: \(models.defaultChoiceTitle(for: .deep))",
            "response mode: \(AppSettings.shared.responseMode.rawValue)",
            "voice enabled: \(listening.isEnabled), engine: \(listening.engine.rawValue), language: \(listening.localLanguage), script: \(listening.chineseScript.rawValue)",
            "commands: \(QuickCommandStore.shared.commands.map { "\($0.title)[\($0.mode?.rawValue ?? "current")]" }.joined(separator: ", "))",
        ]
        try lines.joined(separator: "\n").write(to: URL(fileURLWithPath: "/private/tmp/wisp-current-settings.txt"), atomically: true, encoding: .utf8)
    }
}
