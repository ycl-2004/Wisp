import XCTest
@testable import Wisp

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
