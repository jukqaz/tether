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
    /// Public OS low-battery warning, separate from the user's Low Power Mode setting.
    /// Nil means unavailable; the default preserves legacy deterministic fixtures.
    public var lowPowerWarning: Bool?
    /// Battery current in mA: negative while it drains, even on a charger that can't keep up.
    public var current: Int?

    public var isValid: Bool {
        // The model-specific Celsius sensor is diagnostic only. Public OS pressure and
        // charge are required; an unsupported optional sensor must not disable the product.
        guard let batteryPercent else { return false }
        return (0...100).contains(batteryPercent) && (0...3).contains(thermal)
    }

    public init(temperature: Double?, thermal: Int, batteryPercent: Int?, current: Int? = nil,
                lowPowerWarning: Bool? = false) {
        self.temperature = temperature?.isFinite == true ? temperature : nil
        self.thermal = thermal
        self.batteryPercent = batteryPercent
        self.current = current
        self.lowPowerWarning = lowPowerWarning
    }
}

/// Explicit user choices. macOS low-battery warnings and thermal protection are
/// independent; lowering a reserve never disables either OS signal.
public struct UserLimits: Codable, Equatable, Sendable {
    public var batteryFloor: Int?
    /// Legacy fields retained for decoding/backups only. New service requests reject them.
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

/// Public macOS thermal pressure plus a user-selected battery reserve and time allowance.
/// Celsius readings never determine the active policy. Old fields are decoded only for migration.
public enum SafetyPolicy {
    public static let maxHold: TimeInterval = 4 * 3600
    public static let batteryFloor = 20
    public static let resumeBatteryMargin = 5

    public static let highestFloor = 80
    public static let floorChoices = [5, 10, 15, 20, 25, 30, 40, 50]
    public static let maxHoldChoices: [Double] = [4, 3, 2, 1]

    public static func floor(_ user: UserLimits?) -> Int {
        // Preserve older, stricter reserves above the new selection list.
        min(highestFloor, max(5, user?.batteryFloor ?? batteryFloor))
    }

    public static func maxHold(_ user: UserLimits?) -> TimeInterval {
        guard let hours = user?.maxHoldHours, hours > 0 else { return maxHold }
        return min(maxHold, max(1800, hours * 3600))
    }

    /// Stop at serious or critical pressure without a temperature-derived grace period.
    /// Lid/grace arguments remain source-compatible for legacy clients; neither changes
    /// the OS-pressure policy. A keep-awake tool cannot diagnose chassis or battery health.
    public static func verdict(_ r: SafetyReadings, lidClosed: Bool, now: Date,
                               holdUntil: Date, warmSince: Date?, user: UserLimits? = nil) -> HoldEnd? {
        guard r.isValid else { return .sensor }
        if r.thermal >= 2 { return .thermal }
        guard let warning = r.lowPowerWarning else { return .sensor }
        if warning { return .battery }
        if let percent = r.batteryPercent, percent <= floor(user) { return .battery }
        if now >= holdUntil { return .time }
        return nil
    }

    /// A hold started at or below the floor would end at once.
    public static func canStartHold(batteryPercent: Int?, user: UserLimits? = nil,
                                    lowPowerWarning: Bool? = false) -> Bool {
        guard lowPowerWarning == false, let batteryPercent, (0...100).contains(batteryPercent) else { return false }
        return batteryPercent > floor(user)
    }

    /// Clamp a requested deadline to the maximum hold length.
    public static func clamp(_ until: Date, now: Date, maxHold: TimeInterval = SafetyPolicy.maxHold) -> Date {
        min(until, now.addingTimeInterval(min(maxHold, SafetyPolicy.maxHold)))
    }
}
