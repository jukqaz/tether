import Foundation
import TetherCore

extension Helper {
    // Legacy fixtures remain compatible. Opt-in is read only on --dry-run; the real
    // root helper always requires native OS observations and kernel socket identity.
    var enforcesGUIAuthority: Bool { !dryRun || fake["guiAuthority"] as? Bool == true }
    var guiClock: Double { dryRun ? fake["guiClock"] as? Double ?? ContinuousTime.now : ContinuousTime.now }
    var guiConsoleUID: UInt32? {
        if dryRun, enforcesGUIAuthority {
            if fake["guiUnavailable"] as? Bool == true { return nil }
            return (fake["guiConsoleUID"] as? NSNumber)?.uint32Value
        }
        return SystemProbe.consoleUserID
    }
    var guiControlConfirmed: Bool {
        guard let owner = state.guiOwner,
              owner.matches(process: ProcessIdentity.capture(pid: owner.process.pid), boot: currentBootID),
              GUISessionProbe.graphical(owner.login) != nil, guiConsoleUID == owner.login.uid else { return false }
        return guiAuthority.canAcquire && state.controllerUID == owner.login.uid
    }
    @discardableResult
    func refreshGUIAuthority() -> Bool {
        guard enforcesGUIAuthority, let owner = state.guiOwner else { return false }
        let processValid = owner.matches(process: ProcessIdentity.capture(pid: owner.process.pid), boot: currentBootID)
        let login = processValid ? GUISessionProbe.graphical(owner.login) : nil
        guiAuthority.observe(GUISessionObservation(login: login, consoleUID: guiConsoleUID), now: guiClock)
        guard !processValid || !guiAuthority.canPreserveExisting(now: guiClock) else { return false }
        let reason = guiAuthority.status == .revoked ? "GUI user changed" : "GUI authority unavailable"
        _ = disconnectApp(reason: reason)
        if ownsOverride { _ = applyOverride(false) }
        return true
    }
    func guiRequestError(_ request: ServiceRequest, uid: UInt32) -> String? {
        guard enforcesGUIAuthority, request.action != .snapshot else { return nil }
        if uid == 0, [.stop, .endManualSession, .markDiagnostic].contains(request.action) { return nil }
        guard let login = request.authenticatedGUILogin, login.uid == uid, login.isValid else { return "guiSessionUnavailable" }
        if let approved = state.controllerUID ?? state.appUID, approved != uid { return "notOwner" }
        if [.attachApp, .prepareWorkSession, .attachWorkSession].contains(request.action) {
            guard guiConsoleUID == uid, GUISessionProbe.graphical(login) != nil else { return "guiSessionUnavailable" }
            if let owner = state.guiOwner, appProcessAlive,
               (owner.login != login || owner.process.pid != request.authenticatedPID) { return "notOwner" }
            return nil
        }
        guard state.guiOwner?.login == login else { return "notOwner" }
        if request.action == .syncWorkSession, state.appPID != request.authenticatedPID { return "notOwner" }
        // Same-owner cleanup remains possible during a brief observation gap.
        if [.detachApp, .stop, .endManualSession, .markDiagnostic].contains(request.action) { return nil }
        return guiControlConfirmed ? nil : "guiSessionUnavailable"
    }
}
