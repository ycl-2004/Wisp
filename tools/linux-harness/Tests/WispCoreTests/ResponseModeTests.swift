// Ported from WispTests/ResponseModeTests.swift for the Linux harness.
// Kept: the 12 tests whose subjects are in the Foundation-only closure.
// Dropped (still run on macOS CI): testCollapsedPanelHeightTracksMultilineComposerWithoutExtraDefaultSpace — PanelController/ChatInput (AppKit); testScreenshotOnlyDeepRetryRequiresMatchingWindowTitle — AssistantModel (SwiftUI file); testCameraOffQuickSkipsCaptureAndPreservesChatHistory — AssistantModel (SwiftUI file); testModesAndOverridesRemainEditableWhileStreamingAndRender — AssistantModel + SwiftUI render; testNarrowComposerFitsWithVoiceAndModeControls — SwiftUI render; testQuickUsesTheDefaultModelAndDeepItsHighThinkingLevel — ActiveModels/ModelMenuState (SwiftUI file); testModelSettingsPageRenders — SwiftUI render; testReanswerRereadsOnlyTheSamePage — AssistantModel (SwiftUI file); testReportCurrentSettings — ActiveModels/ListeningModel (UI files); writes a report file.
// AppKit/SwiftUI imports dropped with the render tests. Everything kept is verbatim.
import XCTest
@testable import WispCore

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

    func testQuickOmitsHistoricalPageTextAndKeepsImageAndConversation() throws {
        var packet = ContextPacket(appName: "Browser", bundleID: "test.browser")
        packet.pageText = String(repeating: "PAGE_BODY_SENTINEL ", count: 6000)
        packet.pageTextTotalChars = packet.pageText?.count
        let image = try XCTUnwrap(ScreenCapturer.tinyTestJPEG())
        let messages = [
            Message(role: .user, text: "Previous question", context: packet.snapshot()),
            Message(role: .assistant, text: "Previous answer"),
            Message(role: .user, text: "What is visible now?", context: packet.snapshot())
        ]
        let quick = PromptBuilder.build(messages: messages, liveScreenshot: image, mode: .quick, skippedPageCapture: true)
        let deep = PromptBuilder.build(messages: messages, liveScreenshot: image, mode: .deep)
        let quickData = try JSONSerialization.data(withJSONObject: quick)
        let deepData = try JSONSerialization.data(withJSONObject: deep)
        let quickText = String(decoding: quickData, as: UTF8.self)
        XCTAssertFalse(quickText.contains("PAGE_BODY_SENTINEL"))
        XCTAssertTrue(quickText.contains("Previous answer"))
        XCTAssertTrue(quickText.contains("What is visible now?"))
        let blocks = try XCTUnwrap(quick.last?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.filter { $0["type"] as? String == "image_url" }.count, 1)
        XCTAssertLessThan(quickData.count, deepData.count)

        // Same history/image, only page-context policy differs. This measures local
        // payload preparation, not capture latency or provider time to first token.
        for mode in [ResponseMode.quick, .deep] {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<100 {
                _ = try JSONSerialization.data(withJSONObject: PromptBuilder.build(
                    messages: messages, liveScreenshot: image, mode: mode))
            }
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 10
            print("QUICK_BENCH \(mode.rawValue): \(mode == .quick ? quickData.count : deepData.count) bytes, \(milliseconds) ms/request")
        }
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

}


extension ResponseModeTests {

}

extension ResponseModeTests {
    /// Sending, Test Connection, the header menu and Settings all read one `ActiveModels`: Quick
    /// sends the default model itself, Deep following the default takes its High thinking level
    /// on Antigravity, an explicit per-mode choice always wins, and each connection keeps its own.


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


    /// Read-only: what this Mac's saved settings resolve to after the change.

}
