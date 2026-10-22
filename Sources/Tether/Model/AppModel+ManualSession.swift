import Foundation
import TetherCore

extension AppModel {
    var manualSessionAvailable: Bool { usesUserSession || (sessionAvailable && status?.manualSession != nil) }
    var manualSessionInfo: ManualSessionStatus? {
        if let value = userSessionStatus {
            return ManualSessionStatus(active: value.manualActive, holding: value.manualActive && value.holding,
                until: value.until?.timeIntervalSince1970, batteryRemaining: value.manualBatteryRemaining,
                endReason: value.manualEndReason, batteryContinuationMinutes: value.manualBatteryContinuationMinutes,
                startedOnBattery: value.manualStartedOnBattery)
        }
        return helperResponding ? status?.manualSession : nil
    }
    var manualSessionActive: Bool { manualSessionInfo?.active == true }
    var manualBatteryContinuationMinutes: Int? { nil }
    var manualBatteryContinuationMaximumMinutes: Int {
        Int(min(ManualSessionPolicy.batteryMaximum, SafetyPolicy.maxHold(limits)) / 60)
    }
    var canConfigureManualBatteryContinuation: Bool {
        false
    }
    func setManualBatteryContinuationMinutes(_ minutes: Int?) {
        guard acceptingUserCommands, !commandPending, let userSession else { return }
        if !userSession.setManualBatteryContinuationMinutes(minutes) {
            errorText = userSession.status.error ?? L("The manual unplug choice could not be saved.", "수동 유지의 전원 분리 선택을 저장하지 못했습니다.")
        }
    }
    var manualSessionUntil: Date? { manualSessionInfo?.until.map { Date(timeIntervalSince1970: $0) } }
    var manualMaximumMinutes: Int {
        if let value = userSessionStatus { return value.manualMaximumMinutes }
        return snapshot.power == .ac ? Int(ManualSessionPolicy.maximumTimedDuration / 60)
            : Int(min(ManualSessionPolicy.batteryMaximum, SafetyPolicy.maxHold(limits)) / 60)
    }
    var canStartManualSession: Bool {
        guard manualSessionAvailable, !v4AcquisitionBlocked, !v4ManualApprovalPending, !commandPending, !manualSessionActive,
              snapshot.power != .unknown, protection?.blockReason == nil else { return false }
        if let value = userSessionStatus { return value.canStart }
        guard !helperOutdated, status?.appConnected == true, (0..<2).contains(thermalLevel) else { return false }
        return snapshot.power == .ac || (SafetyPolicy.canStartHold(batteryPercent: batteryPercent, user: limits)
            && (manualSessionInfo?.batteryRemaining ?? 0) > 0)
    }
    var canStartUnlimitedManualSession: Bool { canStartManualSession && snapshot.power == .ac }
    var automaticWorkReasonActive: Bool {
        if let value = userSessionStatus { return value.automaticActive }
        return helperResponding && enabled && protection?.blockReason == nil
            && Policy.wantsClamshell(snapshot, enabled: enabled, sleepNowPending: false,
                batteryHold: batteryHoldUntil != nil, condition: powerCondition, ownsOverride: status?.ownsOverride == true)
    }
    var tetherEnabled: Bool { enabled || manualSessionActive }

    var selectedManualMinutes: Int {
        let selected = v3Settings.lastManualDurationSeconds.map { max(1, Int($0 / 60)) } ?? 0
        if selected == 0 && snapshot.power == .ac { return 0 }
        return min(manualMaximumMinutes, selected == 0 ? min(120, manualMaximumMinutes) : selected)
    }
    var manualDurationChoices: [Int] {
        SessionDuration.choices(maximum: manualMaximumMinutes, including: selectedManualMinutes)
    }
    var manualContinuationChoices: [Int] {
        SessionDuration.choices(maximum: 120, including: v3Settings.manualBatteryContinuationMinutes)
    }
    func durationChoiceTitle(_ minutes: Int) -> String {
        let duration = Texts.duration(Double(minutes) * 60)
        return SessionDuration.presets.contains(minutes)
            ? duration : L("\(duration) · Saved", "\(duration) · 기존 설정")
    }
    var manualEndingDetail: String {
        if automaticWorkReasonActive {
            return L("Ending this session leaves automatic keep-awake active.", "끝내도 자동 유지는 계속됩니다.")
        }
        return v3Settings.automaticEnabled
            ? L("Ending this session waits for the next automatic condition.", "끝내면 자동 조건이 맞을 때까지 대기합니다.")
            : L("Ending this session turns keep-awake off.", "끝내면 작업 유지가 꺼집니다.")
    }
    var manualBatteryScopeDetail: String {
        L("Unplugging ends existing sessions. A new battery session is manual, limited to two hours from its first start.",
          "전원을 빼면 기존 유지는 끝납니다. 배터리에서는 새로 수동 시작하며 최초 시작부터 최대 2시간입니다.")
    }
    var manualStartBlockedDetail: String {
        if let reason = workProtectionReason { return protectionReason(reason) }
        if workPaused { return L("Choose Resume work before starting a manual session.", "‘작업 재개’를 누른 뒤 수동 유지를 시작하세요.") }
        if let error = userSessionStatus?.error { return error }
        if snapshot.power == .unknown { return L("Confirming the power source.", "전원 연결 상태를 확인하고 있습니다.") }
        return L("Start requires an active user session and confirmed power and protection readings.",
                 "현재 로그인 사용자와 전원·보호 관측값을 확인한 뒤 시작할 수 있습니다.")
    }
}
