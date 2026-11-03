import XCTest
@testable import WispCore

/// Audit round 6, part B: the app's compiled provider code against a
/// REAL local Ollama server (no doubles): the probe reads the server's
/// real /v1/models, and the OpenAI-compatible provider streams a real
/// answer from a real (small, CPU) model through Ollama's /v1 SSE
/// dialect — the exact configurable-base-URL path a user hits when
/// they point Wisp at a local server.
///
/// Gated on the OLLAMA_E2E environment variable so the default suite
/// stays hermetic: without a server these tests skip (named in the
/// run output); the round record carries the env-enabled run's real
/// results plus separately measured cold-load / TTFT / tokens-per-sec
/// numbers. Model + base URL default to the round-6 setup and can be
/// overridden via OLLAMA_E2E_MODEL / OLLAMA_E2E_BASE.
final class Round6RealOllamaTests: XCTestCase {

    private var baseURL: String {
        ProcessInfo.processInfo.environment["OLLAMA_E2E_BASE"] ?? "http://127.0.0.1:11434/v1"
    }

    private var model: String {
        ProcessInfo.processInfo.environment["OLLAMA_E2E_MODEL"] ?? "qwen2.5:0.5b"
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OLLAMA_E2E"] != nil,
                          "OLLAMA_E2E not set — real-server leg is opt-in (see AUDIT-ROUND5.md)")
    }

    func testProbeAgainstRealOllamaListsPulledModel() async {
        let status = await OllamaSupport.probe(baseURL: baseURL)
        guard case .running(let models) = status else {
            return XCTFail("expected .running from the real server, got \(status)")
        }
        XCTAssertTrue(models.contains(model),
                      "pulled model \(model) must be listed, got \(models)")
    }

    func testCloudProviderStreamsRealAnswerFromOllama() async throws {
        let provider = OpenAICompatibleProvider()
        let config = ProviderConfig(baseURL: baseURL, apiKey: "ollama-placeholder", model: model)
        var chunks: [String] = []
        for try await chunk in provider.stream(
            messages: [["role": "user", "content": "Reply with exactly one word: pong"]],
            config: config) {
            chunks.append(chunk)
        }
        let answer = chunks.joined()
        print("Round6 real Ollama answer (\(chunks.count) deltas): \(answer)")
        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "a real streamed answer must assemble to non-empty text")
    }

    func testValidateAgainstRealOllama() async throws {
        // validate() sends a tiny image-bearing request on purpose — it
        // is the app's vision-support check. Against this text-only
        // model the correct outcome is .imageUnsupported carrying the
        // server's own explanation (Ollama's wording hits the mapper's
        // image hints exactly); against a vision model it would succeed.
        // Anything else (a transport error, a mis-mapped .http) fails.
        let provider = OpenAICompatibleProvider()
        let config = ProviderConfig(baseURL: baseURL, apiKey: "ollama-placeholder", model: model)
        do {
            try await provider.validate(config: config)
            print("Round6 real Ollama validate: accepted (vision-capable model)")
        } catch let error as ProviderError {
            guard case .imageUnsupported(let detail) = error else {
                XCTFail("validate must succeed or map to .imageUnsupported, got \(error)")
                return
            }
            print("Round6 real Ollama validate: correctly mapped to .imageUnsupported — \(detail)")
        }
    }
}
