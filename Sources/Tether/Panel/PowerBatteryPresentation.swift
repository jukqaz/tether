import Foundation
import TetherCore

/// Read-only wording and formatting. This projection never supplies input to
/// the work, unplug or protection policies.
struct PowerBatteryPresentation: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let value: String
        var prominent = false
    }

    let title: String
    let summary: String
    let message: String?
    let batteryTitle: String
    let batteryRows: [Row]
    let batteryNote: String?
    let chargerTitle: String
    let chargerRows: [Row]
    let chargerNote: String?
    let sensorRows: [Row]
    let observedText: String?

    init(reading: PowerBatteryReading?, phase: PowerBatteryPhase,
         evaluatedAt: Date, language: Language = Localization.current) {
        func text(_ english: String, _ korean: String) -> String {
            language == .korean ? korean : english
        }
        title = text("Power & battery", "전원·배터리 정보")
        batteryTitle = text("Battery", "배터리")
        chargerTitle = text("Charger", "충전기")
        let age = reading.flatMap { Self.age(observedAt: $0.observedAt, evaluatedAt: evaluatedAt) }
        let effectivePhase: PowerBatteryPhase = phase == .fresh && reading == nil ? .unavailable : phase
        guard effectivePhase == .fresh, let reading else {
            switch effectivePhase {
            case .pending:
                summary = text("Checking again", "다시 확인 중")
                message = text("Checking power information again.", "전원 정보를 다시 확인하고 있습니다.")
            case .stale:
                summary = text("Outdated information", "오래된 정보")
                if let age {
                    message = text("Reading from \(age) sec ago · Refresh needed", "\(age)초 전 정보 · 다시 확인 필요")
                } else {
                    message = text("Power information needs refreshing.", "전원 정보를 다시 확인해야 합니다.")
                }
            case .unavailable, .fresh:
                summary = text("Unavailable", "정보 없음")
                message = text("Power information could not be read.", "전원 정보를 가져오지 못했습니다.")
            }
            batteryRows = []; batteryNote = nil
            chargerRows = []; chargerNote = nil
            sensorRows = []; observedText = nil
            return
        }

        message = nil
        if let watts = reading.netWatts, reading.flow == .charging || reading.flow == .discharging {
            summary = text(reading.flow == .charging ? "Charging" : "Discharging",
                           reading.flow == .charging ? "충전" : "방전") + " \(Self.power(abs(watts), compact: true)) W"
        } else if reading.isCharging == false, reading.source == .ac {
            summary = text("Not charging", "충전 안 함")
        } else if reading.flow == .idle {
            // Zero net flow alone does not establish the OS charging flag.
            summary = text("Battery 0 W", "배터리 0 W")
        } else if reading.isCharging == true {
            summary = text("Charging", "충전 중")
        } else {
            summary = text("Unavailable", "정보 없음")
        }

        var battery: [Row] = []
        if let watts = reading.netWatts {
            let label: String
            switch reading.flow {
            case .charging: label = text("Battery charging power", "배터리 충전 전력")
            case .discharging: label = text("Battery discharging power", "배터리 방전 전력")
            case .idle, .unknown: label = text("Net battery power", "배터리 측 전력")
            }
            battery.append(Row(id: "net-power", title: label,
                               value: "\(Self.power(abs(watts))) W", prominent: true))
        }
        switch (reading.voltageV, reading.currentA) {
        case let (.some(voltage), .some(current)):
            battery.append(Row(id: "voltage-current", title: text("Voltage · Current", "전압 · 전류"),
                               value: "\(Self.number(voltage, digits: 1)) V · \(Self.number(current, digits: 2)) A"))
        case let (.some(voltage), .none):
            battery.append(Row(id: "voltage", title: text("Voltage", "전압"),
                               value: "\(Self.number(voltage, digits: 1)) V"))
        case let (.none, .some(current)):
            battery.append(Row(id: "current", title: text("Current", "전류"),
                               value: "\(Self.number(current, digits: 2)) A"))
        case (.none, .none): break
        }
        if let minutes = reading.etaMinutes {
            let value = Self.number(minutes.rounded(), digits: 0)
            battery.append(Row(id: "eta", title: text("Time until full", "완충 예상"),
                               value: text("About \(value) min", "약 \(value)분")))
        }
        batteryRows = battery
        batteryNote = battery.isEmpty
            ? text("Battery power readings are unavailable.", "배터리 전력 정보가 없습니다.") : nil

        if reading.adapterState == .reported, let watts = reading.adapterReportedWatts {
            chargerRows = [Row(id: "reported-adapter-power", title: text("Charger-reported power", "충전기 전력(보고값)"),
                               value: "\(Self.number(watts, digits: 1, compact: true)) W")]
            chargerNote = text("Reported by the charger; this differs from current battery charging or discharging power.",
                               "충전기가 보고한 값이며 실제 배터리 충전·방전 전력과 다릅니다.")
        } else {
            chargerRows = []
            chargerNote = reading.adapterState == .disconnected
                ? text("Not connected", "연결 안 됨") : text("No charger-reported value", "충전기 보고값 없음")
        }

        var sensors: [Row] = []
        switch (reading.temperatureC, reading.cycleCount) {
        case let (.some(temperature), .some(cycles)):
            sensors.append(Row(id: "temperature-cycles", title: text("Battery temperature · Cycles", "배터리 온도 · 충전 사이클"),
                               value: "\(Self.number(temperature, digits: 1, compact: true)) °C · \(cycles)\(text("", "회"))"))
        case let (.some(temperature), .none):
            sensors.append(Row(id: "temperature", title: text("Battery temperature", "배터리 온도"),
                               value: "\(Self.number(temperature, digits: 1, compact: true)) °C"))
        case let (.none, .some(cycles)):
            sensors.append(Row(id: "cycles", title: text("Charge cycles", "충전 사이클"), value: "\(cycles)\(text("", "회"))"))
        case (.none, .none): break
        }
        sensorRows = sensors
        observedText = age.map { text("Checked \($0) sec ago", "\($0)초 전 확인") }
    }

    private static func age(observedAt: Date, evaluatedAt: Date) -> Int? {
        let seconds = evaluatedAt.timeIntervalSince(observedAt)
        guard seconds.isFinite, seconds >= 0, seconds <= Double(Int.max / 2) else { return nil }
        return Int(seconds.rounded(.down))
    }

    private static func number(_ value: Double, digits: Int, compact: Bool = false) -> String {
        // A malformed-but-finite sensor value must not produce hundreds of
        // fixed decimal digits and force the menu beyond its logical width.
        let format = abs(value) >= 100_000 ? "%.1e" : "%.*f"
        // Foundation's locale-aware formatter can uppercase the exponent
        // despite %.1e. Keep this compact notation stable across locales.
        let rendered = format == "%.1e"
            ? String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
                .replacingOccurrences(of: "E", with: "e")
            : String(format: format, locale: Locale(identifier: "en_US_POSIX"), digits, value)
        return compact && rendered.hasSuffix(".0") ? String(rendered.dropLast(2)) : rendered
    }

    private static func power(_ magnitude: Double, compact: Bool = false) -> String {
        // Keep a real zero distinct from a nonzero reading below the displayed
        // precision. In particular, do not label a small discharge as 0 W.
        magnitude > 0 && magnitude < 0.1 ? "<0.1" : number(magnitude, digits: 1, compact: compact)
    }
}
