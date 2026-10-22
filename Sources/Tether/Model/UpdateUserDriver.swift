import AppKit
import Sparkle
import TetherCore

/// Retains Sparkle's standard UI, but rechecks resumed candidates at the user-driver boundary.
/// Sparkle 2.10 intentionally skips shouldProceedWithUpdate when resuming a cached update.
@MainActor
final class UpdateUserDriver: SPUStandardUserDriver {
    private let accepts: (String?) -> Bool
    private let rejected: () -> Void
    private let preparingInstallation: () -> Void
    private let observedCandidate: (SUAppcastItem) -> Void
    private let mayInstall: () -> Bool

    init(hostBundle: Bundle, delegate: SPUStandardUserDriverDelegate?,
         accepts: @escaping (String?) -> Bool, rejected: @escaping () -> Void,
         preparingInstallation: @escaping () -> Void = {},
         observedCandidate: @escaping (SUAppcastItem) -> Void = { _ in },
         mayInstall: @escaping () -> Bool = { true }) {
        self.accepts = accepts; self.rejected = rejected
        self.preparingInstallation = preparingInstallation
        self.observedCandidate = observedCandidate; self.mayInstall = mayInstall
        super.init(hostBundle: hostBundle, delegate: delegate)
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard accepts(appcastItem.channel) else {
            // Skip also clears downloaded candidates or cancels their pending installer.
            // Dismiss would leave an installer that can run after the app quits.
            rejected(); reply(.skip)
            return
        }
        observedCandidate(appcastItem)
        if state.stage == .installing { preparingInstallation() }
        super.showUpdateFound(with: appcastItem, state: state,
            reply: Self.checkedInstallationReply(stage: state.stage,
                installationAllowed: { [weak self] in self?.mayInstall() == true }, reply: reply))
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        super.showReady(toInstallAndRelaunch: Self.checkedInstallationReply(stage: .installing,
            installationAllowed: { [weak self] in self?.mayInstall() == true }, reply: reply))
    }

    /// Only Sparkle's explicit user reply can proceed; there is no retained work-end reservation.
    /// Recheck safety at reply time, and never answer the framework callback twice.
    static func checkedInstallationReply(stage: SPUUserUpdateStage,
        installationAllowed: @escaping () -> Bool,
        reply: @escaping (SPUUserUpdateChoice) -> Void) -> (SPUUserUpdateChoice) -> Void {
        var replied = false
        return { choice in
            guard !replied else { return }
            replied = true
            reply(foundUpdateChoice(choice, stage: stage, installationAllowed: installationAllowed()))
        }
    }

    static func explicitInstallationChoice(_ choice: SPUUserUpdateChoice) -> SPUUserUpdateChoice {
        choice == .dismiss ? .skip : choice
    }
    static func readyInstallationChoice(_ choice: SPUUserUpdateChoice,
                                        installationAllowed: Bool) -> SPUUserUpdateChoice {
        choice == .install && !installationAllowed ? .skip : explicitInstallationChoice(choice)
    }
    static func foundUpdateChoice(_ choice: SPUUserUpdateChoice, stage: SPUUserUpdateStage,
                                  installationAllowed: Bool = true) -> SPUUserUpdateChoice {
        stage == .installing ? readyInstallationChoice(choice, installationAllowed: installationAllowed) : choice
    }
}
