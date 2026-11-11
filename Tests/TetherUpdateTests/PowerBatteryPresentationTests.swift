import XCTest
import TetherCore
@testable import Tether

final class PowerBatteryPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(current: Double? = 2_240, charging: Bool? = true,
                         external: Bool? = true, eta: Double? = 48,
                         adapter: Double? = 94) -> PowerBatteryReading {
        PowerBatteryReading(observedAt: now.addingTimeInterval(-2), source: .ac,
                            externalConnected: external, isCharging: charging,
                            batteryPercent: 62, voltageMV: 12_500, currentMA: current,
                            etaMinutes: eta, adapterReportedWatts: adapter,
                            temperatureC: 32, cycleCount: 50)
    }

    func testChargingNumbersAndChargerMeaningStaySeparateInBothLanguages() {
        for language in [Language.korean, .english] {
            let value = PowerBatteryPresentation(reading: reading(), phase: .fresh,
                                                 evaluatedAt: now, language: language)
            XCTAssertEqual(value.batteryRows.first?.value, "28.0 W")
            XCTAssertEqual(value.chargerRows.first?.value, "94 W")
            XCTAssertEqual(value.batteryRows.first?.prominent, true)
            XCTAssertEqual(value.chargerRows.first?.prominent, false)
            XCTAssertEqual(value.chargerRows.first?.title,
                           language == .korean ? "충전기 전력(보고값)" : "Charger-reported power")
            XCTAssertEqual(value.chargerNote, language == .korean
                ? "충전기가 보고한 값이며 실제 배터리 충전·방전 전력과 다릅니다."
                : "Reported by the charger; this differs from current battery charging or discharging power.")
            XCTAssertEqual(value.sensorRows.first?.title,
                           language == .korean ? "배터리 온도 · 충전 사이클" : "Battery temperature · Cycles")
            XCTAssertEqual(value.observedText, language == .korean ? "2초 전 확인" : "Checked 2 sec ago")
            XCTAssertEqual(value.batteryRows.first(where: { $0.id == "eta" })?.value,
                           language == .korean ? "약 48분" : "About 48 min")
        }
    }

    func testActualZeroDiffersFromMissingCurrentAndFailedAdapterLookup() {
        let zero = PowerBatteryPresentation(reading: reading(current: 0, charging: false), phase: .fresh,
                                            evaluatedAt: now, language: .english)
        XCTAssertEqual(zero.summary, "Not charging")
        XCTAssertEqual(zero.batteryRows.first?.value, "0.0 W")
        let missing = PowerBatteryPresentation(reading: reading(current: nil, charging: false, adapter: nil),
                                               phase: .fresh, evaluatedAt: now, language: .english)
        XCTAssertEqual(missing.summary, "Not charging")
        XCTAssertNil(missing.batteryRows.first(where: { $0.id == "net-power" }))
        XCTAssertEqual(missing.batteryRows.first?.id, "voltage")
        XCTAssertEqual(missing.chargerNote, "No charger-reported value")
        XCTAssertTrue(missing.chargerRows.isEmpty)
    }

    func testACDischargeUsesMagnitudeAndSignedCurrentWithoutInferringCause() {
        let value = PowerBatteryPresentation(reading: reading(current: -1_000, charging: false), phase: .fresh,
                                             evaluatedAt: now, language: .english)
        XCTAssertEqual(value.summary, "Discharging 12.5 W")
        XCTAssertEqual(value.batteryRows.first?.title, "Battery discharging power")
        XCTAssertEqual(value.batteryRows.first?.value, "12.5 W")
        XCTAssertEqual(value.batteryRows.first(where: { $0.id == "voltage-current" })?.value, "12.5 V · -1.00 A")
        XCTAssertNil(value.batteryRows.first(where: { $0.id == "eta" }))
        XCTAssertEqual(value.chargerRows.first?.value, "94 W")
    }

    func testZeroNetPowerDoesNotOverrideAnIndependentChargingFlag() {
        let value = PowerBatteryPresentation(reading: reading(current: 0), phase: .fresh,
                                             evaluatedAt: now, language: .english)
        XCTAssertEqual(value.summary, "Battery 0 W")
        XCTAssertEqual(value.batteryRows.first?.title, "Net battery power")
    }

    func testUnknownPowerCanStillShowKnownChargingFlagWithoutInventingWatts() {
        let value = PowerBatteryPresentation(reading: reading(current: nil), phase: .fresh,
                                             evaluatedAt: now, language: .korean)
        XCTAssertEqual(value.summary, "충전 중")
        XCTAssertFalse(value.batteryRows.contains(where: { $0.id == "net-power" }))
    }

    func testPendingStaleAndUnavailableNeverExposeOldNumericalRows() {
        for language in [Language.korean, .english] {
            for phase in [PowerBatteryPhase.pending, .stale, .unavailable] {
                let value = PowerBatteryPresentation(reading: reading(), phase: phase,
                                                     evaluatedAt: now, language: language)
                XCTAssertNotNil(value.message)
                XCTAssertTrue(value.batteryRows.isEmpty)
                XCTAssertTrue(value.chargerRows.isEmpty)
                XCTAssertTrue(value.sensorRows.isEmpty)
                XCTAssertNil(value.observedText)
                XCTAssertNil(value.chargerNote)
                if phase == .stale { XCTAssertTrue(value.message?.contains("2") == true) }
            }
        }
    }

    func testMissingReadingNeverAppearsFreshOrShowsAZero() {
        let value = PowerBatteryPresentation(reading: nil, phase: .fresh, evaluatedAt: now, language: .english)
        XCTAssertEqual(value.summary, "Unavailable")
        XCTAssertEqual(value.message, "Power information could not be read.")
        XCTAssertTrue(value.batteryRows.isEmpty)
    }

    func testETAUnknownSentinelsAndDisconnectedChargerAreNotEstimated() {
        for minutes in [nil, -1, 65_535, Double.nan, .infinity] as [Double?] {
            let value = PowerBatteryPresentation(reading: reading(external: false, eta: minutes), phase: .fresh,
                                                 evaluatedAt: now, language: .english)
            XCTAssertNil(value.batteryRows.first(where: { $0.id == "eta" }))
            XCTAssertEqual(value.chargerNote, "Not connected")
        }
    }

    func testUnavailableSensorsAreOmittedAndFutureAgeIsNotPresented() {
        let reading = PowerBatteryReading(observedAt: now.addingTimeInterval(1), source: .battery,
                                          temperatureC: nil, cycleCount: nil)
        let fresh = PowerBatteryPresentation(reading: reading, phase: .fresh, evaluatedAt: now, language: .english)
        XCTAssertTrue(fresh.sensorRows.isEmpty)
        XCTAssertNil(fresh.observedText)
        XCTAssertNotNil(fresh.batteryNote)
        let stale = PowerBatteryPresentation(reading: reading, phase: .stale, evaluatedAt: now, language: .english)
        XCTAssertEqual(stale.message, "Power information needs refreshing.")
    }

    func testExtremeFiniteValuesStayCompactRatherThanExpandingTheMenu() {
        let reading = PowerBatteryReading(observedAt: now, voltageMV: 1e100, currentMA: 1e100)
        let value = PowerBatteryPresentation(reading: reading, phase: .fresh, evaluatedAt: now, language: .english)
        XCTAssertEqual(value.batteryRows.first(where: { $0.id == "net-power" })?.value, "1.0e+194 W")
        XCTAssertEqual(value.batteryRows.first(where: { $0.id == "voltage-current" })?.value,
                       "1.0e+97 V · 1.0e+97 A")
        XCTAssertTrue(value.batteryRows.allSatisfy { $0.value.count < 40 })
    }

    func testNonzeroPowerBelowDisplayedPrecisionDoesNotAppearAsARealZero() {
        let value = PowerBatteryPresentation(reading: reading(current: -1, charging: false), phase: .fresh,
                                             evaluatedAt: now, language: .english)
        XCTAssertEqual(value.summary, "Discharging <0.1 W")
        XCTAssertEqual(value.batteryRows.first?.value, "<0.1 W")
    }
}
