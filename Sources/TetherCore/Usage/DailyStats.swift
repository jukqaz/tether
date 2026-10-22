import Foundation

/// What one helper check saw, as far as the stats go.
public struct UsageSample: Codable, Equatable, Sendable {
    public var lidClosed: Bool
    public var clamshellOn: Bool
    public var holdingOnBattery: Bool
    public var temperature: Double?
    public var thermal: Int
    public var batteryPercent: Int?

    public init(lidClosed: Bool, clamshellOn: Bool, holdingOnBattery: Bool = false, temperature: Double? = nil,
                thermal: Int = 0, batteryPercent: Int? = nil) {
        self.lidClosed = lidClosed
        self.clamshellOn = clamshellOn
        self.holdingOnBattery = holdingOnBattery
        self.temperature = temperature
        self.thermal = thermal
        self.batteryPercent = batteryPercent
    }
}

public struct DayStats: Codable, Equatable, Sendable {
    /// yyyy-MM-dd in local time.
    public var day: String
    /// Time spent awake with the lid closed.
    public var lidClosedSeconds: Double
    /// Legacy stored key for sleep-request attempts, not completed physical sleeps.
    /// Earlier totals are retained; a current native request counts even if refused.
    public var forcedSleeps: Int
    public var sleepRequestAttempts: Int { forcedSleeps }
    public var batteryHolds: Int
    public var heatGuards: Int
    // Measurements behind the data-based settings (absent in files from before 1.9).
    /// Battery temperature while awake with the lid closed.
    public var closedTemps: TempStats?
    /// Battery temperature with the lid open.
    public var openTemps: TempStats?
    /// Time kept awake on battery by a hold, and the charge it used (percentage points).
    public var holdSeconds: Double?
    public var holdDrain: Double?
    /// Highest thermal pressure seen awake with the lid closed.
    public var closedMaxThermal: Int?

    public init(day: String, lidClosedSeconds: Double = 0, forcedSleeps: Int = 0, batteryHolds: Int = 0,
                heatGuards: Int = 0, closedTemps: TempStats? = nil, openTemps: TempStats? = nil,
                holdSeconds: Double? = nil, holdDrain: Double? = nil, closedMaxThermal: Int? = nil) {
        self.day = day
        self.lidClosedSeconds = lidClosedSeconds
        self.forcedSleeps = forcedSleeps
        self.batteryHolds = batteryHolds
        self.heatGuards = heatGuards
        self.closedTemps = closedTemps
        self.openTemps = openTemps
        self.holdSeconds = holdSeconds
        self.holdDrain = holdDrain
        self.closedMaxThermal = closedMaxThermal
    }
}

public struct StatsTracker: Codable, Equatable, Sendable {
    /// Oldest first, at most `keepDays`.
    public var days: [DayStats]
    public var lastTick: Double?
    public var lastSample: UsageSample?

    /// Longest step counted between two checks; anything longer was sleep or downtime.
    public static let maxStep: TimeInterval = 45
    public static let keepDays = 7

    public init(days: [DayStats] = [], lastTick: Double? = nil, lastSample: UsageSample? = nil) {
        self.days = days
        self.lastTick = lastTick
        self.lastSample = lastSample
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Credits the time since the previous check to what was seen then.
    public mutating func tick(now: Date, sample: UsageSample, calendar: Calendar = .current) {
        let t = now.timeIntervalSince1970
        if let previous = lastSample, let last = lastTick, t > last, t - last <= Self.maxStep {
            let step = t - last
            let closedAwake = previous.lidClosed && previous.clamshellOn
            edit(now, calendar) { day in
                if closedAwake {
                    day.lidClosedSeconds += step
                    day.closedMaxThermal = Swift.max(day.closedMaxThermal ?? 0, previous.thermal)
                }
                if let temperature = previous.temperature {
                    if closedAwake {
                        var stats = day.closedTemps ?? TempStats()
                        stats.add(temperature, seconds: step)
                        day.closedTemps = stats
                    } else if !previous.lidClosed {
                        var stats = day.openTemps ?? TempStats()
                        stats.add(temperature, seconds: step)
                        day.openTemps = stats
                    }
                }
                if previous.holdingOnBattery {
                    day.holdSeconds = (day.holdSeconds ?? 0) + step
                    if let before = previous.batteryPercent, let after = sample.batteryPercent, before > after {
                        day.holdDrain = (day.holdDrain ?? 0) + Double(before - after)
                    }
                }
            }
        }
        lastTick = t
        lastSample = sample
    }

    /// Lid-closed time only (tests, and callers without readings).
    public mutating func tick(now: Date, active: Bool, calendar: Calendar = .current) {
        tick(now: now, sample: UsageSample(lidClosed: active, clamshellOn: active), calendar: calendar)
    }

    /// Record once for each native sleep-request call, regardless of its result.
    /// Releasing a keep-awake request without calling sleep is not an attempt.
    public mutating func recordSleepRequestAttempt(now: Date, calendar: Calendar = .current) {
        edit(now, calendar) { $0.forcedSleeps += 1 }
    }

    /// Source-compatible name used by older request paths; never proves physical sleep.
    public mutating func recordForcedSleep(now: Date, calendar: Calendar = .current) {
        recordSleepRequestAttempt(now: now, calendar: calendar)
    }

    public mutating func recordBatteryHold(now: Date, calendar: Calendar = .current) {
        edit(now, calendar) { $0.batteryHolds += 1 }
    }

    public mutating func recordHeatGuard(now: Date, calendar: Calendar = .current) {
        edit(now, calendar) { $0.heatGuards += 1 }
    }

    public func today(now: Date, calendar: Calendar = .current) -> DayStats {
        let key = Self.dayKey(now, calendar: calendar)
        return days.first { $0.day == key } ?? DayStats(day: key)
    }

    /// The last seven days ending today, oldest first, with empty days filled in.
    public func week(now: Date, calendar: Calendar = .current) -> [DayStats] {
        (0..<Self.keepDays).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            let key = Self.dayKey(date, calendar: calendar)
            return days.first { $0.day == key } ?? DayStats(day: key)
        }
    }

    private mutating func edit(_ now: Date, _ calendar: Calendar, _ change: (inout DayStats) -> Void) {
        let key = Self.dayKey(now, calendar: calendar)
        if let i = days.firstIndex(where: { $0.day == key }) {
            change(&days[i])
            return
        }
        var day = DayStats(day: key)
        change(&day)
        days.append(day)
        days.sort { $0.day < $1.day }
        if days.count > Self.keepDays { days.removeFirst(days.count - Self.keepDays) }
    }
}
