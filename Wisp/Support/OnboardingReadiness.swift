import Foundation

/// First-run onboarding's view of the machine, gathered by the caller
/// from KeychainStore / OllamaSupport / the CLI detectors. Plain data on
/// purpose: the decision is pure and testable, the gathering is not
/// (issue #8 — derive the entry condition, never store a flag for it).
struct OnboardingSignals: Equatable {
    /// A key is saved in the Keychain for the selected cloud provider.
    var hasCloudKey = false
    /// The effective cloud base URL is empty (only possible for a custom
    /// provider left blank, but the check is what Settings itself needs).
    var cloudBaseURLIsEmpty = false
    /// Ollama answered a probe on its configured base URL.
    var ollamaRunning = false
    /// At least one supported agent CLI (Claude Code / Codex / AGY) is
    /// installed on this Mac.
    var anyCLIInstalled = false
}

enum OnboardingReadiness {
    static func cloudReady(_ signals: OnboardingSignals) -> Bool {
        signals.hasCloudKey && !signals.cloudBaseURLIsEmpty
    }

    static func anyPathReady(_ signals: OnboardingSignals) -> Bool {
        cloudReady(signals) || signals.ollamaRunning || signals.anyCLIInstalled
    }

    /// The sheet exists for exactly this state: nothing the user could
    /// ask right now would succeed.
    static func needsSetup(_ signals: OnboardingSignals) -> Bool {
        !anyPathReady(signals)
    }

    /// The panel-open offer policy (the annoyance budget): at most once
    /// per launch, and never after the user skipped the sheet this
    /// launch. The failed-ask path is the only re-offer, and it does not
    /// go through here.
    static func shouldOfferOnPanelOpen(needsSetup: Bool,
                                       alreadyOfferedThisLaunch: Bool,
                                       dismissedThisLaunch: Bool) -> Bool {
        needsSetup && !alreadyOfferedThisLaunch && !dismissedThisLaunch
    }
}
