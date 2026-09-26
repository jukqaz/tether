import Foundation

// MARK: AC heat guard

public struct HeatGuardSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Thermal pressure that turns Low Power Mode on: 1 fair, 2 serious.
    public var level: Int

    public static let standard = HeatGuardSettings(enabled: true, level: 2)

    public init(enabled: Bool, level: Int) {
        self.enabled = enabled
        self.level = level
    }

    /// Only fair or serious make sense: critical is too late to start cooling.
    public var threshold: Int { min(2, max(1, level)) }
}

/// Clamshell on AC with the lid shut still blocks the hinge vent. Tether never sleeps the Mac
/// here (remote sessions and long jobs are why clamshell is on), but it cools it with Low Power
/// Mode and raises an alert when critical pressure persists.
public enum ACThermalPolicy {
    /// Thermal pressure must stay at fair or below this long before Low Power Mode is released.
    public static let coolDown: TimeInterval = 120
    /// Critical pressure this long raises an alert.
    public static let alertAfter: TimeInterval = 180

    /// `coolSince`: when thermal pressure last dropped below the threshold, nil while it is at or
    /// above it.
    public static func wantsLowPower(clamshellOn: Bool, onAC: Bool, lidClosed: Bool, thermal: Int,
                                     lowPowerOn: Bool, coolSince: Date?, now: Date,
                                     settings: HeatGuardSettings = .standard) -> Bool {
        guard settings.enabled, clamshellOn, onAC, lidClosed else { return false }
        if thermal >= settings.threshold { return true }
        // Hysteresis: keep it until the Mac has been cool for a while, so it does not flap.
        guard lowPowerOn else { return false }
        guard let coolSince else { return true }
        return now.timeIntervalSince(coolSince) < coolDown
    }

    public static func shouldAlert(criticalSince: Date?, alreadyAlerted: Bool, now: Date) -> Bool {
        guard let criticalSince, !alreadyAlerted else { return false }
        return now.timeIntervalSince(criticalSince) >= alertAfter
    }
}

// MARK: Lid sessions

/// One stretch of the lid being closed while clamshell mode kept the Mac awake.
public struct LidSession: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double?
    /// Last check that saw the session running; a long silence means sleep or a helper restart.
    public var lastSeen: Double
    public var maxTemperature: Double?
    public var maxThermal: Int
    public var batteryStart: Int?
    public var batteryEnd: Int?
    /// Tether turned Low Power Mode on during the session (heat guard or battery hold).
    public var lowPower: Bool
    /// Part of the session ran on battery (a battery hold).
    public var onBattery: Bool

    public init(start: Double, end: Double?, lastSeen: Double, maxTemperature: Double?, maxThermal: Int,
                batteryStart: Int?, batteryEnd: Int?, lowPower: Bool, onBattery: Bool) {
        self.start = start
        self.end = end
        self.lastSeen = lastSeen
        self.maxTemperature = maxTemperature
        self.maxThermal = maxThermal
        self.batteryStart = batteryStart
        self.batteryEnd = batteryEnd
        self.lowPower = lowPower
        self.onBattery = onBattery
    }

    public var duration: TimeInterval { (end ?? lastSeen) - start }

    /// Shorter sessions (closing the lid to carry the Mac across the room) are not reported.
    public static let minimumDuration: TimeInterval = 300
}

public struct SessionTracker: Codable, Equatable, Sendable {
    public var open: LidSession?

    /// Longest silence between checks that still counts as one session.
    public static let maxGap: TimeInterval = 120

    public init(open: LidSession? = nil) { self.open = open }

