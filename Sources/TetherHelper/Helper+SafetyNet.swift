import Foundation
import TetherCore

/// With the lid closed on power: the critical-heat alert, and the last-resort sleep where the Mac
/// may be in a bag on a power bank (overheating, or a charger that can't keep up). The timing is
/// `SafetyNetTracker`, tested in Core.
extension Helper {
    func updateSafetyNet(_ s: Snapshot, clamshellOn: Bool, readings r: SafetyReadings) {
        let now = Date()
        let reason = safetyNet.update(s, clamshellOn: clamshellOn, readings: r,
                                      floor: SafetyPolicy.floor(limits), now: now)
        if safetyNet.criticalSince == nil { criticalAlerted = false }
        if ACThermalPolicy.shouldAlert(criticalSince: safetyNet.criticalSince, alreadyAlerted: criticalAlerted, now: now) {
            criticalAlerted = true
            thermalAlertAt = now.timeIntervalSince1970
            note(.heatCritical)
            logReadings(r)
        }
        switch reason {
        case .overheatSleep: overheatSleepAt = now.timeIntervalSince1970
        case .weakChargerSleep: weakChargerSleepAt = now.timeIntervalSince1970
        default: return
        }
        // Like "sleep now", it ends an armed hold; quietly, as the reason is reported after wake.
        criticalAlerted = false
        if holdWasActive { consumeHold() }
        sleepNowReason = reason ?? .sleepNow
        sleepNowUntil = now.addingTimeInterval(20)
        schedule(.sleepNow)
    }
}
