import Foundation

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
