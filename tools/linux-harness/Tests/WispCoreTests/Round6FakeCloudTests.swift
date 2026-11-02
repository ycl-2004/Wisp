import XCTest
@testable import WispCore

/// Audit round 6, part A.1: the REAL `OpenAICompatibleProvider` driven
/// end-to-end against a scripted in-process endpoint (URLProtocol — the
/// seam the harness already uses, e.g. ResponseModeTests). No external
/// services, no keys: the provider's request construction, status/error
/// mapping, SSE assembly, and the round 2/4/5 caps (#10 line + error
/// body, #52 cumulative) are all exercised through its public stream API.
///
/// Fidelity notes (also in AUDIT-ROUND5.md): on Linux the provider
/// reads through the harness's whole-response `bytes(for:)` shim, so
/// bytes arrive buffered rather than incrementally. Everything except
/// *timing* (time-to-first-token, mid-stream partial delivery before a
/// disconnect) is proven here; those two are macOS-only by
/// construction. Separately, swift-corelibs' URLProtocol delivers only
/// the LAST didLoad chunk (measured: 3 chunks of 7+15+4 bytes arrived
/// as 4), so the stub sends each scripted body as one didLoad —
/// transport-split invariance is already covered at the pipeline level
/// by SSEFuzzTests.
private final class Round6StubProtocol: URLProtocol {
    struct Script {
        var status: Int = 200
        var chunks: [Data] = []
        var failure: Error?
    }

