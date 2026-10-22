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
    private let deferReady: ((@escaping (SPUUserUpdateChoice) -> Void) -> Bool)?
    private let deferCandidate: ((SUAppcastItem, SPUUserUpdateState, @escaping (SPUUserUpdateChoice) -> Void) -> Bool)?
    private let observedCandidate: (SUAppcastItem) -> Void
    private let mayInstall: () -> Bool
    private var pendingCandidate: (id: UUID, prepare: () -> Bool, presented: Bool)?

    init(hostBundle: Bundle, delegate: SPUStandardUserDriverDelegate?,
         accepts: @escaping (String?) -> Bool, rejected: @escaping () -> Void,
         preparingInstallation: @escaping () -> Void = {},
         deferReady: ((@escaping (SPUUserUpdateChoice) -> Void) -> Bool)? = nil,
         deferCandidate: ((SUAppcastItem, SPUUserUpdateState, @escaping (SPUUserUpdateChoice) -> Void) -> Bool)? = nil,
         observedCandidate: @escaping (SUAppcastItem) -> Void = { _ in },
         mayInstall: @escaping () -> Bool = { true }) {
        self.accepts = accepts; self.rejected = rejected
        self.preparingInstallation = preparingInstallation
        self.deferReady = deferReady; self.deferCandidate = deferCandidate
        self.observedCandidate = observedCandidate; self.mayInstall = mayInstall
        super.init(hostBundle: hostBundle, delegate: delegate)
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard accepts(appcastItem.channel) else {
            // Skip also clears downloaded candidates or cancels their pending installer.
            // Dismiss would leave an installer that can run after the app quits.
            pendingCandidate = nil
            rejected(); reply(.skip)
            return
        }
        observedCandidate(appcastItem)
        if state.stage == .installing { preparingInstallation() }
        let id = UUID()
        var replied = false, reserved = false
        let finish: (SPUUserUpdateChoice) -> Void = { [weak self] choice in
            guard !replied else { return }
            replied = true
            if self?.pendingCandidate?.id == id { self?.pendingCandidate = nil }
            // A resumed installer bypasses showReady. It needs the same fresh
            // installation check when the eventual user/reservation reply arrives.
            reply(Self.foundUpdateChoice(choice, stage: state.stage,
                installationAllowed: state.stage != .installing || self?.mayInstall() == true))
        }
        let prepare: () -> Bool = { [weak self] in
            reserved = true
            if self?.deferCandidate?(appcastItem, state, finish) == true { return true }
            reserved = false
            return false
        }
        pendingCandidate = (id, prepare, false)
        if prepareDeferredCandidate() { return }
        pendingCandidate?.presented = true
        super.showUpdateFound(with: appcastItem, state: state) { choice in
            // A standard window may have existed before the reservation was
            // chosen. Once handed over, only its retained reservation reply owns it.
            if !reserved { finish(choice) }
        }
    }

    /// Reuse an already selected candidate without creating Sparkle's automatic
    /// install-on-quit driver or sending a second answer from its old window.
    @discardableResult
    func prepareDeferredCandidate() -> Bool {
        guard let pending = pendingCandidate, pending.prepare() else { return false }
        if pendingCandidate?.id == pending.id { pendingCandidate = nil }
        if pending.presented { super.dismissUpdateInstallation() }
        return true
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        var replied = false
        let checkedReply: (SPUUserUpdateChoice) -> Void = { [weak self] choice in
            guard !replied else { return }
            replied = true
            reply(Self.readyInstallationChoice(choice, installationAllowed: self?.mayInstall() == true))
        }
        if deferReady?(checkedReply) == true { return }
        super.showReady(toInstallAndRelaunch: checkedReply)
    }

    override func dismissUpdateInstallation() {
        pendingCandidate = nil
        super.dismissUpdateInstallation()
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
