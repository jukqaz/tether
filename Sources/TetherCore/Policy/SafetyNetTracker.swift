import Foundation

/// Protection for Tether's closed-lid AC hold. Native display operation belongs to macOS.
/// Celsius readings are diagnostic only; serious/critical OS pressure ends the hold.
public struct SafetyNetTracker: Equatable, Sendable {
    /// Current pressure observation; no extra grace period.
    public private(set) var criticalSince: Date?
    public private(set) var drainingSince: Date?

    public init() {}

    /// Something is building up, so the helper checks more often.
    public var isWatching: Bool { criticalSince != nil || drainingSince != nil }

    /// Updates the timers and returns why the Mac should sleep now, if it should. The timers
    /// start over once a reason is returned.
    public mutating func update(_ s: Snapshot, clamshellOn: Bool, readings r: SafetyReadings, floor: Int,
                                now: Date) -> EventKind? {
        guard clamshellOn, s.power == .ac, s.lidClosed, !s.defersToDisplaySetup else {
            self = Self(); return nil
        }
        let onAC = true
        criticalSince = (2...3).contains(r.thermal) ? (criticalSince ?? now) : nil
        drainingSince = WeakChargerPolicy.isRunningDown(r, onAC: onAC, lidClosed: s.lidClosed, clamshellOn: clamshellOn,
                                                        floor: floor) ? (drainingSince ?? now) : nil
        let reason: EventKind?
        if criticalSince != nil {
            reason = .overheatSleep
        } else if WeakChargerPolicy.shouldSleep(externalDisplay: s.externalDisplay, drainingSince: drainingSince, now: now) {
            reason = .weakChargerSleep
        } else {
            reason = nil
        }
        if reason != nil { self = SafetyNetTracker() }
        return reason
    }
}
