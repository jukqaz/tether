import Foundation
import TetherCore

/// The battery-hold limits, Low Power Mode and the heat guard, and what the measurements recommend
/// for them. They live in the control file because the helper enforces them.
extension AppModel {
    /// The limits the helper enforces: `limits`, or with auto-adjust on, what this Mac's
    /// measurements make of them. The helper computes the same from the same `usage.json`.
    var limitsInForce: UserLimits { Advisor.limitsInForce(limits, auto: autoLimits, summary: summary) ?? UserLimits() }

    var batteryFloor: Int { SafetyPolicy.floor(limits) }
    var maxHoldMinutes: Int { Int(SafetyPolicy.maxHold(limitsInForce) / 60) }

    /// 30 min, 1 h, 2 h under the maximum set in Settings, then the maximum itself.
    var holdChoices: [Int] {
        let longest = maxHoldMinutes
        return [30, 60, 120].filter { $0 < longest } + [longest]
    }

    func safetyLimits(lidClosed: Bool) -> SafetyLimits { SafetyPolicy.limits(lidClosed: lidClosed, user: limitsInForce) }

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

    func setAutoLimits(_ on: Bool) {
        appLog.notice("auto-adjust \(on ? "on" : "off", privacy: .public)")
        save { ControlStore.update { $0.autoLimits = on ? true : nil } }
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

    var safetyIsDefault: Bool { limits.isDefault && !autoLimits && heatGuard == .standard && holdLowPower }

    func resetSafety() {
        save {
            ControlStore.update {
                $0.limits = nil
                $0.autoLimits = nil
                $0.heatGuard = nil
                $0.holdLowPower = nil
            }
        }
    }

    // MARK: Recommendations

    var recommendations: Recommendations { Recommendations(summary, floor: batteryFloor) }

    /// Whether applying the recommendations would change anything. With auto-adjust on, the
    /// battery-hold limits already follow them, so only the Low Power Mode level is left.
    var recommendationsDiffer: Bool {
        let r = recommendations
        let heat = r.heatLevel.map { heatGuard.enabled && $0.value != heatGuard.threshold } ?? false
        guard !autoLimits else { return heat }
        return heat || (r.applied(to: limits) ?? UserLimits()) != limits
    }

    func applyRecommendations() {
        let r = recommendations
        var guardSettings = heatGuard
        if let a = r.heatLevel { guardSettings.level = a.value }
        let new = autoLimits ? limits : r.applied(to: limits) ?? UserLimits()
        save {
            ControlStore.update {
                $0.limits = new.isDefault ? nil : new
                $0.heatGuard = guardSettings == .standard ? nil : guardSettings
            }
        }
    }
}
