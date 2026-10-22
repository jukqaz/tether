import Foundation
import TetherCore

@MainActor
extension AppModel {
    var automaticPauseActive: Bool { userSessionStatus?.automaticPauseActive == true }
    var automaticPauseUntil: Date? { automaticPauseActive ? userSessionStatus?.automaticPauseUntil : nil }

    @discardableResult
    func pauseAutomatic(for duration: TimeInterval?) -> Bool {
        guard acceptingUserCommands, !commandPending, let userSession else { return false }
        return userSession.pauseAutomatic(for: duration)
    }

    @discardableResult
    func resumeAutomatic() -> Bool {
        guard acceptingUserCommands, !commandPending, !v4AcquisitionBlocked, let userSession else { return false }
        let accepted = userSession.resumeAutomatic()
        if accepted && userSession.status.automaticActive { acceptedUserWorkIntent() }
        return accepted
    }
}
