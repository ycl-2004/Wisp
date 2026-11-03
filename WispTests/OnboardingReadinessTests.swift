import XCTest
@testable import Wisp

/// Issue #8: the onboarding entry condition is derived from live state,
/// never stored. These tests pin the full signal matrix and the
/// panel-open offer policy (the annoyance budget).
final class OnboardingReadinessTests: XCTestCase {

    private func signals(cloudKey: Bool = false, baseURLEmpty: Bool = false,
                         ollama: Bool = false, cli: Bool = false) -> OnboardingSignals {
        OnboardingSignals(hasCloudKey: cloudKey, cloudBaseURLIsEmpty: baseURLEmpty,
                          ollamaRunning: ollama, anyCLIInstalled: cli)
    }

    func testNothingConfiguredNeedsSetup() {
        XCTAssertTrue(OnboardingReadiness.needsSetup(signals()))
    }

    func testCloudKeyWithBaseURLIsReady() {
        XCTAssertFalse(OnboardingReadiness.needsSetup(signals(cloudKey: true)))
    }

    func testCloudKeyWithoutBaseURLIsNotReady() {
        // A saved key aimed at an empty custom base URL answers nothing.
        XCTAssertTrue(OnboardingReadiness.needsSetup(signals(cloudKey: true, baseURLEmpty: true)))
    }

    func testRunningOllamaAloneIsReady() {
        XCTAssertFalse(OnboardingReadiness.needsSetup(signals(ollama: true)))
    }

    func testAnyInstalledCLIAloneIsReady() {
        XCTAssertFalse(OnboardingReadiness.needsSetup(signals(cli: true)))
    }

    func testEmptyBaseURLDoesNotPoisonOtherPaths() {
        XCTAssertFalse(OnboardingReadiness.needsSetup(
            signals(cloudKey: true, baseURLEmpty: true, ollama: true)))
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
