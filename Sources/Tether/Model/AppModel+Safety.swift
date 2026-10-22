import Foundation
import TetherCore

/// User-selected limits and power preferences enforced by the helper.
extension AppModel {
    var batteryFloor: Int { SafetyPolicy.floor(limits) }
    var maxHoldMinutes: Int {
        Int(SafetyPolicy.maxHold(limits) / 60)
    }

    var holdStartTitle: String {
        return snapshot.power == .ac ? L("Reserve", "예약하기") : L("Start now", "지금 시작")
    }
    var holdStartDetail: String {
        return snapshot.power == .ac
            ? L("The countdown starts when you unplug, not while charging.", "전원을 분리하면 선택한 시간 동안 잠자기를 방지합니다.")
            : L("The countdown starts now and ends automatically.", "선택한 시간 동안 잠자기를 방지한 뒤 자동으로 끝냅니다.")
    }
    var protectionResumeDetail: String {
        if usesUserSession, ["battery", "sensor"].contains(protection?.blockReason ?? ""), snapshot.power == .battery {
            return L("Resume needs at least \(batteryFloor + SafetyPolicy.resumeBatteryMargin)% charge and nominal/fair macOS thermal pressure.",
                     "잔량 \(batteryFloor + SafetyPolicy.resumeBatteryMargin)% 이상, 시스템 발열이 정상·주의일 때 다시 켤 수 있습니다.")
        }
        if usesUserSession { return L("Resume after macOS thermal pressure returns to nominal or fair.", "시스템 발열이 정상·주의로 돌아온 뒤 직접 다시 켤 수 있습니다.") }
        if needsActivityReview {
            return L("Review other power or screen requests, resolve the cause, then resume yourself.", "다른 전원·화면 요청을 점검하고 원인을 해결한 뒤 직접 다시 켜세요.")
        }
        if ["budget", "time"].contains(protection?.blockReason ?? "") {
            return L("Keep power connected until its return is confirmed, then resume yourself.", "안정적인 전원 복귀가 확인될 때까지 연결을 유지한 뒤 직접 재개하세요.")
        }
        let charge = batteryFloor + SafetyPolicy.resumeBatteryMargin
        return L("Resume needs at least \(charge)% charge and nominal/fair macOS thermal pressure.",
                 "배터리 잔량 \(charge)% 이상, 시스템 발열이 정상·주의일 때 재개할 수 있습니다.")
    }

    /// 30 min, 1 h, 2 h under the maximum set in Settings, then the maximum itself.
    var holdChoices: [Int] {
        SessionDuration.choices(maximum: maxHoldMinutes)
    }

    var batteryPercent: Int? {
        if let session = userSessionStatus { return session.batteryPercent }
        return status?.batteryPercent ?? SystemProbe.batteryPercent()
    }

    /// A hold started at or below the battery floor would end at once, so it isn't offered.
    var canStartHold: Bool {
        guard hasInternalBattery else { return false }
        if usesUserSession { return userSessionStatus?.canStartBatteryHold == true && !commandPending }
        return helperResponding && !helperOutdated && !commandPending && pendingHoldMinutes == nil && enabled && protection?.blockReason == nil && (0..<2).contains(thermalLevel) && SafetyPolicy.canStartHold(batteryPercent: batteryPercent, user: limits)
    }

    /// Why a hold can't start, for the panel.
    var holdBlockedReason: String {
        if let error = batteryControlError { return UserSessionFailure(error).localizedDescription }
        if usesUserSession {
            if let error = userSessionStatus?.error { return error }
            if let reason = protection?.blockReason { return protectionReason(reason) }
            if !(0..<2).contains(thermalLevel) { return L("Wait for thermal pressure to settle", "시스템 발열이 낮아진 뒤 시작해 주세요") }
            if snapshot.power == .battery {
                if let percent = batteryPercent, percent <= batteryFloor {
                    return L("Charge above the \(batteryFloor)% reserve before starting.", "잔량이 하한 \(batteryFloor)%보다 높아진 뒤 시작해 주세요.")
                }
                if batteryPercent == nil { return L("Battery reading unavailable", "배터리 잔량 확인 필요") }
                if (userSessionStatus?.batteryRemaining ?? 0) <= 0 {
                    return L("The battery time allowance is exhausted. Keep power connected before starting again.", "배터리 시간 한도를 소진했습니다. 전원 연결을 유지한 뒤 다시 시작해 주세요.")
                }
            }
            return L("Confirm the active user and awake state before starting.", "현재 로그인 사용자와 깨어 있음 상태를 확인한 뒤 시작할 수 있습니다.")
        }
        if commandPending { return L("Applying…", "적용 중…") }
        if helperOutdated { return L("Update the helper first", "도우미를 먼저 업데이트해 주세요") }
        if !helperResponding { return L("Helper unavailable", "도우미 연결 필요") }
        if !enabled { return L("Turn on clamshell first", "클램쉘을 먼저 켜 주세요") }
        if let reason = protection?.blockReason { return protectionReason(reason) }
        if !(0..<2).contains(thermalLevel) { return L("Wait for thermal pressure to settle", "시스템 발열이 낮아진 뒤 시작해 주세요") }
        if batteryPercent == nil { return L("Battery reading unavailable", "배터리 잔량 확인 필요") }
        return L("Battery at \(batteryPercent ?? 0)%, at or under the \(batteryFloor)% floor",
          "배터리 \(batteryPercent ?? 0)%, 하한선 \(batteryFloor)% 이하")
    }

    func setLimits(_ new: UserLimits) {
        if usesUserSession { setUserSessionLimits(new); return }
        save { ControlStore.update { $0.limits = new.isDefault ? nil : new } }
    }

    var safetyIsDefault: Bool { limits.isDefault }

    func resetSafety() {
        if usesUserSession { setUserSessionLimits(UserLimits()); return }
        save {
            ControlStore.update {
                $0.limits = nil
                $0.autoLimits = nil
                $0.heatGuard = nil
                $0.holdLowPower = nil
            }
        }
    }

}
