import Foundation
import TetherCore

/// Presentation commands all target the same user-owned session controller.
/// A helper is optional; these choices never write the root control file directly.
@MainActor
extension AppModel {
    var v3Settings: IdleSessionSettings { userSession?.settings ?? IdleSessionSettings() }
    var automaticEnabled: Bool { userSessionStatus?.automaticEnabled ?? false }
    /// macOS exposes no supported app API to change the login session's lock state.
    /// Keep the option unavailable rather than simulate keyboard input or change
    /// the system password policy. macOS's own lock settings remain authoritative.
    var canRequestLockOnClose: Bool { false }

    func setAutomaticEnabled(_ value: Bool) {
        guard acceptingUserCommands, !value || !v4AcquisitionBlocked, let controller = userSession else { return }
        controller.setAutomatic(value)
        if controller.status.automaticActive { acceptedUserWorkIntent() }
    }
    func setKeepDisplayAwake(_ value: Bool) {
        guard acceptingUserCommands, let controller = userSession else { return }
        controller.setKeepDisplayAwake(value)
    }
    func setAllowClosedLid(_ value: Bool) {
        guard acceptingUserCommands, capabilities.lidControlAvailable, let controller = userSession else { return }
        controller.setAllowClosedLid(value)
    }
    func setLockOnClose(_ value: Bool) {
        guard acceptingUserCommands, capabilities.lidControlAvailable, let controller = userSession else { return }
        guard !value || canRequestLockOnClose else { return }
        controller.setLockOnClose(value)
    }
    func setDisconnectAction(_ value: WorkSessionEndAction) {
        guard acceptingUserCommands, let controller = userSession else { return }
        controller.setDisconnectAction(value)
    }
    func selectManualDuration(_ duration: TimeInterval?) {
        guard acceptingUserCommands, let controller = userSession else { return }
        controller.selectManualDuration(duration)
    }
}
