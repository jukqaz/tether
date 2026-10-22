import Foundation

/// A confirmed AC departure is handled once, before any automatic evaluation.
public enum WorkSessionDisconnectPolicy: String, Codable, CaseIterable, Sendable {
    case endAll, endAutomatic, continueEligible
}

/// Captured when a request/automatic activation is created. Changing a default
/// cannot refill a live request's first battery allowance.
public enum WorkSessionBatteryLimit: String, Codable, CaseIterable, Sendable {
    case thirtyMinutes, oneHour, twoHours, fourHours, unlimited
    public var seconds: Double? {
        switch self {
        case .thirtyMinutes: return 1800
        case .oneHour: return 3600
        case .twoHours: return 7200
        case .fourHours: return 14400
        case .unlimited: return nil
        }
    }
}

extension PowerCondition {
    public func permits(_ power: PowerSource) -> Bool {
        switch power {
        case .ac: return includesAC
        case .battery: return includesBattery
        case .unknown: return false
        }
    }
}

/// Relevant facts have independent stability windows. A Sleep, an explicit
/// unknown, or a sampling gap longer than 15s breaks the relevant window.
struct ProtectionRecoveryWindow: Equatable, Sendable {
    static let duration: Double = 60
    private(set) var thermalSince: Double?
    private(set) var powerSince: Double?
    private var lastThermalSample: Double?
    private var lastPowerSample: Double?
    private var power: PowerSource = .unknown

    mutating func observe(now: Double, thermal: Int?, power: PowerSource, battery: Int?,
                          floor: Int, lowWarning: Bool?, lowMode: Bool?, stopOnLowMode: Bool) {
        guard now.isFinite else { reset(); return }
        let thermalHealthy = thermal.map { (0...1).contains($0) } == true
        if !thermalHealthy || lastThermalSample.map({ now < $0 || now - $0 > 15 }) == true {
            thermalSince = nil
        }
        if thermalHealthy { thermalSince = thermalSince ?? now }
        lastThermalSample = thermalHealthy ? now : nil
        let powerHealthy = (!stopOnLowMode || lowMode == false) && (power == .ac
            || (power == .battery && lowWarning == false
                && battery.map { (0...100).contains($0) && $0 >= floor + 5 } == true))
        if !powerHealthy || self.power != power
            || lastPowerSample.map({ now < $0 || now - $0 > 15 }) == true { powerSince = nil }
        if powerHealthy { powerSince = powerSince ?? now }
        self.power = power
        lastPowerSample = powerHealthy ? now : nil
    }
    func isReady(now: Double) -> Bool {
        guard let thermalSince, let powerSince, let lastThermalSample, let lastPowerSample else { return false }
        return now >= thermalSince + Self.duration && now >= powerSince + Self.duration
            && now >= lastThermalSample && now - lastThermalSample <= 15
            && now >= lastPowerSample && now - lastPowerSample <= 15
    }
    mutating func reset() {
        thermalSince = nil; powerSince = nil; lastThermalSample = nil; lastPowerSample = nil; power = .unknown
    }
}
