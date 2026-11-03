import XCTest
@testable import Wisp

/// Issue #8: the onboarding entry condition is derived from live state,
/// never stored, and only from the connection a question would go to.
/// These tests pin the signal matrix and the panel-open offer policy
/// (the annoyance budget).
final class OnboardingReadinessTests: XCTestCase {

    private func signals(_ selected: OnboardingSignals.Connection = .cloud,
                         cloudKey: Bool = false, baseURLEmpty: Bool = false,
                         ollama: Bool = false, cli: Bool = false) -> OnboardingSignals {
        OnboardingSignals(selected: selected, hasCloudKey: cloudKey, cloudBaseURLIsEmpty: baseURLEmpty,
                          ollamaRunning: ollama, selectedCLIFound: cli)
    }

    func testNothingConfiguredNeedsSetup() {
        XCTAssertTrue(OnboardingReadiness.needsSetup(signals()))
        XCTAssertTrue(OnboardingReadiness.needsSetup(signals(.ollama)))
        XCTAssertTrue(OnboardingReadiness.needsSetup(signals(.cli)))
    }

    func testCloudKeyWithBaseURLIsReady() {
        XCTAssertFalse(OnboardingReadiness.needsSetup(signals(cloudKey: true)))
    }

    func testCloudKeyWithoutBaseURLIsNotReady() {
        // A saved key aimed at an empty custom base URL answers nothing.
        XCTAssertTrue(OnboardingReadiness.needsSetup(signals(cloudKey: true, baseURLEmpty: true)))
    }

    func testRunningOllamaIsReadyWhenSelected() {
        XCTAssertFalse(OnboardingReadiness.needsSetup(signals(.ollama, ollama: true)))
    }

    func testFoundCLIIsReadyWhenSelected() {
        XCTAssertFalse(OnboardingReadiness.needsSetup(signals(.cli, cli: true)))
    }

    func testAPathThatIsNotSelectedDoesNotCount() {
        // The default connection is the cloud: a fresh user with Claude Code
        // installed but no key would still hit the missing-key error.
        XCTAssertTrue(OnboardingReadiness.needsSetup(signals(.cloud, ollama: true, cli: true)))
        // A configured CLI user is never blocked because no cloud key exists.
        XCTAssertFalse(OnboardingReadiness.needsSetup(signals(.cli, cli: true)))
        XCTAssertTrue(OnboardingReadiness.needsSetup(signals(.ollama, cloudKey: true, cli: true)))
    }

    func testOfferPolicyMatrix() {
        // Offered only when setup is needed, not yet offered, not dismissed.
        XCTAssertTrue(OnboardingReadiness.shouldOfferOnPanelOpen(
            needsSetup: true, alreadyOfferedThisLaunch: false, dismissedThisLaunch: false))
        XCTAssertFalse(OnboardingReadiness.shouldOfferOnPanelOpen(
            needsSetup: false, alreadyOfferedThisLaunch: false, dismissedThisLaunch: false))
        XCTAssertFalse(OnboardingReadiness.shouldOfferOnPanelOpen(
            needsSetup: true, alreadyOfferedThisLaunch: true, dismissedThisLaunch: false))
        XCTAssertFalse(OnboardingReadiness.shouldOfferOnPanelOpen(
            needsSetup: true, alreadyOfferedThisLaunch: false, dismissedThisLaunch: true))
        XCTAssertFalse(OnboardingReadiness.shouldOfferOnPanelOpen(
            needsSetup: true, alreadyOfferedThisLaunch: true, dismissedThisLaunch: true))
    }
}
