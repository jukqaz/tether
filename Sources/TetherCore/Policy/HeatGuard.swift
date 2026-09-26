import Foundation

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

/// Clamshell on AC with the lid shut still blocks the hinge vent. Remote sessions and long jobs
/// are why clamshell is on, so Tether first cools the Mac with Low Power Mode and raises an alert
/// when critical pressure persists. With no external display attached, the closed Mac may be in
/// a bag on a power bank, which macOS also reports as AC; there sustained critical pressure or a
/// hot battery puts it to sleep.
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

    /// Critical pressure this long puts a closed Mac with no external display to sleep.
    public static let sleepAfterCritical: TimeInterval = 120
    /// A battery this hot for `sleepAfterHot` does the same; it is above every battery-hold limit.
    public static let hotBattery: Double = 45
    public static let sleepAfterHot: TimeInterval = 60

    /// `criticalSince` and `hotSince`: when critical pressure and a battery at `hotBattery` or
    /// more began, nil while not the case.
    public static func shouldSleep(clamshellOn: Bool, onAC: Bool, lidClosed: Bool, externalDisplay: Bool,
                                   criticalSince: Date?, hotSince: Date?, now: Date) -> Bool {
        guard clamshellOn, onAC, lidClosed, !externalDisplay else { return false }
        if let criticalSince, now.timeIntervalSince(criticalSince) >= sleepAfterCritical { return true }
        if let hotSince, now.timeIntervalSince(hotSince) >= sleepAfterHot { return true }
        return false
    }
}
