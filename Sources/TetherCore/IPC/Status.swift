import Foundation

/// Written by the helper, read by the menu bar app.
public struct Status: Codable, Equatable, Sendable {
    public var updatedAt: Double
    public var version: String
    public var enabled: Bool
    public var power: PowerSource
    public var lidClosed: Bool
    public var sleepDisabled: Bool
    public var lastEvent: EventKind?
    public var lastEventAt: Double?
    /// Effective battery hold deadline, nil when no hold is armed.
    public var batteryHoldUntil: Double?
    public var batteryTemperature: Double?
    public var thermal: Int?
    public var batteryPercent: Int?
    /// The most recent end of a battery hold, kept apart from `lastEvent` (which the sleep
    /// that follows overwrites) so the app can report it after wake.
    public var lastHoldEnd: HoldEnd?
    public var lastHoldEndAt: Double?
    /// When the armed hold was first seen (the start of its countdown).
    public var batteryHoldSince: Double?
    /// The heat guard has Low Power Mode on (lid closed on AC, running hot).
    public var heatGuard: Bool?
    /// The most recent "critical for 3 minutes" alert, for the app to notify once.
    public var thermalAlertAt: Double?
    /// When overheating on AC with the lid closed put the Mac to sleep; the app reports it after wake.
    public var overheatSleepAt: Double?
    /// When a charger that couldn't keep up let the battery reach the floor and the Mac was put to sleep.
    public var weakChargerSleepAt: Double?

    private enum CodingKeys: String, CodingKey {
        case updatedAt, version, enabled, power, lidClosed, sleepDisabled, lastEvent, lastEventAt
        case batteryHoldUntil, batteryTemperature, thermal, batteryPercent, lastHoldEnd, lastHoldEndAt
        case batteryHoldSince, heatGuard, thermalAlertAt, overheatSleepAt, weakChargerSleepAt
    }

    /// Tolerates an event this build does not know, so an app and helper from different
    /// versions still read each other's status.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        version = try c.decode(String.self, forKey: .version)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        power = (try? c.decode(PowerSource.self, forKey: .power)) ?? .unknown
        lidClosed = try c.decode(Bool.self, forKey: .lidClosed)
        sleepDisabled = try c.decode(Bool.self, forKey: .sleepDisabled)
        lastEvent = try? c.decodeIfPresent(EventKind.self, forKey: .lastEvent)
        lastEventAt = try c.decodeIfPresent(Double.self, forKey: .lastEventAt)
        batteryHoldUntil = try? c.decodeIfPresent(Double.self, forKey: .batteryHoldUntil)
        batteryTemperature = try? c.decodeIfPresent(Double.self, forKey: .batteryTemperature)
        thermal = try? c.decodeIfPresent(Int.self, forKey: .thermal)
        batteryPercent = try? c.decodeIfPresent(Int.self, forKey: .batteryPercent)
        lastHoldEnd = try? c.decodeIfPresent(HoldEnd.self, forKey: .lastHoldEnd)
        lastHoldEndAt = try? c.decodeIfPresent(Double.self, forKey: .lastHoldEndAt)
        batteryHoldSince = try? c.decodeIfPresent(Double.self, forKey: .batteryHoldSince)
        heatGuard = try? c.decodeIfPresent(Bool.self, forKey: .heatGuard)
        thermalAlertAt = try? c.decodeIfPresent(Double.self, forKey: .thermalAlertAt)
        overheatSleepAt = try? c.decodeIfPresent(Double.self, forKey: .overheatSleepAt)
        weakChargerSleepAt = try? c.decodeIfPresent(Double.self, forKey: .weakChargerSleepAt)
    }

    public init(updatedAt: Double, version: String, enabled: Bool, power: PowerSource,
                lidClosed: Bool, sleepDisabled: Bool, lastEvent: EventKind?, lastEventAt: Double?,
                batteryHoldUntil: Double? = nil, batteryTemperature: Double? = nil,
                thermal: Int? = nil, batteryPercent: Int? = nil) {
        self.updatedAt = updatedAt
        self.version = version
        self.enabled = enabled
        self.power = power
        self.lidClosed = lidClosed
        self.sleepDisabled = sleepDisabled
        self.lastEvent = lastEvent
        self.lastEventAt = lastEventAt
        self.batteryHoldUntil = batteryHoldUntil
        self.batteryTemperature = batteryTemperature
        self.thermal = thermal
        self.batteryPercent = batteryPercent
    }
}

public enum EventKind: String, Codable, Sendable {
    case started, clamshellOn, clamshellOffPower, clamshellOffDisabled, clamshellOffSleepNow
    case lidSleep, sleepNow, sleepRefused, stopping
    case holdOnBattery, holdEndedTime, holdEndedBattery, holdEndedHeat, holdEndedThermal
    case holdEndedSensor, holdCancelled
    case heatGuardOn, heatGuardOff, heatCritical, overheatSleep, weakChargerSleep

    public static func holdEnded(_ reason: HoldEnd) -> EventKind {
        switch reason {
        case .time: .holdEndedTime
        case .battery: .holdEndedBattery
        case .heat: .holdEndedHeat
        case .thermal: .holdEndedThermal
        case .sensor: .holdEndedSensor
        case .cancelled: .holdCancelled
        }
    }

    /// Events that end in sleep with the lid closed; the app reports them after wake.
    public var isHoldEnd: Bool {
        switch self {
        case .holdEndedTime, .holdEndedBattery, .holdEndedHeat, .holdEndedThermal, .holdEndedSensor: true
        default: false
        }
    }

    public var logText: String {
        switch self {
        case .started: "helper started"
        case .clamshellOn: "on power: clamshell on"
        case .clamshellOffPower: "power disconnected: clamshell off"
        case .clamshellOffDisabled: "Tether turned off: clamshell off"
        case .clamshellOffSleepNow: "sleep now: clamshell off"
        case .lidSleep: "lid already closed: sleeping"
        case .sleepNow: "sleep now requested"
        case .sleepRefused: "sleep refused by the system: fell back to pmset sleepnow"
        case .stopping: "helper stopping: clamshell off"
        case .holdOnBattery: "on battery with a battery hold: clamshell kept"
        case .holdEndedTime: "battery hold ended: time is up"
        case .holdEndedBattery: "battery hold ended: battery at the floor"
        case .holdEndedHeat: "battery hold ended: battery too hot"
        case .holdEndedThermal: "battery hold ended: system thermal pressure"
        case .holdEndedSensor: "battery hold ended: battery temperature unreadable"
        case .holdCancelled: "battery hold cancelled"
        case .heatGuardOn: "lid closed on AC and running hot: Low Power Mode on"
        case .heatGuardOff: "heat guard released: Low Power Mode restored"
        case .heatCritical: "lid closed on AC: critical thermal pressure for 3 minutes"
        case .overheatSleep: "lid closed on AC with no external display and overheating: putting the Mac to sleep"
        case .weakChargerSleep: "lid closed on a charger that can't keep up, battery at the floor and draining: putting the Mac to sleep"
        }
    }
}
