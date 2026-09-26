import Foundation
import TetherCore

/// Last-resort sleep with the lid closed on power and no external display, where the Mac may be in
/// a bag on a power bank: overheating (`ACThermalPolicy.shouldSleep`) or a charger that can't keep
/// up while the battery is at the floor (`WeakChargerPolicy`).
extension Helper {
    func updateSafetyNet(_ s: Snapshot, clamshellOn: Bool, readings r: SafetyReadings) {
        let now = Date()
        let onAC = s.power == .ac
        if clamshellOn, onAC, s.lidClosed, (r.temperature ?? 0) >= ACThermalPolicy.hotBattery {
            if hotSince == nil { hotSince = now }
        } else {
            hotSince = nil
        }
        if WeakChargerPolicy.isRunningDown(r, onAC: onAC, lidClosed: s.lidClosed, clamshellOn: clamshellOn,
                                           floor: SafetyPolicy.floor(control.limits)) {
            if drainingSince == nil { drainingSince = now }
        } else {
            drainingSince = nil
        }
        if ACThermalPolicy.shouldSleep(clamshellOn: clamshellOn, onAC: onAC, lidClosed: s.lidClosed,
                                       externalDisplay: s.externalDisplay, criticalSince: criticalSince,
                                       hotSince: hotSince, now: now) {
            overheatSleepAt = now.timeIntervalSince1970
            sleepForSafety(.overheatSleep, now: now)
        } else if WeakChargerPolicy.shouldSleep(externalDisplay: s.externalDisplay, drainingSince: drainingSince, now: now) {
            weakChargerSleepAt = now.timeIntervalSince1970
            sleepForSafety(.weakChargerSleep, now: now)
        }
    }

    /// Sleep through the "sleep now" path. Like "sleep now", it ends an armed hold; quietly, as
    /// the reason is reported after wake.
    private func sleepForSafety(_ reason: EventKind, now: Date) {
        criticalSince = nil
        hotSince = nil
        drainingSince = nil
        if holdWasActive { consumeHold() }
        sleepNowReason = reason
        sleepNowUntil = now.addingTimeInterval(20)
        schedule(.sleepNow)
    }
}