    /// Feed every check. Returns a finished session worth reporting when the lid opens,
    /// clamshell mode ends, or a gap shows the session was cut short.
    public mutating func update(lidClosed: Bool, clamshellOn: Bool, readings: SafetyReadings,
                                onBattery: Bool, lowPower: Bool, now: Date) -> LidSession? {
        let t = now.timeIntervalSince1970
        var finished: LidSession?
        if var current = open, t - current.lastSeen > Self.maxGap {
            current.end = current.lastSeen
            finished = current
            open = nil
        }
        if lidClosed && clamshellOn {
            var s = open ?? LidSession(start: t, end: nil, lastSeen: t, maxTemperature: nil, maxThermal: 0,
                                       batteryStart: readings.batteryPercent, batteryEnd: nil,
                                       lowPower: false, onBattery: false)
            s.lastSeen = t
            if let temperature = readings.temperature {
                s.maxTemperature = max(s.maxTemperature ?? temperature, temperature)
            }
            s.maxThermal = max(s.maxThermal, readings.thermal)
            s.batteryEnd = readings.batteryPercent ?? s.batteryEnd
            s.lowPower = s.lowPower || lowPower
            s.onBattery = s.onBattery || onBattery
            open = s
        } else if var current = open {
            current.end = t
            finished = current
            open = nil
        }
        guard let finished, finished.duration >= LidSession.minimumDuration else { return nil }
        return finished
    }
}

// MARK: Usage stats

/// Time-weighted battery temperatures: how long the pack spent at each whole degree.
public struct TempStats: Codable, Equatable, Sendable {
    public static let lowest = 20
    public static let bucketCount = 30  // 20...49 °C

    public var seconds: Double
    /// Sum of temperature × seconds, for the time-weighted average.
    public var weighted: Double
    public var max: Double?
    /// Seconds spent in each 1 °C bucket from `lowest`; the ends catch everything beyond.
    public var buckets: [Double]

    public init() {
        seconds = 0
        weighted = 0
        max = nil
        buckets = Array(repeating: 0, count: Self.bucketCount)
    }

    public mutating func add(_ temperature: Double, seconds step: Double) {
        guard step > 0 else { return }
        if buckets.count != Self.bucketCount { buckets = Array(repeating: 0, count: Self.bucketCount) }
        seconds += step
        weighted += temperature * step
        max = Swift.max(max ?? temperature, temperature)
        let index = Int(temperature.rounded(.down)) - Self.lowest
        buckets[Swift.min(Self.bucketCount - 1, Swift.max(0, index))] += step
    }

    public mutating func merge(_ other: TempStats) {
        guard other.seconds > 0 else { return }
        if buckets.count != Self.bucketCount { buckets = Array(repeating: 0, count: Self.bucketCount) }
        seconds += other.seconds
        weighted += other.weighted
        if let m = other.max { max = Swift.max(max ?? m, m) }
        for (i, value) in other.buckets.prefix(Self.bucketCount).enumerated() { buckets[i] += value }
    }

    public var average: Double? { seconds > 0 ? weighted / seconds : nil }

    /// The temperature the pack stayed at or below for fraction `p` of the time (the top of the
    /// bucket that reaches it, never above the peak seen).
    public func percentile(_ p: Double) -> Double? {
        guard seconds > 0, let max else { return nil }
        let target = seconds * Swift.min(1, Swift.max(0, p))
        var running = 0.0
        for (i, value) in buckets.enumerated() {
            running += value
            if running >= target { return Swift.min(Double(Self.lowest + i + 1), max) }
        }
        return max
    }
}

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
    /// Sleeps Tether forced: power pulled with the lid closed, a hold ending, "sleep now".
    public var forcedSleeps: Int
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

    public mutating func recordForcedSleep(now: Date, calendar: Calendar = .current) {
        edit(now, calendar) { $0.forcedSleeps += 1 }
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

// MARK: Sleep log

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

/// Written by the helper to `usage.json` (world-readable), read by the app and the CLI.
public struct Usage: Codable, Equatable, Sendable {
    public var stats: StatsTracker
    public var tracker: SessionTracker
    /// Finished sessions worth reporting, oldest first.
    public var recentSessions: [LidSession]
    /// Absent in files from before 1.10.
    public var sleepLog: SleepLog?

    public static let keepSessions = 10

    public init(stats: StatsTracker = StatsTracker(), tracker: SessionTracker = SessionTracker(),
                recentSessions: [LidSession] = [], sleepLog: SleepLog? = nil) {
        self.stats = stats
        self.tracker = tracker
        self.recentSessions = recentSessions
        self.sleepLog = sleepLog
    }

    public var sleeps: SleepLog {
        get { sleepLog ?? SleepLog() }
        set { sleepLog = newValue }
    }

    public mutating func add(_ session: LidSession) {
        recentSessions.append(session)
        if recentSessions.count > Self.keepSessions {
            recentSessions.removeFirst(recentSessions.count - Self.keepSessions)
        }
    }
}

// MARK: Commands (CLI and tether:// URLs)

public enum TetherCommand: Equatable, Sendable {
    case status, on, off, toggle, sleep, blank
    case hold(minutes: Int)
    case cancelHold

    /// `on`, `off`, `toggle`, `sleep`, `blank`, `hold 90m`, `hold off`, `status`.
    /// Returns nil for anything else, including a hold length outside 1 min–4 h.
    public static func parse(_ words: [String]) -> TetherCommand? {
        guard let first = words.first?.lowercased() else { return .status }
        switch first {
        case "status": return .status
        case "on", "enable": return .on
        case "off", "disable": return .off
        case "toggle": return .toggle
        case "sleep": return .sleep
        case "blank", "screen-off": return .blank
        case "hold":
            guard words.count >= 2 else { return nil }
            let argument = words[1...].joined().lowercased()
            if ["off", "cancel", "stop"].contains(argument) { return .cancelHold }
            return HoldDuration.minutes(argument).map { .hold(minutes: $0) }
        default: return nil
        }
    }

    /// `tether://sleep`, `tether://hold/90m`, `tether://hold?minutes=90`, `tether://hold/off`.
    public static func parse(url: URL) -> TetherCommand? {
        guard url.scheme?.lowercased() == "tether" else { return nil }
        var words = [url.host ?? ""] + url.pathComponents.filter { $0 != "/" }
        if let minutes = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "minutes" })?.value {
            words.append(minutes)
        }
        words = words.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return parse(words)
    }
}

