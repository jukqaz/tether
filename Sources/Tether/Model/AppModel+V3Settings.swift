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
    func setDisconnectPolicy(_ value: WorkSessionDisconnectPolicy) {
        guard acceptingUserCommands, !commandPending else { return }
        _ = userSession?.setDisconnectPolicy(value)
    }
    func setManualPowerCondition(_ value: PowerCondition) {
        guard acceptingUserCommands, !commandPending else { return }
        _ = userSession?.setManualPowerCondition(value)
    }
    func setBatteryTimeLimit(_ value: WorkSessionBatteryLimit) {
        guard acceptingUserCommands, !commandPending else { return }
        _ = userSession?.setBatteryTimeLimit(value)
    }
    func setAutomaticallyResumeAfterProtection(_ value: Bool) {
        guard acceptingUserCommands, !commandPending else { return }
        _ = userSession?.setAutomaticallyResumeAfterProtection(value)
    }
    func setStopOnSeriousThermal(_ value: Bool) {
        guard acceptingUserCommands, !commandPending else { return }
        _ = userSession?.setStopOnSeriousThermal(value)
    }
    func setStartAutomaticOnBatteryDisconnect(_ value: Bool) {
        guard acceptingUserCommands, !commandPending else { return }
        _ = userSession?.setStartAutomaticOnBatteryDisconnect(value)
    }
    var disconnectPolicyDetail: String {
        switch v3Settings.disconnectPolicy {
        case .endAll:
            L("Unplugging ends all existing Tether work. Start new battery work separately.",
              "전원을 빼면 기존 Tether 유지를 모두 끝냅니다. 배터리 유지는 따로 시작하세요.")
        case .endAutomatic:
            L("Unplugging ends automatic work. Eligible manual work keeps its original deadline and battery limit.",
              "전원을 빼면 자동 유지를 끝냅니다. 배터리 사용이 허용된 수동 유지만 원래 기한·한도 안에서 계속합니다.")
        case .continueEligible:
            L("Only requests already allowed on battery continue. Their original deadlines and battery limits never reset.",
              "배터리 사용이 허용된 요청만 계속합니다. 원래 기한과 최초 배터리 한도는 초기화하지 않습니다.")
        }
    }
    func batteryLimitTitle(_ value: WorkSessionBatteryLimit) -> String {
        value.seconds.map { Texts.duration($0) } ?? L("Unlimited · protection stays on", "무제한 · 보호는 유지")
    }
    func selectManualDuration(_ duration: TimeInterval?) {
        guard acceptingUserCommands, let controller = userSession else { return }
        controller.selectManualDuration(duration)
    }
}
