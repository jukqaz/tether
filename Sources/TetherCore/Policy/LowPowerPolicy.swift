import Foundation

/// When Tether may switch Low Power Mode on. Only two cases, each the user's choice: a battery
/// hold (the battery setting, `Control.holdLowPower`) and heat with the lid closed on power (the AC
/// setting, `ACThermalPolicy` and `HeatGuardSettings`). Tether remembers the value it replaced and
/// puts it back afterwards, unless the user changed the setting in the meantime.
public enum LowPowerPolicy {
    /// During a battery hold, on unless turned off in Settings.
    public static func wantsOnBattery(holdingOnBattery: Bool, allowed: Bool?) -> Bool {
        holdingOnBattery && (allowed ?? true)
    }

    /// Put the saved value back only while the setting still shows the "on" Tether chose. If the
    /// user switched Low Power Mode off meanwhile, or it can't be read, it's left alone.
    public static func shouldRestore(current: Int?, saved: Int) -> Bool {
        current == 1 && saved != 1
    }
}