public enum HoldDuration {
    /// Minutes from "90", "90m", "1h", "1h30m", "1.5h" or "1시간30분"; nil when it cannot be
    /// read or falls outside 1 minute to the 4-hour cap.
    public static func minutes(_ text: String) -> Int? {
        let t = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "시간", with: "h")
            .replacingOccurrences(of: "분", with: "m")
        if let plain = Int(t) { return valid(plain) }
        var total = 0.0
        var number = ""
        var sawUnit = false
        for ch in t {
            if ch.isNumber || ch == "." {
                number.append(ch)
                continue
            }
            guard let value = Double(number) else { return nil }
            switch ch {
            case "h": total += value * 60
            case "m": total += value
            default: return nil
            }
            number = ""
            sawUnit = true
        }
        guard number.isEmpty, sawUnit else { return nil }
        return valid(Int(total.rounded()))
    }

    private static func valid(_ minutes: Int) -> Int? {
        (1...Int(SafetyPolicy.maxHold / 60)).contains(minutes) ? minutes : nil
    }
}

// MARK: Control file client (menu bar app and CLI)

public enum ControlStore {
    public static func read(path: String = TetherPaths.controlPath) -> Control {
        JSONFile.read(Control.self, from: path) ?? Control()
    }

    /// Applies a change to the control file and nudges the helper. Returns false when it cannot
    /// be written, e.g. the helper was never installed so the folder does not exist.
    @discardableResult
    public static func update(path: String = TetherPaths.controlPath, _ change: (inout Control) -> Void) -> Bool {
        var control = read(path: path)
        change(&control)
        guard JSONFile.write(control, to: path, permissions: 0o664) else { return false }
        DarwinNotification.post(TetherPaths.controlChanged)
        return true
    }

    @discardableResult
    public static func setEnabled(_ on: Bool) -> Bool { update { $0.enabled = on } }

    @discardableResult
    public static func sleepNow() -> Bool { update { $0.sleepNowRequest = Date().timeIntervalSince1970 } }

    @discardableResult
    public static func startHold(minutes: Int) -> Bool {
        update { $0.batteryHoldUntil = Date().addingTimeInterval(TimeInterval(minutes * 60)).timeIntervalSince1970 }
    }

    @discardableResult
    public static func cancelHold() -> Bool { update { $0.batteryHoldUntil = nil } }
}

// MARK: Versions

public enum Version {
    /// Numeric dotted comparison: "2.0.10" is newer than "2.0.9"; missing parts count as 0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
