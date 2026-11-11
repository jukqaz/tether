import Foundation
import TetherCore

/// Fixed, explicitly illustrative inputs for preview renderers and private UI tests.
/// No collector, installed helper, or native keep-awake request is involved.
@MainActor
enum PowerBatterySample {
    static let cases = ["charging", "discharging", "connected-idle", "ac-discharging", "requery", "stale", "partial"]

    static func monitor(scenario: String = "charging", now: Date = Date()) -> PowerBatteryMonitor {
        let monitor = PowerBatteryMonitor(simulated: true)
        configure(monitor, scenario: scenario, now: now)
        return monitor
    }

    static func configure(_ monitor: PowerBatteryMonitor, scenario: String, now: Date = Date()) {
        let date = now.addingTimeInterval(scenario == "stale" ? -35 : -2)
        var reading: PowerBatteryReading
        switch scenario {
        case "discharging":
            reading = .init(observedAt: date, source: .battery, externalConnected: false, isCharging: false,
                batteryPercent: 42, voltageMV: 12_000, currentMA: -1_000, temperatureC: 33, cycleCount: 50)
        case "connected-idle":
            reading = .init(observedAt: date, source: .ac, externalConnected: true, isCharging: false,
                batteryPercent: 80, voltageMV: 12_400, currentMA: 0, etaMinutes: 65_535,
                adapterReportedWatts: 94, cycleCount: 50)
        case "ac-discharging":
            reading = .init(observedAt: date, source: .ac, externalConnected: true, isCharging: false,
                batteryPercent: 61, voltageMV: 12_000, currentMA: -500,
                adapterReportedWatts: 30, temperatureC: 32, cycleCount: 50)
        case "partial":
            reading = .init(observedAt: date, source: .ac, externalConnected: true, isCharging: false,
                batteryPercent: 80, voltageMV: 12_500, cycleCount: 50)
        default:
            reading = .init(observedAt: date, source: .ac, externalConnected: true, isCharging: true,
                batteryPercent: 62, voltageMV: 12_500, currentMA: 2_240, etaMinutes: 48,
                adapterReportedWatts: 94, temperatureC: 32, cycleCount: 50)
        }
        monitor.setFixture(reading: scenario == "requery" ? nil : reading,
            phase: scenario == "requery" ? .pending : scenario == "stale" ? .stale : .fresh,
            evaluatedAt: now)
    }
}
