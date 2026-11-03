import XCTest
@testable import WispCore

/// UX overhaul item 4: the panel error row only offers a "Connect"
/// button for errors the onboarding wizard can actually fix. This pins
/// the classification on `ProviderError` so the button never appears
/// for rate limits, network blips, or model capability problems — and
/// never goes missing for the setup problems it exists for.
final class ProviderErrorConnectionTests: XCTestCase {

    func testSetupProblemsAreConnectionErrors() {
        let cases: [ProviderError] = [
            .missingKey,
            .unauthorized,
            .badBaseURL,
            .ollamaNotRunning,
            .codexNotFound,
            .agyNotFound,
            .claudeCodeNotFound,
            .claudeCodeSignedOut,
            .http(401, "unauthorized"),
            .http(403, "forbidden"),
        ]
        for error in cases {
            XCTAssertTrue(error.isConnectionSetupError, "\(error) should offer the connect path")
        }
    }

    // MARK: - mapError status routing

    /// 401 才是 Key 被拒：映射到 .unauthorized，错误行给「去连接」。
    func testMapErrorKeeps401AsUnauthorized() {
        let body = Data(#"{"error":{"message":"invalid api key"}}"#.utf8)
        let error = OpenAICompatibleProvider.mapError(status: 401, data: body)
        guard case .unauthorized = error else {
            return XCTFail("401 should map to .unauthorized, got \(error)")
        }
        XCTAssertTrue(error.isConnectionSetupError)
    }

    /// 403 不再折成 .unauthorized（它那句文案写死「(401)」）：余额、
    /// 政策、模型权限类 403 的真实原因在服务端原话里，走 .http 带
    /// 回来；分类仍算连接问题，「去连接」照样出现。
    func testMapErrorRoutes403ToHTTPWithServerMessage() {
        let body = Data(#"{"error":{"message":"insufficient balance"}}"#.utf8)
        let error = OpenAICompatibleProvider.mapError(status: 403, data: body)
        guard case .http(let code, let message) = error else {
            return XCTFail("403 should map to .http, got \(error)")
        }
        XCTAssertEqual(code, 403)
        XCTAssertTrue(message.contains("insufficient balance"), message)
        XCTAssertTrue(error.isConnectionSetupError)
    }

    func testTransientAndRuntimeProblemsAreNotConnectionErrors() {
        let cases: [ProviderError] = [
            .http(400, "bad request"),
            .http(404, "not found"),
            .http(429, "slow down"),
            .http(500, "server error"),
            .rateLimited(detail: "", upstream: false, resetHint: nil),
            .rateLimited(detail: "", upstream: true, resetHint: nil),
            .imageUnsupported("no vision"),
            .network("offline"),
            .offline,
            .timedOut(30),
            .cancelled,
            .codexFailed("boom", status: 1),
            .agyFailed("boom", status: 1),
            .claudeCodeFailed("boom", status: 1),
            .codexTimedOut(300),
            .agyTimedOut(300),
            .claudeCodeTimedOut(300),
        ]
        for error in cases {
            XCTAssertFalse(error.isConnectionSetupError, "\(error) should not offer the connect path")
        }
    }
}
