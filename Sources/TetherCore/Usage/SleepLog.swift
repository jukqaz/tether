import Foundation

/// One stretch of system sleep, from "will sleep" to the next full wake (dark wakes in between
/// are counted, not split out).
public struct SleepRecord: Codable, Equatable, Sendable {
    public var sleptAt: Double
    public var wokeAt: Double?
    public var percentBefore: Int?
    public var percentAfter: Int?
    public var onBatteryBefore: Bool
    public var onBatteryAfter: Bool?
    /// IOPMrootDomain "Last Sleep Reason", e.g. "Clamshell Sleep", "Software Sleep".
    public var sleepReason: String?
    /// Tether asked for this sleep (power pulled with the lid shut, a hold ending, "sleep now").
    public var byTether: Bool
    /// IOPMrootDomain "Wake Type" and "Wake Reason" at the full wake.
    public var wakeType: String?
    public var wakeReason: String?
    public var darkWakes: Int

    public init(sleptAt: Double, percentBefore: Int?, onBatteryBefore: Bool, byTether: Bool = false) {
        self.sleptAt = sleptAt
        self.percentBefore = percentBefore
        self.onBatteryBefore = onBatteryBefore
        self.byTether = byTether
        darkWakes = 0
    }

    public var duration: TimeInterval? { wokeAt.map { $0 - sleptAt } }

    /// Charge used per hour, only for sleeps on battery throughout and long enough for whole
    /// percentage points to mean something.
    public var drainPerHour: Double? {
        guard let d = duration, d >= SleepLog.minimumForDrain, onBatteryBefore, onBatteryAfter == true,
              let before = percentBefore, let after = percentAfter, before >= after else { return nil }
        return Double(before - after) / (d / 3600)
    }
}

public struct SleepLog: Codable, Equatable, Sendable {
    public var open: SleepRecord?
    /// Finished sleeps, oldest first.
    public var recent: [SleepRecord]

    public static let keep = 20
    /// Shorter "sleeps" were cancelled on the way down (input during the pre-sleep window).
    public static let minimumDuration: TimeInterval = 60
    public static let minimumForDrain: TimeInterval = 1800
    /// Above this per hour, sleep is costing more than it should (1–2 %/h is typical).
    public static let highDrain: Double = 3

    public init(open: SleepRecord? = nil, recent: [SleepRecord] = []) {
        self.open = open
        self.recent = recent
    }

    /// Call on "will sleep". A record left open by a dark wake keeps running.
    public mutating func willSleep(at t: Double, percent: Int?, onBattery: Bool, byTether: Bool) {
        if open == nil {
            open = SleepRecord(sleptAt: t, percentBefore: percent, onBatteryBefore: onBattery, byTether: byTether)
        } else if byTether {
            open?.byTether = true
        }
    }

    /// Call on every check after a wake. A dark wake is counted; a full wake closes the record,
    /// which is returned when it lasted long enough to keep.
    public mutating func awake(at t: Double, fullWake: Bool, justWoke: Bool, percent: Int?, onBattery: Bool,
                               sleepReason: String?, requestedByTether: Bool, wakeType: String?,
                               wakeReason: String?) -> SleepRecord? {
        guard var record = open else { return nil }
        guard fullWake else {
            if justWoke { open?.darkWakes += 1 }
            return nil
        }
        open = nil
        record.wokeAt = t
        record.percentAfter = percent
        record.onBatteryAfter = onBattery
        record.sleepReason = sleepReason
        record.byTether = record.byTether || requestedByTether
        record.wakeType = wakeType
        record.wakeReason = wakeReason
        guard (record.duration ?? 0) >= Self.minimumDuration else { return nil }
        recent.append(record)
        if recent.count > Self.keep { recent.removeFirst(recent.count - Self.keep) }
        return record
    }

    /// Duration-weighted drain over the sleeps that measured one.
    public var averageDrain: Double? {
        let measured = recent.filter { $0.drainPerHour != nil }
        let hours = measured.reduce(0) { $0 + ($1.duration ?? 0) / 3600 }
        guard hours > 0 else { return nil }
        let used = measured.reduce(0) { $0 + Double(($1.percentBefore ?? 0) - ($1.percentAfter ?? 0)) }
        return used / hours
    }
}
