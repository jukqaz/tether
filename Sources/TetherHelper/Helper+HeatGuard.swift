import Foundation
import TetherCore

/// Recovery only: new sessions never change macOS energy modes. Keep this journal reader
/// until every older helper can be upgraded/uninstalled without leaving its changes behind.
extension Helper {
    func restoreLegacyPowerModes() {
        _ = withRecoveryLock { restoreLegacyPowerModesLocked() }
    }

    private func restoreLegacyPowerModesLocked() {
        for onBattery in [true, false] {
            guard let saved = onBattery ? state.savedBatteryLowPower : state.savedACLowPower else { continue }
            guard let setting = currentPowerMode(onBattery: onBattery) else {
                lastApplyError = "lowPowerUnreadable"; continue
            }
            let signature = "\(setting.key.rawValue)|\(setting.value)|\(saved)"
                + (dryRun ? "|\(String(describing: fake["commandFailure"]))|\(String(describing: fake["commandNoEffect"]))" : "")
            if let failed = legacyRestoreFailures[onBattery], failed.key == signature {
                lastApplyError = failed.error; continue
            }
            if LowPowerPolicy.shouldRestore(current: setting.value, saved: saved),
               !restorePowerMode(setting, saved: saved, onBattery: onBattery) {
                legacyRestoreFailures[onBattery] = (signature, lastApplyError ?? "powerVerificationFailed")
                continue
            }
            // A successful setter or earlier read is not the last verification.
            // Keep the recovery entry if this final query is unavailable or the
            // original Tether value still needs restoration.
            guard let verified = currentPowerMode(onBattery: onBattery),
                  !LowPowerPolicy.shouldRestore(current: verified.value, saved: saved) else {
                lastApplyError = "powerVerificationFailed"
                legacyRestoreFailures[onBattery] = (signature, "powerVerificationFailed")
                continue
            }
            // A different current value belongs to the user/another tool. Do not overwrite it.
            if onBattery { state.savedBatteryLowPower = nil } else { state.savedACLowPower = nil }
            if !saveState() {
                if onBattery { state.savedBatteryLowPower = saved } else { state.savedACLowPower = saved }
                continue
            }
            log("legacy \(onBattery ? "battery" : "AC") energy mode recovery completed; prior/user mode retained")
            legacyRestoreFailures.removeValue(forKey: onBattery)
        }
        if state.savedBatteryLowPower != nil || state.savedACLowPower != nil {
            protection.block("powerModeRestoreFailed")
        }
    }
}
