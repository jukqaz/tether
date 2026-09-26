import Foundation
import TetherCore

/// The battery-hold limits, Low Power Mode and the heat guard, and what the measurements recommend
/// for them. They live in the control file because the helper enforces them.
extension AppModel {
    var batteryFloor: Int { SafetyPolicy.floor(limits) }
    var maxHoldMinutes: Int { Int(SafetyPolicy.maxHold(limits) / 60) }

    /// 30 min, 1 h, 2 h under the maximum set in Settings, then the maximum itself.
    var holdChoices: [Int] {
        let longest = maxHoldMinutes
        return [30, 60, 120].filter { $0 < longest } + [longest]
    }

    func safetyLimits(lidClosed: Bool) -> SafetyLimits { SafetyPolicy.limits(lidClosed: lidClosed, user: limits) }

    var batteryPercent: Int? { status?.batteryPercent ?? SystemProbe.batteryPercent() }

    /// A hold started at or below the battery floor would end at once, so it isn't offered.
    var canStartHold: Bool { SafetyPolicy.canStartHold(batteryPercent: batteryPercent, user: limits) }

    /// Why a hold can't start, for the panel.
    var holdBlockedReason: String {
        L("Battery at \(batteryPercent ?? 0)%, at or under the \(batteryFloor)% floor",
          "배터리 \(batteryPercent ?? 0)%, 하한선 \(batteryFloor)% 이하")
    }

    func setLimits(_ new: UserLimits) {
        save { ControlStore.update { $0.limits = new.isDefault ? nil : new } }
    }

    func setHeatGuard(_ new: HeatGuardSettings) {
        save { ControlStore.update { $0.heatGuard = new == .standard ? nil : new } }
    }

    func setHoldLowPower(_ on: Bool) {
        save { ControlStore.update { $0.holdLowPower = on ? nil : false } }
    }

    /// When a closed Mac running hot on power gets Low Power Mode: from "serious" (2), from "fair"
    /// (1), or never (0). One choice for the heat guard's switch and level.
    var heatLowPowerLevel: Int { heatGuard.enabled ? heatGuard.threshold : 0 }

    func setHeatLowPowerLevel(_ level: Int) {
        setHeatGuard(level == 0 ? HeatGuardSettings(enabled: false, level: heatGuard.level)
                                : HeatGuardSettings(enabled: true, level: level))
    }

    var safetyIsDefault: Bool { limits.isDefault && heatGuard == .standard && holdLowPower }

    func resetSafety() {
        save {
            ControlStore.update {
                $0.limits = nil
                $0.heatGuard = nil
                $0.holdLowPower = nil
            }
        }
    }

    // MARK: Recommendations

    /// The last seven days of measurements.
    var summary: UsageSummary { UsageSummary(week: week, sessions: usage?.recentSessions ?? []) }

    struct Recommendations: Equatable {
        var closedLid: Advice<Double>?
        var openLid: Advice<Double>?
        var maxHold: Advice<Double>?
        var heatLevel: Advice<Int>?

        var isEmpty: Bool { closedLid == nil && openLid == nil && maxHold == nil && heatLevel == nil }
    }

    var recommendations: Recommendations {
        let s = summary
        return Recommendations(closedLid: Advisor.closedLidLimit(s), openLid: Advisor.openLidLimit(s),
                               maxHold: Advisor.maxHold(s, floor: batteryFloor), heatLevel: Advisor.heatGuardLevel(s))
    }

    /// Whether applying the recommendations would change anything.
    var recommendationsDiffer: Bool {
        let r = recommendations
        let closed = safetyLimits(lidClosed: true).hardTemperature
        let open = safetyLimits(lidClosed: false).hardTemperature
        return (r.closedLid.map { $0.value != closed } ?? false)
            || (r.openLid.map { $0.value != open } ?? false)
            || (r.maxHold.map { $0.value != SafetyPolicy.maxHold(limits) / 3600 } ?? false)
            || (r.heatLevel.map { heatGuard.enabled && $0.value != heatGuard.threshold } ?? false)
    }

    func applyRecommendations() {
        let r = recommendations
        var new = limits
        if let a = r.closedLid { new.closedLidMaxTemperature = a.value == SafetyPolicy.closedLid.hardTemperature ? nil : a.value }
        if let a = r.openLid { new.openLidMaxTemperature = a.value == SafetyPolicy.openLid.hardTemperature ? nil : a.value }
        if let a = r.maxHold { new.maxHoldHours = a.value == SafetyPolicy.maxHold / 3600 ? nil : a.value }
        var guardSettings = heatGuard
        if let a = r.heatLevel { guardSettings.level = a.value }
        save {
            ControlStore.update {
                $0.limits = new.isDefault ? nil : new
                $0.heatGuard = guardSettings == .standard ? nil : guardSettings
            }
        }
    }
}
