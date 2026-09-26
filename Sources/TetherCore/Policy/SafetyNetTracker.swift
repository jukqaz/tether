import Foundation

/// Times the last-resort conditions with the lid closed on power and says when to sleep:
/// critical pressure (`ACThermalPolicy.sleepAfterCritical`), a hot battery
/// (`ACThermalPolicy.hotBattery` for `sleepAfterHot`), or a charger that can't keep up
/// (`WeakChargerPolicy`). A value type fed the time, so the timing is tested without waiting.
public struct SafetyNetTracker: Equatable, Sendable {
    /// Also drives the critical-heat alert, which applies with an external display too.
    public private(set) var criticalSince: Date?
    public private(set) var hotSince: Date?
    public private(set) var drainingSince: Date?

    public init() {}

    /// Something is building up, so the helper checks more often.
    public var isWatching: Bool { criticalSince != nil || hotSince != nil || drainingSince != nil }

    /// Updates the timers and returns why the Mac should sleep now, if it should. The timers
    /// start over once a reason is returned.
    public mutating func update(_ s: Snapshot, clamshellOn: Bool, readings r: SafetyReadings, floor: Int,
                                now: Date) -> EventKind? {
        let onAC = s.power == .ac
        let closedOnPower = clamshellOn && onAC && s.lidClosed
        criticalSince = closedOnPower && r.thermal >= 3 ? (criticalSince ?? now) : nil
        hotSince = closedOnPower && (r.temperature ?? 0) >= ACThermalPolicy.hotBattery ? (hotSince ?? now) : nil
        drainingSince = WeakChargerPolicy.isRunningDown(r, onAC: onAC, lidClosed: s.lidClosed, clamshellOn: clamshellOn,
                                                        floor: floor) ? (drainingSince ?? now) : nil
        let reason: EventKind?
        if ACThermalPolicy.shouldSleep(clamshellOn: clamshellOn, onAC: onAC, lidClosed: s.lidClosed,
                                       externalDisplay: s.externalDisplay, criticalSince: criticalSince,
                                       hotSince: hotSince, now: now) {
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
