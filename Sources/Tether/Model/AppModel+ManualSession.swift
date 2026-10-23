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
            return L("Wait for the previous request to be confirmed before extending.",
                     "이전 요청을 확인한 뒤 연장할 수 있습니다.")
        }
        if v4ManualApprovalPending || userSession?.manualExtensionPending == true
            || userSessionStatus?.manualApprovalPending == true {
            return L("A manual request or extension is still being confirmed.",
                     "수동 유지의 승인·연장을 확인 중입니다.")
        }
        if let reason = workProtectionReason { return protectionReason(reason) }
        if workPaused {
            return L("Keep-awake is paused. Resume before reviewing an extension.",
                     "유지가 중지되어 있습니다. 다시 허용한 뒤 확인하세요.")
        }
        guard manualSessionActive, manualSessionUntil != nil else {
            return L("There is no active finite timer to extend.", "연장할 실행 중인 유한 타이머가 없습니다.")
        }
        if v4AcquisitionBlocked {
            return L("Extensions are unavailable while preparing an update installation.",
                     "업데이트 설치를 준비하는 동안에는 연장할 수 없습니다.")
        }
        if !acceptingUserCommands {
            return L("Confirm the current Tether session before extending.",
                     "현재 Tether 실행 권한을 확인해야 연장할 수 있습니다.")
        }
        if snapshot.power == .unknown {
            return L("Extensions wait until the power source is confirmed.",
                     "전원 상태가 확인될 때까지 연장할 수 없습니다.")
        }
        if userSessionStatus?.observationLimited == true {
            return L("Extensions wait for the required power and protection observations.",
                     "전원·보호 관측이 확인될 때까지 연장할 수 없습니다.")
        }
        if userSession?.hasConfirmedSessionAuthority != true {
            return L("Confirm the logged-in session and wake state before extending.",
                     "로그인 세션·깨움 상태를 확인해야 연장할 수 있습니다.")
        }
        if manualFeaturesNeedHelper && !canAcquireManualFeatures {
            return L("Confirm the closed-lid helper and its current observations before extending.",
                     "덮개 도우미의 연결·관측을 확인해야 연장할 수 있습니다.")
        }
        if snapshot.power == .battery,
           let request = userSession?.v4ManualSnapshot,
           let limit = request.batteryTimeLimit, limit != .unlimited {
            // The captured request limit is authoritative, not today's default.
            // Do not duplicate deadline arithmetic or claim which gate failed.
            return L("The full \(minutes)-minute extension is unavailable. Review this request's battery limit and original deadline.",
                     "\(minutes)분 전체를 연장할 수 없습니다. 이 요청의 배터리 한도와 원래 마감을 확인하세요.")
        }
        return L("The full \(minutes)-minute extension is not confirmed for the current timer, power and protection state.",
                 "현재 타이머의 기한·전원·보호 상태에서 \(minutes)분 전체 연장이 확인되지 않습니다.")
    }

    var manualEndingDetail: String {
        if automaticWorkReasonActive {
            return L("Ending this session leaves automatic keep-awake active.", "끝내도 자동 유지는 계속됩니다.")
        }
        if automaticPauseActive {
            return L("Ending manual work keeps automatic starts resting.", "수동 종료는 자동 쉬기를 해제하지 않습니다.")
        }
        return v3Settings.automaticEnabled
            ? L("Ending this session waits for the next automatic condition.", "끝내면 자동 조건이 맞을 때까지 대기합니다.")
            : L("Ending this session turns keep-awake off.", "끝내면 작업 유지가 꺼집니다.")
    }
    var manualBatteryScopeDetail: String {
        disconnectPolicyDetail + " " + L("Battery limit: ", "배터리 한도: ") + batteryLimitTitle(v3Settings.batteryTimeLimit)
    }
    var manualStartBlockedDetail: String {
        if let reason = workProtectionReason { return protectionReason(reason) }
        if workPaused { return L("Choose Resume before starting a manual session.", "‘다시 허용’을 누른 뒤 수동 유지를 시작하세요.") }
        if let error = userSessionStatus?.error { return error }
        if snapshot.power == .unknown { return L("Confirming the power source.", "전원 연결 상태를 확인하고 있습니다.") }
        return L("Start requires an active user session and confirmed power and protection readings.",
                 "현재 로그인 사용자와 전원·보호 관측값을 확인한 뒤 시작할 수 있습니다.")
    }
}
