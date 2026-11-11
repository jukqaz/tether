import Foundation
import TetherCore

extension Helper {
    var manualClock: Double { dryRun ? (fake["manualClock"] as? Double ?? ContinuousTime.now) : ContinuousTime.now }
    var manualSessionAllowed: Bool {
        (state.userSessionCoordinated == true ? coordinatedWorkAllowed : manualSession.canHold)
            && protection.blockReason == nil && !sessionSuspended && !systemSleepTransition
            && (workSessionPreparation == nil || (ownsOverride && currentSnapshot().sleepDisabled))
    }
    @discardableResult
    func persistManualBudget() -> Bool {
        guard state.manualBatteryBudget != manualSession.savedBatteryBudget else { return true }
        let previous = state.manualBatteryBudget
        state.manualBatteryBudget = manualSession.savedBatteryBudget
        if saveState() { return true }
        state.manualBatteryBudget = previous
        return false
    }
    func updateManualSession(_ snapshot: Snapshot, readings: SafetyReadings) {
        let previous = manualSession
        manualSession.evaluate(power: snapshot.power, now: manualClock, user: limits)
        if manualSession.active {
            if !readings.isValid { protection.block("sensor") }
            else if readings.thermal >= 2 { protection.block("thermal") }
            else if snapshot.power == .battery,
                    !SafetyPolicy.canStartHold(batteryPercent: readings.batteryPercent, user: limits) { protection.block("battery") }
            if protection.blockReason != nil { manualSession.end(.protection) }
            else if sessionSuspended || systemSleepTransition { manualSession.end(.sessionEnded) }
        }
        if !persistManualBudget() { protection.block("stateWriteFailed"); manualSession.end(.protection) }
        if previous.active && !manualSession.active {
            log("manual session ended: \(manualSession.endReason?.rawValue ?? "none"); automatic trigger preserved")
        }
    }
    func manualSessionStatus(_ snapshot: Snapshot) -> ManualSessionStatus {
        let until = manualSession.active ? manualSession.effectiveDeadline.map {
            Date().timeIntervalSince1970 + max(0, $0 - manualClock)
        } : nil
        return ManualSessionStatus(active: manualSession.active,
            holding: manualSessionAllowed && ownsOverride && snapshot.sleepDisabled,
            until: until, batteryRemaining: manualSession.batteryRemaining(now: manualClock, user: limits),
            endReason: manualSession.endReason, batteryContinuationMinutes: manualSession.batteryContinuationMinutes,
            startedOnBattery: manualSession.startedOnBattery)
    }
}
