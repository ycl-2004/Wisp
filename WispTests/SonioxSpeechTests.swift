import XCTest
@testable import Wisp

/// The Soniox message mapping, against the documented response shapes. No network.
/// https://docs.soniox.com/api-reference/stt/websocket-api
final class SonioxSpeechTests: XCTestCase {
    func testMissingKeyFailsBeforeStartingCloudRecognition() async throws {
        do {
            let speech = try await SonioxSpeech.start(apiKey: nil, locale: "zh-CN",
                                                      onUpdate: { _ in }, onFailure: { _ in })
            speech.cancel()
            XCTFail("A missing key should fail before starting the WebSocket")
        } catch let failure as ListeningFailure {
            XCTAssertEqual(failure.message, String(localized: "云端识别需要 Soniox API Key，请在设置 → 音频中填写。"))
        }
    }

    /// A server that accepts the connection and never answers the upgrade must not leave
    /// captions waiting forever. Loopback only: the listener never replies.
    func testHandshakeThatNeverCompletesTimesOut() async throws {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, length) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 4), 0)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(listener, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let endpoint = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/transcribe-websocket"))

        let started = Date()
        do {
            let speech = try await SonioxSpeech.start(apiKey: "fixture", locale: "en-US", endpoint: endpoint,
                                                      handshakeTimeout: 0.5,
                                                      onUpdate: { _ in }, onFailure: { _ in })
            speech.cancel()
            XCTFail("A handshake that never completes should fail")
        } catch let failure as ListeningFailure {
            XCTAssertEqual(failure.message, String(localized: "连接 Soniox 超时，请检查网络后重试。"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testConfigurationAsksForRawPCMAndTheMeetingLanguagePlusEnglish() throws {
        let config = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(SonioxSpeech.configuration(locale: "zh-CN").utf8)) as? [String: Any])
        XCTAssertEqual(config["model"] as? String, SonioxSpeech.model)
        XCTAssertEqual(config["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(config["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(config["num_channels"] as? Int, 1)
        XCTAssertEqual(config["language_hints"] as? [String], ["zh", "en"])
        XCTAssertNil(config["api_key"], "the key goes in the Authorization header, not the message")
        let english = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(SonioxSpeech.configuration(locale: "en-US").utf8)) as? [String: Any])
        XCTAssertEqual(english["language_hints"] as? [String], ["en"])
        XCTAssertEqual(SonioxSpeech.format.sampleRate, 16_000)
        XCTAssertEqual(SonioxSpeech.format.commonFormat, .pcmFormatInt16)
    }

    func testFinalTokensCommitAndTheNonFinalTailIsTheGuess() {
        let message = #"""
        {"tokens":[
          {"text":"RAG","start_ms":1200,"end_ms":1500,"is_final":true},
          {"text":" 是","start_ms":1500,"end_ms":1700,"is_final":true},
          {"text":"什","start_ms":1700,"end_ms":1800,"is_final":false},
          {"text":"么","start_ms":1800,"end_ms":1900,"is_final":false}],
         "final_audio_proc_ms":1700,"total_audio_proc_ms":1900}
        """#
        XCTAssertEqual(SonioxSpeech.parse(message), .updates([
            .committed([CaptionPiece(text: "RAG", start: 1.2, end: 1.5), CaptionPiece(text: " 是", start: 1.5, end: 1.7)]),
            .volatile(CaptionPiece(text: "什么", start: 1.7, end: 1.9)),
        ]))
        var buffer = CaptionBuffer()
        if case .updates(let updates)? = SonioxSpeech.parse(message) { updates.forEach { buffer.apply($0) } }
        XCTAssertEqual(buffer.text, "RAG 是什么")
    }

    /// A response with no non-final tokens means nothing is pending; endpoint markers are not speech.
    func testEndpointMarkersAreDroppedAndAnEmptyTailClearsTheGuess() {
        let message = #"{"tokens":[{"text":"吗？","start_ms":1900,"end_ms":2100,"is_final":true},{"text":"<end>","is_final":true}]}"#
        XCTAssertEqual(SonioxSpeech.parse(message), .updates([
            .committed([CaptionPiece(text: "吗？", start: 1.9, end: 2.1)]), .volatile(nil),
        ]))
        XCTAssertEqual(SonioxSpeech.parse(#"{"tokens":[]}"#), .updates([.volatile(nil)]))
    }

    func testFinishedAndErrorResponses() {
        XCTAssertEqual(SonioxSpeech.parse(#"{"tokens":[],"finished":true}"#), .finished)
        guard case .failure(let text)? = SonioxSpeech.parse(
            #"{"error_code":401,"error_type":"unauthenticated","error_message":"Invalid API key."}"#) else {
            return XCTFail("an error response must stop the captions")
        }
        XCTAssertTrue(text.contains("401") && text.contains("Invalid API key."), text)
        XCTAssertNil(SonioxSpeech.parse("not json"))
    }
}
