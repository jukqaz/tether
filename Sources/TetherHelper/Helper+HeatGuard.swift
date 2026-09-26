import Foundation
import TetherCore

/// Heat with the lid closed on power: Low Power Mode, and an alert when it stays critical. The
/// last-resort sleep is in `Helper+SafetyNet`.
extension Helper {
    /// Lid closed on AC blocks the hinge vent. Cool the Mac with Low Power Mode and raise an alert
    /// when critical pressure lasts.
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
