import Foundation
import TetherCore

/// Heat with the lid closed on power: Low Power Mode. The critical-heat alert and the
/// last-resort sleep are in `Helper+SafetyNet`.
extension Helper {
    /// Lid closed on AC blocks the hinge vent: cool the Mac with Low Power Mode.
    func updateHeatGuard(_ s: Snapshot, clamshellOn: Bool, readings r: SafetyReadings) {
        let now = Date()
        let settings = control.heatGuard ?? .standard
        if r.thermal < settings.threshold {
            if coolSince == nil { coolSince = now }
        } else {
            coolSince = nil
        }
        let want = ACThermalPolicy.wantsLowPower(clamshellOn: clamshellOn, onAC: s.power == .ac,
                                                 lidClosed: s.lidClosed, thermal: r.thermal,
                                                 lowPowerOn: state.savedACLowPower != nil,
                                                 coolSince: coolSince, now: now, settings: settings)
        manageACLowPower(on: want, readings: r)
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