    static var script = Script()
    static var requestBodies: [[String: Any]] = []

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
        if let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            Self.requestBodies.append(body)
        }
        let script = Self.script
        let response = HTTPURLResponse(url: request.url!, statusCode: script.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // One didLoad for the whole body: corelibs drops all but the
        // last chunk (see the class doc).
        let body = script.chunks.reduce(Data()) { $0 + $1 }
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        if let failure = script.failure {
            client?.urlProtocol(self, didFailWithError: failure)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class Round6FakeCloudTests: XCTestCase {

    private func provider() -> OpenAICompatibleProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Round6StubProtocol.self]
        return OpenAICompatibleProvider(configuration: configuration)
    }

    private func config() -> ProviderConfig {
        ProviderConfig(baseURL: "https://fake.invalid/v1", apiKey: "round6-key", model: "fake-model")
    }

    private func collect(_ provider: OpenAICompatibleProvider,
                         _ config: ProviderConfig) async -> (chunks: [String], error: Error?) {
        var chunks: [String] = []
        do {
            for try await chunk in provider.stream(messages: [["role": "user", "content": "q"]],
                                                   config: config) {
                chunks.append(chunk)
            }
            return (chunks, nil)
        } catch {
            return (chunks, error)
        }
    }

    private func sse(_ content: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\(jsonString(content))}}]}\n\n"
    }

    private func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast()) // strip the [ ]
    }

    // MARK: - Happy path

    func testNormalSSEAssemblesDeltasInOrderAndStopsAtDone() async {
        // A delta AFTER [DONE] must never reach the user. (Byte-level
        // transport splits are covered by SSEFuzzTests; corelibs
        // URLProtocol cannot deliver them — see the class doc.)
        let body = sse("Hello, ") + sse("wisp") + sse("!") + "data: [DONE]\n\n" + sse("LATE")
        Round6StubProtocol.script = .init(chunks: [Data(body.utf8)])
        Round6StubProtocol.requestBodies = []
        let (chunks, error) = await collect(provider(), config())
        XCTAssertNil(error)
        XCTAssertEqual(chunks, ["Hello, ", "wisp", "!"])
        // The request the provider actually built:
        let sent = Round6StubProtocol.requestBodies.first
        XCTAssertEqual(sent?["model"] as? String, "fake-model")
        XCTAssertEqual(sent?["stream"] as? Bool, true)
        XCTAssertNotNil(sent?["messages"])
    }

    func testMalformedLinesMidStreamAreSkipped() async {
        // Unparseable lines are dropped. An in-stream {"error": ...}
        // object is NOT dropped, by design: the parser surfaces it as a
        // visible note inside the answer (the gateway is telling the
        // user something; silently swallowing it would fake success).
        let body = sse("A")
            + "data: {not json at all\n\n"
            + "data: {\"error\":{\"message\":\"in-stream noise\"}}\n\n"
            + "garbage line without prefix\n\n"
            + sse("B") + "data: [DONE]\n\n"
        Round6StubProtocol.script = .init(chunks: [Data(body.utf8)])
        let (chunks, error) = await collect(provider(), config())
        XCTAssertNil(error)
        XCTAssertEqual(chunks, ["A", "\n\n[服务端错误] in-stream noise", "B"])
    }

    // MARK: - Error mapping

    func testNon2xxJSONErrorBodyMapsServerMessage() async {
        Round6StubProtocol.script = .init(
            status: 400,
            chunks: [Data(#"{"error":{"message":"model fake-model does not exist"}}"#.utf8)])
        let (_, error) = await collect(provider(), config())
        guard case ProviderError.http(let code, let message)? = error as? ProviderError else {
            return XCTFail("expected .http, got \(String(describing: error))")
        }
        XCTAssertEqual(code, 400)
        XCTAssertTrue(message.contains("does not exist"), message)
    }

    func testErrorBodyIsCappedAt64KiBAndMappedFromTheHead() async {
        // The stream path caps the error body with CappedDataBuffer
        // (#10): only the first 64 KiB is kept, and mapError works from
        // the head — where the error JSON lives. A 400 with a 200 KiB
        // body (JSON head + junk tail) still maps precisely, and a 401
        // still maps to .unauthorized; memory stays bounded either way.
        var body = Data(#"{"error":{"message":"head message survives"}}"#.utf8)
        body.append(Data(repeating: 0x61, count: 200_000))
        Round6StubProtocol.script = .init(status: 400, chunks: [body])
        let (_, error400) = await collect(provider(), config())
        guard case ProviderError.http(let code, let message)? = error400 as? ProviderError else {
            return XCTFail("expected .http, got \(String(describing: error400))")
        }
        XCTAssertEqual(code, 400)
        XCTAssertTrue(message.contains("head message survives"), message)

        Round6StubProtocol.script = .init(status: 401, chunks: [body])
        let (_, error401) = await collect(provider(), config())
        guard case ProviderError.unauthorized? = error401 as? ProviderError else {
            return XCTFail("expected .unauthorized, got \(String(describing: error401))")
        }
    }

    func testAbruptDisconnectThrowsInsteadOfHangingOrFakingSuccess() async {
        Round6StubProtocol.script = .init(
            chunks: [Data(sse("partial").utf8)],
            failure: URLError(.networkConnectionLost))
        let (chunks, error) = await collect(provider(), config())
        XCTAssertNotNil(error)
        // Whole-response shim fidelity: on Linux no partial delta is
        // delivered before the failure (macOS bytes would deliver it).
        XCTAssertEqual(chunks, [])
    }

    // MARK: - Hostile streams (#10 line cap, #52 cumulative cap)

    func testSingleLineOverOneMiBTripsLineCap() async {
        let content = String(repeating: "x", count: 1_100_000)
        Round6StubProtocol.script = .init(chunks: [Data(sse(content).utf8)])
        let (_, error) = await collect(provider(), config())
        guard case ProviderError.network(let message)? = error as? ProviderError else {
            return XCTFail("expected .network from the line cap, got \(String(describing: error))")
        }
        XCTAssertTrue(message.contains("单行数据过长"), message)
    }

    func testEndlessStreamIsTerminatedByCumulativeCap() async {
        // ~36 MB of perfectly valid small SSE lines and NO [DONE]: only
        // the #52 cumulative cap can end this. The assembled text must
        // stop at the cap, not at the end of the body.
        let line = sse(String(repeating: "y", count: 4096))
        let lineCount = 8_800 // ≈ 36 MB on the wire
        var chunks: [Data] = []
        var batch = ""
        for index in 0..<lineCount {
            batch += line
            if index % 200 == 199 { chunks.append(Data(batch.utf8)); batch = "" }
        }
        if !batch.isEmpty { chunks.append(Data(batch.utf8)) }
        Round6StubProtocol.script = .init(chunks: chunks)
        let (received, error) = await collect(provider(), config())
        guard case ProviderError.network(let message)? = error as? ProviderError else {
            return XCTFail("expected .network from the cumulative cap, got \(String(describing: error))")
        }
        XCTAssertTrue(message.contains("数据总量过大"), message)
        let assembled = received.joined().count
        XCTAssertLessThanOrEqual(assembled, StreamByteBudget.maxTotalBytes,
                                 "assembly must stop at the cap, got \(assembled)")
        XCTAssertLessThan(assembled, lineCount * 4096,
                          "the cap, not the end of the body, terminated the stream")
    }

    // MARK: - Soak (smoke-level stability, not a leak profile)

    func testSoak200SequentialRequestsAllComplete() async {
        Round6StubProtocol.script = .init(chunks: [Data((sse("ok") + "data: [DONE]\n\n").utf8)])
        let provider = provider()
        let config = config()
        let started = Date()
        for iteration in 0..<200 {
            let (chunks, error) = await collect(provider, config)
            XCTAssertNil(error, "iteration \(iteration)")
            XCTAssertEqual(chunks, ["ok"], "iteration \(iteration)")
            if error != nil { return }
        }
        let elapsed = Date().timeIntervalSince(started)
        print("Round6 soak: 200 requests in \(String(format: "%.2f", elapsed))s")
        XCTAssertLessThan(elapsed, 120, "soak must stay comfortably bounded")
    }
}
