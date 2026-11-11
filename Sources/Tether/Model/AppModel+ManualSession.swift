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
    var canStartUnlimitedManualSession: Bool {
        canStartManualSession && (snapshot.power == .ac || v3Settings.batteryTimeLimit == .unlimited)
    }
    var automaticWorkReasonActive: Bool {
        if let value = userSessionStatus { return value.automaticActive }
        return helperResponding && enabled && protection?.blockReason == nil
            && Policy.wantsClamshell(snapshot, enabled: enabled, sleepNowPending: false,
                batteryHold: batteryHoldUntil != nil, condition: powerCondition, ownsOverride: status?.ownsOverride == true)
    }
    var tetherEnabled: Bool { enabled || manualSessionActive }

    var selectedManualMinutes: Int {
        let selected = v3Settings.lastManualDurationSeconds.map { max(1, Int($0 / 60)) } ?? 0
        if selected == 0 && (snapshot.power == .ac || v3Settings.batteryTimeLimit == .unlimited) { return 0 }
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
    /// Read-only explanation for the shipping extension gate. Never recreate
    /// its policy or infer permission from a saved default or a visible deadline.
    func manualExtensionUnavailableReason(by minutes: Int) -> String? {
        guard !canExtendManual(by: minutes) else { return nil }
        if commandPending {
            return L("Wait for the previous change to finish before adding time.",
                     "이전 변경이 완료된 뒤 시간을 추가할 수 있습니다.")
        }
        if v4ManualApprovalPending || userSession?.manualExtensionPending == true
            || userSessionStatus?.manualApprovalPending == true {
            return L("Manual keep-awake or its extension is still being confirmed.",
                     "수동 유지 시작이나 시간 추가를 확인 중입니다.")
        }
        if let reason = workProtectionReason { return protectionReason(reason) }
        if workPaused {
            return L("Keep-awake is stopped. Choose Resume before reviewing an extension.",
                     "유지가 중지되어 있습니다. 중지를 해제한 뒤 확인할 수 있습니다.")
        }
        guard manualSessionActive, manualSessionUntil != nil else {
            return L("There is no running timer to extend.", "시간을 추가할 실행 중인 타이머가 없습니다.")
        }
        if v4AcquisitionBlocked {
            return L("Extensions are unavailable while preparing an update installation.",
                     "업데이트 설치를 준비하는 동안에는 연장할 수 없습니다.")
        }
        if !acceptingUserCommands {
            return L("Confirm Tether's control access before adding time.",
                     "현재 Tether 실행 권한을 확인해야 연장할 수 있습니다.")
        }
        if snapshot.power == .unknown {
            return L("Extensions wait until the power source is confirmed.",
                     "전원 상태가 확인될 때까지 연장할 수 없습니다.")
        }
        if userSessionStatus?.observationLimited == true {
            return L("Extensions wait for the required power and protection checks.",
                     "전원·보호 상태가 확인될 때까지 연장할 수 없습니다.")
        }
        if userSession?.hasConfirmedSessionAuthority != true {
            return L("Confirm the logged-in user and wake state before adding time.",
                     "현재 로그인 사용자와 깨움 상태를 확인해야 시간을 추가할 수 있습니다.")
        }
        if manualFeaturesNeedHelper && !canAcquireManualFeatures {
            return L("Confirm the helper connection and closed-lid status before adding time.",
                     "도우미 연결과 덮개 상태를 확인해야 시간을 추가할 수 있습니다.")
        }
        if snapshot.power == .battery,
           let request = userSession?.v4ManualSnapshot,
           let limit = request.batteryTimeLimit, limit != .unlimited {
            // The captured request limit is authoritative, not today's default.
            // Do not duplicate deadline arithmetic or claim which gate failed.
            return L("The full \(minutes)-minute extension is unavailable. Check this manual keep-awake's battery limit and original end time.",
                     "\(minutes)분 전체를 추가할 수 없습니다. 현재 수동 유지의 배터리 한도와 기존 종료 시간을 확인해야 합니다.")
        }
        return L("The full \(minutes)-minute extension is not confirmed for the current end time, power and protection state.",
                 "현재 종료 시간·전원·보호 상태에서 \(minutes)분 전체 추가가 확인되지 않습니다.")
    }

    var manualEndingDetail: String {
        if automaticWorkReasonActive {
            return L("Ending manual keep-awake leaves automatic keep-awake active.", "수동 유지를 종료해도 자동 유지는 계속됩니다.")
        }
        if automaticPauseActive {
            return L("Ending manual keep-awake leaves automatic starts paused.", "수동 유지를 종료해도 자동 유지 일시 중지는 유지됩니다.")
        }
        return v3Settings.automaticEnabled
            ? L("Ending manual keep-awake waits for the next automatic condition.", "수동 유지를 종료하면 다음 자동 조건이 맞을 때까지 대기합니다.")
            : L("Ending manual keep-awake turns keep-awake off.", "수동 유지를 종료하면 잠자기 방지가 꺼집니다.")
    }
    var manualBatteryScopeDetail: String {
        disconnectPolicyDetail + " " + L("Battery limit: ", "배터리 한도: ") + batteryLimitTitle(v3Settings.batteryTimeLimit)
    }
    var manualStartBlockedDetail: String {
        if let reason = workProtectionReason { return protectionReason(reason) }
        if workPaused { return L("Choose Resume before starting manual keep-awake.", "수동 유지를 시작하려면 먼저 ‘중지 해제’가 필요합니다.") }
        if let error = userSessionStatus?.error { return error }
        if snapshot.power == .unknown { return L("Confirming the power source.", "전원 연결 상태를 확인하고 있습니다.") }
        return L("Starting requires a confirmed logged-in user, power source and protection status.",
                 "현재 로그인 사용자와 전원·보호 상태를 확인한 뒤 시작할 수 있습니다.")
    }
}
