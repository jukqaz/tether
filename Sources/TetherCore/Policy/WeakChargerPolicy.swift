import Foundation

/// A charger that can't keep up (a small power bank, a phone charger) still counts as AC, so a
/// closed Mac in clamshell mode could run its battery flat. With no display attached, a battery at
/// the floor that keeps draining for a minute puts the Mac to sleep.
public enum WeakChargerPolicy {
    /// Draining at least this fast counts (mA); a few mA either way is noise.
    public static let drainingCurrent = -100
    public static let sleepAfter: TimeInterval = 60

    public static func isDraining(_ r: SafetyReadings) -> Bool {
        guard let current = r.current else { return false }
        return current <= drainingCurrent
    }

    /// At or below the battery floor and draining, on AC with the lid closed in clamshell mode.
    public static func isRunningDown(_ r: SafetyReadings, onAC: Bool, lidClosed: Bool, clamshellOn: Bool,
                                     floor: Int) -> Bool {
        guard clamshellOn, onAC, lidClosed, let percent = r.batteryPercent else { return false }
        return percent <= floor && isDraining(r)
    }

    /// `drainingSince`: when `isRunningDown` became true, nil while it isn't.
    public static func shouldSleep(externalDisplay: Bool, drainingSince: Date?, now: Date) -> Bool {
        guard !externalDisplay, let drainingSince else { return false }
        return now.timeIntervalSince(drainingSince) >= sleepAfter
    }
}
