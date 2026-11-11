import Foundation

/// Read-only information for the power-details UI. These values never replace
/// SafetyReadings or the raw current used by keep-awake and charger policies.
public struct PowerBatteryReading: Equatable, Sendable {
    public enum Flow: String, Equatable, Sendable { case charging, discharging, idle, unknown }
    public enum AdapterState: String, Equatable, Sendable { case reported, disconnected, unavailable }

    public let observedAt: Date
    public let source: PowerSource
    public let externalConnected: Bool?
    public let isCharging: Bool?
    public let isCharged: Bool?
    public let batteryPercent: Int?
    public let voltageMV: Double?
    public let currentMA: Double?
    public let etaMinutes: Double?
    public let adapterReportedWatts: Double?
    public let temperatureC: Double?
    public let cycleCount: Int?

    public init(observedAt: Date = Date(), source: PowerSource = .unknown,
                externalConnected: Bool? = nil, isCharging: Bool? = nil, isCharged: Bool? = nil,
                batteryPercent: Int? = nil, voltageMV: Double? = nil, currentMA: Double? = nil,
                etaMinutes: Double? = nil, adapterReportedWatts: Double? = nil,
                temperatureC: Double? = nil, cycleCount: Int? = nil) {
        self.observedAt = observedAt
        self.externalConnected = externalConnected
        self.source = externalConnected.map { $0 ? .ac : .battery } ?? source
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.batteryPercent = batteryPercent.flatMap { (0...100).contains($0) ? $0 : nil }
        self.voltageMV = Self.finite(voltageMV).flatMap { $0 > 0 ? $0 : nil }
        self.currentMA = Self.finite(currentMA)
        self.etaMinutes = Self.finite(etaMinutes).flatMap {
            isCharging == true && $0 >= 0 && $0 < 65_535 ? $0 : nil
        }
        self.adapterReportedWatts = Self.finite(adapterReportedWatts).flatMap {
            externalConnected == true && $0 > 0 ? $0 : nil
        }
        self.temperatureC = Self.finite(temperatureC).flatMap { (0...80).contains($0) ? $0 : nil }
        self.cycleCount = cycleCount.flatMap { $0 >= 0 ? $0 : nil }
    }

    public var voltageV: Double? { voltageMV.map { $0 / 1_000 } }
    public var currentA: Double? { currentMA.map { $0 / 1_000 } }
    public var netWatts: Double? {
        guard let voltageMV, let currentMA else { return nil }
        return Self.finite(voltageMV * currentMA / 1_000_000).map { $0 == 0 ? 0 : $0 }
    }
    public var flow: Flow {
        guard let netWatts else { return .unknown }
        return netWatts > 0 ? .charging : netWatts < 0 ? .discharging : .idle
    }
    public var adapterState: AdapterState {
        if externalConnected == false { return .disconnected }
        return adapterReportedWatts != nil ? .reported : .unavailable
    }

    private static func finite(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? $0 : nil }
    }
}
