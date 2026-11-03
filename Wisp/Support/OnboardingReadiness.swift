import Foundation

/// First-run onboarding's view of the machine, gathered by the caller
/// from the selected connection. Plain data on purpose: the decision is
/// pure and testable, the gathering is not (issue #8 — derive the entry
/// condition, never store a flag for it).
struct OnboardingSignals: Equatable {
    /// The connection a question would go to right now (Settings' provider kind).
    enum Connection: Equatable { case cloud, ollama, cli }

    var selected: Connection = .cloud
    /// A key is saved in the Keychain for the selected cloud provider.
    var hasCloudKey = false
    /// The effective cloud base URL is empty (only possible for a custom
    /// provider left blank, but the check is what Settings itself needs).
    var cloudBaseURLIsEmpty = false
    /// Ollama answered a probe on its configured base URL.
    var ollamaRunning = false
    /// The selected agent CLI resolves to an executable — the configured
    /// path first, then the default install locations, the same lookup the
    /// provider itself runs.
    var selectedCLIFound = false
}

enum OnboardingReadiness {
    /// The sheet exists for exactly this state: the question the user is
    /// about to ask would fail on the selected connection. Another path
    /// that happens to work (an installed CLI while the cloud is selected
    /// without a key) does not count — the question would still end in the
    /// bare missing-key error the sheet replaces.
    static func needsSetup(_ signals: OnboardingSignals) -> Bool {
        switch signals.selected {
        case .cloud:  return !signals.hasCloudKey || signals.cloudBaseURLIsEmpty
        case .ollama: return !signals.ollamaRunning
        case .cli:    return !signals.selectedCLIFound
        }
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
