import Foundation

/// Why a battery hold ended. Every case ends in sleep when the lid is closed.
public enum HoldEnd: String, Codable, Sendable {
    case time, battery, heat, thermal, sensor, cancelled
}

public struct SafetyReadings: Equatable, Sendable {
    /// Battery pack temperature in °C, nil when it cannot be read.
    public var temperature: Double?
    /// ProcessInfo.ThermalState raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermal: Int
    public var batteryPercent: Int?

    public init(temperature: Double?, thermal: Int, batteryPercent: Int?) {
        self.temperature = temperature
        self.thermal = thermal
        self.batteryPercent = batteryPercent
    }
}

/// Temperature and thermal limits for one lid state.
public struct SafetyLimits: Equatable, Sendable {
    /// Ends the hold once it has held for `sustain` seconds; nil disables the early rule.
    public var earlyTemperature: Double?
    public var earlyThermal: Int?
    /// Ends the hold immediately.
    public var hardTemperature: Double
    public var hardThermal: Int
    public var sustain: TimeInterval
}

/// Limits the user chose in Settings. Applied only where they are stricter than the defaults,
/// so neither the app nor a hand-edited control file can loosen a limit.
public struct UserLimits: Codable, Equatable, Sendable {
    public var batteryFloor: Int?
    /// Battery temperature that ends a hold at once with the lid closed; the one-minute early
    /// limit moves down with it.
    public var closedLidMaxTemperature: Double?
    public var openLidMaxTemperature: Double?
    public var maxHoldHours: Double?

    public init(batteryFloor: Int? = nil, closedLidMaxTemperature: Double? = nil,
                openLidMaxTemperature: Double? = nil, maxHoldHours: Double? = nil) {
        self.batteryFloor = batteryFloor
        self.closedLidMaxTemperature = closedLidMaxTemperature
        self.openLidMaxTemperature = openLidMaxTemperature
        self.maxHoldHours = maxHoldHours
    }

    public var isDefault: Bool {
        batteryFloor == nil && closedLidMaxTemperature == nil && openLidMaxTemperature == nil && maxHoldHours == nil
    }
}

/// Limits for keeping a Mac awake on battery. A closed lid may mean a bag with no airflow, so
/// it is held to much stricter limits than an open, in-use Mac, whose own thermal management
/// is enough. The defaults are the loosest allowed; users can only tighten them.
public enum SafetyPolicy {
    public static let maxHold: TimeInterval = 4 * 3600
    public static let batteryFloor = 20

    public static let closedLid = SafetyLimits(earlyTemperature: 40, earlyThermal: 2,
                                               hardTemperature: 43, hardThermal: 3, sustain: 60)
    public static let openLid = SafetyLimits(earlyTemperature: nil, earlyThermal: nil,
                                             hardTemperature: 45, hardThermal: 3, sustain: 60)

    /// Below this a limit would end every hold at once, which helps nobody.
    public static let lowestTemperature: Double = 35
    public static let highestFloor = 80

    // What Settings offers, defaults first.
    public static let floorChoices = [20, 25, 30, 40, 50]
    public static let closedLidChoices: [Double] = [43, 42, 41, 40, 38]
    public static let openLidChoices: [Double] = [45, 44, 43, 42, 40]
    public static let maxHoldChoices: [Double] = [4, 3, 2, 1]

    public static func limits(lidClosed: Bool, user: UserLimits? = nil) -> SafetyLimits {
        var l = lidClosed ? closedLid : openLid
        guard let requested = lidClosed ? user?.closedLidMaxTemperature : user?.openLidMaxTemperature
        else { return l }
        let hard = min(l.hardTemperature, max(lowestTemperature, requested))
        let shift = l.hardTemperature - hard
        l.hardTemperature = hard
        l.earlyTemperature = l.earlyTemperature.map { $0 - shift }
        return l
    }

    public static func floor(_ user: UserLimits?) -> Int {
        min(highestFloor, max(batteryFloor, user?.batteryFloor ?? batteryFloor))
    }

    public static func maxHold(_ user: UserLimits?) -> TimeInterval {
        guard let hours = user?.maxHoldHours, hours > 0 else { return maxHold }
        return min(maxHold, max(1800, hours * 3600))
    }

    /// The early-warning condition, tracked by the caller to know how long it has held.
    public static func isWarm(_ r: SafetyReadings, lidClosed: Bool, user: UserLimits? = nil) -> Bool {
        let l = limits(lidClosed: lidClosed, user: user)
        let warmTemperature = l.earlyTemperature.map { (r.temperature ?? 0) >= $0 } ?? false
        let warmThermal = l.earlyThermal.map { r.thermal >= $0 } ?? false
        return warmTemperature || warmThermal
    }

    /// Returns why the hold must end now, or nil to keep holding. `warmSince` must be reset by
    /// the caller whenever the lid state changes, so a closing lid starts its own countdown.
    public static func verdict(_ r: SafetyReadings, lidClosed: Bool, now: Date,
                               holdUntil: Date, warmSince: Date?, user: UserLimits? = nil) -> HoldEnd? {
        guard let temperature = r.temperature else { return .sensor }  // fail safe
        let l = limits(lidClosed: lidClosed, user: user)
        if temperature >= l.hardTemperature { return .heat }
        if r.thermal >= l.hardThermal { return .thermal }
        if let warmSince, now.timeIntervalSince(warmSince) >= l.sustain,
           isWarm(r, lidClosed: lidClosed, user: user) {
            return (l.earlyTemperature.map { temperature >= $0 } ?? false) ? .heat : .thermal
        }
        if let percent = r.batteryPercent, percent <= floor(user) { return .battery }
        if now >= holdUntil { return .time }
        return nil
    }

    /// Clamp a requested deadline to the maximum hold length.
    public static func clamp(_ until: Date, now: Date, maxHold: TimeInterval = SafetyPolicy.maxHold) -> Date {
        min(until, now.addingTimeInterval(min(maxHold, SafetyPolicy.maxHold)))
    }
}
