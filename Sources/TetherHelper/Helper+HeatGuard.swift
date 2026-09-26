import Foundation
import TetherCore

/// Heat with the lid closed on power: Low Power Mode, an alert, and sleep as a last resort.
extension Helper {
    /// Lid closed on AC blocks the hinge vent. Cool the Mac with Low Power Mode first and raise
    /// an alert when critical pressure lasts; with no external display attached, sustained
    /// critical pressure or a hot battery puts it to sleep.
    func updateHeatGuard(_ s: Snapshot, clamshellOn: Bool, readings r: SafetyReadings) {
        let now = Date()
        let settings = control.heatGuard ?? .standard
        if r.thermal < settings.threshold {
            if coolSince == nil { coolSince = now }
        } else {
            coolSince = nil
        }
        if clamshellOn, s.power == .ac, s.lidClosed, r.thermal >= 3 {
            if criticalSince == nil { criticalSince = now }
        } else {
            criticalSince = nil
            criticalAlerted = false
        }
        let want = ACThermalPolicy.wantsLowPower(clamshellOn: clamshellOn, onAC: s.power == .ac,
                                                 lidClosed: s.lidClosed, thermal: r.thermal,
                                                 lowPowerOn: state.savedACLowPower != nil,
                                                 coolSince: coolSince, now: now, settings: settings)
        manageACLowPower(on: want, readings: r)
        if ACThermalPolicy.shouldAlert(criticalSince: criticalSince, alreadyAlerted: criticalAlerted, now: now) {
            criticalAlerted = true
            thermalAlertAt = now.timeIntervalSince1970
            note(.heatCritical)
            logReadings(r)
        }
        if clamshellOn, s.power == .ac, s.lidClosed, (r.temperature ?? 0) >= ACThermalPolicy.hotBattery {
            if hotSince == nil { hotSince = now }
        } else {
            hotSince = nil
        }
        // Low Power Mode was not enough and nothing shows it's at a desk: sleep, like a hold would.
        if ACThermalPolicy.shouldSleep(clamshellOn: clamshellOn, onAC: s.power == .ac, lidClosed: s.lidClosed,
                                       externalDisplay: s.externalDisplay, criticalSince: criticalSince,
                                       hotSince: hotSince, now: now) {
            overheatSleepAt = now.timeIntervalSince1970
            criticalSince = nil
            hotSince = nil
            // Like "sleep now", sleeping ends an armed hold; quietly, as overheating is reported.
            if holdWasActive { consumeHold() }
            sleepNowReason = .overheatSleep
            sleepNowUntil = now.addingTimeInterval(20)
            schedule(.sleepNow)
        }
    }

    func manageACLowPower(on: Bool, readings: SafetyReadings) {
        if on, state.savedACLowPower == nil {
            let current = SystemProbe.lowPowerMode(section: "AC Power") ?? 0
            state.savedACLowPower = current
            saveState()
            note(.heatGuardOn)
            logReadings(readings)
            usage.stats.recordHeatGuard(now: Date())
            if current != 1 { pmset(["-c", "lowpowermode", "1"]) }
        } else if !on, let saved = state.savedACLowPower {
            if LowPowerPolicy.shouldRestore(current: SystemProbe.lowPowerMode(section: "AC Power"), saved: saved) {
                pmset(["-c", "lowpowermode", String(saved)])
            }
            state.savedACLowPower = nil
            saveState()
            note(.heatGuardOff)
        }
    }
}
