import Foundation

/// Restoration of energy modes saved by older releases. New sessions never set a mode.
public enum LowPowerPolicy {
    /// Put the saved value back only while the setting still shows the "on" Tether chose. If the
    /// user switched Low Power Mode off meanwhile, or it can't be read, it's left alone.
    public static func shouldRestore(current: Int?, saved: Int) -> Bool {
        current == 1 && saved != 1
    }
}
