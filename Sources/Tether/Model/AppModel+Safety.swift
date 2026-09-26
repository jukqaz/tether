import Foundation
import TetherCore

/// The battery-hold limits and the heat guard, and what the measurements recommend for them.
/// They live in the control file because the helper enforces them.
extension AppModel {
    var batteryFloor: Int { SafetyPolicy.floor(limits) }
    var maxHoldMinutes: Int { Int(SafetyPolicy.maxHold(limits) / 60) }

    /// 30 min, 1 h, 2 h under the maximum set in Settings, then the maximum itself.
    var holdChoices: [Int] {
        let longest = maxHoldMinutes
        return [30, 60, 120].filter { $0 < longest } + [longest]
    }

    func safetyLimits(lidClosed: Bool) -> SafetyLimits { SafetyPolicy.limits(lidClosed: lidClosed, user: limits) }

    func setLimits(_ new: UserLimits) {
        save { ControlStore.update { $0.limits = new.isDefault ? nil : new } }
    }

    func setHeatGuard(_ new: HeatGuardSettings) {
        save { ControlStore.update { $0.heatGuard = new == .standard ? nil : new } }
    }

    func resetSafety() {
        save {
            ControlStore.update {
                $0.limits = nil
                $0.heatGuard = nil
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
