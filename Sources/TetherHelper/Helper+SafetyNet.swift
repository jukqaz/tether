import Foundation
import TetherCore

/// With the lid closed on power: the critical-heat alert, and the last-resort sleep where the Mac
/// may be in a bag on a power bank (overheating, or a charger that can't keep up). The timing is
/// `SafetyNetTracker`, tested in Core.
extension Helper {
    func updateSafetyNet(_ s: Snapshot, clamshellOn: Bool, readings r: SafetyReadings) {
        let now = Date(timeIntervalSince1970: ContinuousTime.now)
        let criticalNow = clamshellOn && s.power == .ac && s.lidClosed && !s.defersToDisplaySetup && r.thermal == 3
        if !criticalNow { criticalAlerted = false }
        if criticalNow && !criticalAlerted {
            criticalAlerted = true
            thermalAlertAt = Date().timeIntervalSince1970
            note(.heatCritical)
            logReadings(r)
        }
        let reason = safetyNet.update(s, clamshellOn: clamshellOn, readings: r,
                                      floor: SafetyPolicy.floor(limits), now: now)
        switch reason {
        case .overheatSleep: overheatSleepAt = Date().timeIntervalSince1970
        case .weakChargerSleep: weakChargerSleepAt = Date().timeIntervalSince1970
        default: return
        }
        // Like "sleep now", it ends an armed hold; quietly, as the reason is reported after wake.
        criticalAlerted = false
        protection.block(reason == .overheatSleep ? "thermal" : (reason?.rawValue ?? "thermal"))
        if holdWasActive { consumeHold() }
        sleepNowReason = reason ?? .sleepNow
        sleepNowIntent = .protection
        sleepNowUntil = Date().addingTimeInterval(20)
        schedule(.sleepNow)
    }
}
