import Foundation

/// A week of measurements, summarised for the settings window.
public struct UsageSummary: Equatable, Sendable {
    public var closed = TempStats()
    public var open = TempStats()
    public var holdSeconds: Double = 0
    public var holdDrain: Double = 0
    public var closedMaxThermal = 0
    public var heatGuards = 0
    public var lidClosedSeconds: Double = 0
    public var sessions: [LidSession] = []

    public init(week: [DayStats], sessions: [LidSession]) {
        for day in week {
            if let c = day.closedTemps { closed.merge(c) }
            if let o = day.openTemps { open.merge(o) }
            holdSeconds += day.holdSeconds ?? 0
            holdDrain += day.holdDrain ?? 0
            closedMaxThermal = max(closedMaxThermal, day.closedMaxThermal ?? 0)
            heatGuards += day.heatGuards
            lidClosedSeconds += day.lidClosedSeconds
        }
        self.sessions = sessions
    }

    /// Percentage points per hour while a hold kept the Mac awake on battery; needs 15 minutes.
    public var drainPerHour: Double? {
        guard holdSeconds >= 900, holdDrain > 0 else { return nil }
        return holdDrain / (holdSeconds / 3600)
    }

    /// Median lid session, once there are a few.
    public var typicalSession: TimeInterval? {
        let durations = sessions.map(\.duration).sorted()
        guard durations.count >= 3 else { return nil }
        return durations[durations.count / 2]
    }
}

public struct Advice<Value: Equatable & Sendable>: Equatable, Sendable {
    public var value: Value
    /// What in the data led here, e.g. "덮개를 닫았을 때 대부분 34°C 이하".
    public var reason: String
}

/// Recommendations from the user's own measurements. They only pick among the choices Settings
/// offers, so they are never looser than the defaults.
public enum Advisor {
    /// Enough time measured to trust a percentile.
    public static let minimumClosed: TimeInterval = 1800
    public static let minimumOpen: TimeInterval = 3600
    /// Headroom above the usual peak: ordinary use never trips the limit, a bag soon does.
    public static let headroom: Double = 4

    public static func closedLidLimit(_ s: UsageSummary) -> Advice<Double>? {
        guard s.closed.seconds >= minimumClosed, let usual = s.closed.percentile(0.95) else { return nil }
        return Advice(value: pick(SafetyPolicy.closedLidChoices, atLeast: usual + headroom),
                      reason: L("lid closed: usually \(Int(usual.rounded()))°C or less",
                                "덮개를 닫았을 때 대부분 \(Int(usual.rounded()))°C 이하"))
    }

    public static func openLidLimit(_ s: UsageSummary) -> Advice<Double>? {
        guard s.open.seconds >= minimumOpen, let usual = s.open.percentile(0.95) else { return nil }
        return Advice(value: pick(SafetyPolicy.openLidChoices, atLeast: usual + headroom),
                      reason: L("lid open: usually \(Int(usual.rounded()))°C or less",
                                "덮개를 열었을 때 대부분 \(Int(usual.rounded()))°C 이하"))
    }

    /// The longest hold that fits between the usual starting charge (full, unless battery
    /// sessions show otherwise) and the floor at the measured drain.
    public static func maxHold(_ s: UsageSummary, floor: Int) -> Advice<Double>? {
        guard let rate = s.drainPerHour else { return nil }
        let starts = s.sessions.filter(\.onBattery).compactMap(\.batteryStart)
        let start = starts.isEmpty ? 100 : Double(starts.reduce(0, +)) / Double(starts.count)
        let hours = (start - Double(floor)) / rate
        let choices = SafetyPolicy.maxHoldChoices.sorted()
        return Advice(value: choices.last { $0 <= hours } ?? choices.first ?? 1,
                      reason: L("a battery hold uses about \(Int(rate.rounded()))% an hour",
                                "배터리 유지 중 시간당 약 \(Int(rate.rounded()))% 사용"))
    }

    public static func heatGuardLevel(_ s: UsageSummary) -> Advice<Int>? {
        guard s.lidClosedSeconds >= minimumClosed else { return nil }
        if s.heatGuards >= 3 || s.closedMaxThermal >= 3 {
            return Advice(value: 1, reason: L("it often ran hot with the lid closed", "덮개를 닫고 자주 뜨거워졌어요"))
        }
        return Advice(value: 2, reason: L("it stayed cool with the lid closed", "덮개를 닫아도 발열이 높지 않았어요"))
    }

    /// The smallest choice at or above `target`, or the loosest one (the default) if none is.
    static func pick(_ choices: [Double], atLeast target: Double) -> Double {
        choices.sorted().first { $0 >= target } ?? choices.max() ?? target
    }
}
