import Foundation
import IOKit.ps
import XCTest
@testable import TetherCore

final class PowerBatteryReadingTests: XCTestCase {
    private let observed = Date(timeIntervalSince1970: 1_000)

    private func decode(_ description: [String: Any] = [:], battery: [String: Any]? = nil,
                        pack: [String: Any]? = nil, adapter: [String: Any]? = nil,
                        source: String? = nil) -> PowerBatteryReading {
        SystemProbe.decodePowerBatteryReading(description: description, batteryProperties: battery,
            packProperties: pack, adapterDetails: adapter, providingSource: source, observedAt: observed)
    }

    func testSignedBatteryPowerIsIndependentOfAdapterAndChargingFlag() {
        let reading = decode([kIOPSVoltageKey: 12_000, kIOPSCurrentKey: -500,
                              kIOPSIsChargingKey: false, kIOPSTimeToFullChargeKey: 48],
                             battery: ["ExternalConnected": true], adapter: [kIOPSPowerAdapterWattsKey: 30],
                             source: kIOPSACPowerValue)
        XCTAssertEqual(reading.source, .ac)
        XCTAssertEqual(reading.isCharging, false)
        XCTAssertEqual(reading.netWatts, -6)
        XCTAssertEqual(reading.flow, .discharging)
        XCTAssertEqual(reading.voltageV, 12)
        XCTAssertEqual(reading.currentA, -0.5)
        XCTAssertEqual(reading.adapterReportedWatts, 30)
        XCTAssertNil(reading.etaMinutes)
        XCTAssertEqual(reading.observedAt, observed)
    }

    func testChargingConversionPreservesRawPrecision() {
        let reading = PowerBatteryReading(externalConnected: true, isCharging: true,
            voltageMV: 12_500, currentMA: 2_240, etaMinutes: 48, adapterReportedWatts: 94)
        XCTAssertEqual(reading.netWatts, 28)
        XCTAssertEqual(reading.voltageV, 12.5)
        XCTAssertEqual(reading.currentA, 2.24)
        XCTAssertEqual(reading.flow, .charging)
        XCTAssertEqual(reading.etaMinutes, 48)
        XCTAssertEqual(reading.adapterState, .reported)
    }

    func testMissingCurrentIsNotAZeroMeasurement() {
        let partial = decode([kIOPSVoltageKey: 12_500], battery: ["ExternalConnected": true])
        XCTAssertEqual(partial.voltageV, 12.5)
        XCTAssertNil(partial.currentMA)
        XCTAssertNil(partial.netWatts)
        XCTAssertEqual(partial.flow, .unknown)
        XCTAssertEqual(partial.adapterState, .unavailable)
        let idle = PowerBatteryReading(isCharging: false, voltageMV: 12_400, currentMA: 0)
        XCTAssertEqual(idle.netWatts, 0)
        XCTAssertEqual(idle.flow, .idle)
    }

    func testAdapterLookupFailureDoesNotMeanDisconnected() {
        let ac = decode(battery: ["ExternalConnected": true], adapter: nil, source: kIOPSACPowerValue)
        XCTAssertEqual(ac.source, .ac)
        XCTAssertEqual(ac.adapterState, .unavailable)
        XCTAssertNil(ac.adapterReportedWatts)
        let unknown = decode(source: kIOPSBatteryPowerValue)
        XCTAssertEqual(unknown.source, .battery)
        XCTAssertNil(unknown.externalConnected)
        XCTAssertEqual(unknown.adapterState, .unavailable)
        let unplugged = decode(battery: ["ExternalConnected": false], adapter: [kIOPSPowerAdapterWattsKey: 94])
        XCTAssertEqual(unplugged.source, .battery)
        XCTAssertEqual(unplugged.adapterState, .disconnected)
        XCTAssertNil(unplugged.adapterReportedWatts)
    }

    func testAdapterPresenceCanConfirmConnectionWithoutRegistryFlag() {
        let reading = decode(adapter: [kIOPSPowerAdapterWattsKey: 65], source: kIOPSBatteryPowerValue)
        XCTAssertEqual(reading.externalConnected, true)
        XCTAssertEqual(reading.source, .ac)
        XCTAssertEqual(reading.adapterReportedWatts, 65)
    }

    func testMissingOrInvalidNumericValuesStayUnavailable() {
        for invalid: Any in [true, false, "12000", NSNull(), Double.nan, Double.infinity, -Double.infinity] {
            let reading = decode([kIOPSVoltageKey: invalid, kIOPSCurrentKey: invalid,
                                  kIOPSCurrentCapacityKey: invalid, kIOPSMaxCapacityKey: 100,
                                  kIOPSTimeToFullChargeKey: invalid, kIOPSIsChargingKey: true],
                                 battery: ["ExternalConnected": true, "CycleCount": invalid],
                                 adapter: [kIOPSPowerAdapterWattsKey: invalid])
            XCTAssertNil(reading.voltageMV, "\(invalid)")
            XCTAssertNil(reading.currentMA, "\(invalid)")
            XCTAssertNil(reading.netWatts, "\(invalid)")
            XCTAssertNil(reading.batteryPercent, "\(invalid)")
            XCTAssertNil(reading.cycleCount, "\(invalid)")
            XCTAssertNil(reading.etaMinutes, "\(invalid)")
            XCTAssertNil(reading.adapterReportedWatts, "\(invalid)")
        }
    }

    func testNumericBooleansAreNotChargingOrConnectionFlags() {
        for invalid: Any in [0, 1, "true", "false", NSNull()] {
            let reading = decode([kIOPSIsChargingKey: invalid, kIOPSIsChargedKey: invalid],
                                 battery: ["ExternalConnected": invalid, "IsCharging": invalid])
            XCTAssertNil(reading.externalConnected)
            XCTAssertNil(reading.isCharging)
            XCTAssertNil(reading.isCharged)
        }
        let reading = decode([kIOPSIsChargingKey: true, kIOPSIsChargedKey: false])
        XCTAssertEqual(reading.isCharging, true)
        XCTAssertEqual(reading.isCharged, false)
    }

    func testETARequiresConfirmedChargingAndValidNonnegativeEstimate() {
        for invalid in [-1.0, 65_535, 65_536, Double.nan, Double.infinity] {
            XCTAssertNil(PowerBatteryReading(isCharging: true, etaMinutes: invalid).etaMinutes)
        }
        XCTAssertNil(PowerBatteryReading(isCharging: nil, etaMinutes: 48).etaMinutes)
        XCTAssertNil(PowerBatteryReading(isCharging: false, etaMinutes: 48).etaMinutes)
        XCTAssertEqual(PowerBatteryReading(isCharging: true, etaMinutes: 0).etaMinutes, 0)
        XCTAssertEqual(PowerBatteryReading(isCharging: true, etaMinutes: 65_534).etaMinutes, 65_534)
        let drainingButFlaggedCharging = PowerBatteryReading(isCharging: true, voltageMV: 12_000,
            currentMA: -500, etaMinutes: 48)
        XCTAssertEqual(drainingButFlaggedCharging.flow, .discharging)
        XCTAssertEqual(drainingButFlaggedCharging.etaMinutes, 48)
    }

    func testPercentageRequiresAValidCapacityPair() {
        XCTAssertEqual(decode([kIOPSCurrentCapacityKey: 3_000, kIOPSMaxCapacityKey: 5_000]).batteryPercent, 60)
        XCTAssertEqual(decode([kIOPSCurrentCapacityKey: 0, kIOPSMaxCapacityKey: 100]).batteryPercent, 0)
        XCTAssertEqual(decode([kIOPSCurrentCapacityKey: 100, kIOPSMaxCapacityKey: 100]).batteryPercent, 100)
        for (current, maximum) in [(-1, 100), (101, 100), (0, 0), (0, -1)] {
            XCTAssertNil(decode([kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: maximum]).batteryPercent)
        }
    }

    func testVoltageAndCurrentAreNotMixedAcrossObservationSources() {
        let reading = decode([kIOPSVoltageKey: 12_500], battery: ["Amperage": -1_000])
        XCTAssertEqual(reading.voltageMV, 12_500)
        XCTAssertNil(reading.currentMA)
        XCTAssertNil(reading.netWatts)
        let completeRegistry = decode([kIOPSCurrentKey: -900],
            battery: ["Voltage": 12_000, "Amperage": -1_000])
        XCTAssertEqual(completeRegistry.voltageMV, 12_000)
        XCTAssertEqual(completeRegistry.currentMA, -1_000)
        XCTAssertEqual(completeRegistry.netWatts, -12)
    }

    func testRegistryFallbackPreservesSignedCurrentAndMetadata() {
        let negative = NSNumber(value: UInt64(bitPattern: Int64(-1_000)))
        let reading = decode(battery: ["Voltage": 12_000, "Amperage": negative,
                                      "ExternalConnected": false, "CycleCount": 50,
                                      "CurrentCapacity": 42, "MaxCapacity": 100,
                                      "VirtualTemperature": 3_300])
        XCTAssertEqual(reading.netWatts, -12)
        XCTAssertEqual(reading.batteryPercent, 42)
        XCTAssertEqual(reading.temperatureC, 33)
        XCTAssertEqual(reading.cycleCount, 50)
        XCTAssertEqual(reading.adapterState, .disconnected)
    }

    func testTopLevelSmartBatteryTemperatureUsesTenthKelvin() throws {
        let reading = decode(battery: ["Temperature": 3_200, "CycleCount": 1.5])
        XCTAssertEqual(try XCTUnwrap(reading.temperatureC), 46.85, accuracy: 0.000_001)
        XCTAssertNil(reading.cycleCount)
    }

    func testTopLevelVirtualTemperatureUsesCentiCelsius() {
        XCTAssertEqual(decode(battery: ["VirtualTemperature": 3_200]).temperatureC, 32)
    }

    func testTemperatureFallsBackToVirtualOnlyWhenPhysicalReadingIsUnavailable() throws {
        let physical = decode(battery: ["Temperature": 3_200, "VirtualTemperature": 3_100])
        XCTAssertEqual(try XCTUnwrap(physical.temperatureC), 46.85, accuracy: 0.000_001)
        for invalid: Any in [Double.nan, 9_000, true, NSNull()] {
            let fallback = decode(battery: ["Temperature": invalid, "VirtualTemperature": 3_100])
            XCTAssertEqual(fallback.temperatureC, 31)
        }
        XCTAssertEqual(decode(battery: ["VirtualTemperature": 3_100]).temperatureC, 31)
        XCTAssertNil(decode().temperatureC)
    }

    func testUnknownNestedAndPackTemperatureUnitsRemainUnavailable() {
        // Unlike Apple's documented top-level keys, these similarly named keys
        // are not assumed to use centi-Celsius merely because /100 looks valid.
        let unknownSources: [([String: Any]?, [String: Any]?)] = [
            (["BatteryData": ["Temperature": 3_200]], nil),
            (["BatteryData": ["VirtualTemperature": 3_200]], nil),
            (nil, ["Temperature": 3_200]),
            (nil, ["VirtualTemperature": 3_200]),
            (nil, ["BatteryData": ["Temperature": 3_200]]),
            (nil, ["BatteryData": ["VirtualTemperature": 3_200]])
        ]
        for (battery, pack) in unknownSources {
            XCTAssertNil(decode(battery: battery, pack: pack).temperatureC)
        }
        XCTAssertEqual(decode(battery: ["Temperature": 3_200],
                              pack: ["BatteryData": ["Temperature": 1_000]]).temperatureC,
                       decode(battery: ["Temperature": 3_200]).temperatureC)
    }

    func testInvalidTopLevelTemperaturesStayUnavailableWithoutGuessingUnits() {
        for invalid: Any in [true, false, "3200", NSNull(), Double.nan,
                             Double.infinity, -Double.infinity, -1, 8_001, 9_000] {
            XCTAssertNil(decode(battery: ["Temperature": invalid]).temperatureC, "\(invalid)")
            XCTAssertNil(decode(battery: ["VirtualTemperature": invalid]).temperatureC, "\(invalid)")
        }
        XCTAssertNil(decode(battery: ["Temperature": 0]).temperatureC)
        XCTAssertEqual(decode(battery: ["VirtualTemperature": 0]).temperatureC, 0)
    }

    func testInitializerBoundsAndPowerOverflowStayUnavailable() {
        let reading = PowerBatteryReading(externalConnected: true, batteryPercent: 101,
            voltageMV: 0, currentMA: .nan, adapterReportedWatts: -1, temperatureC: 81, cycleCount: -1)
        XCTAssertNil(reading.batteryPercent)
        XCTAssertNil(reading.voltageMV)
        XCTAssertNil(reading.currentMA)
        XCTAssertNil(reading.netWatts)
        XCTAssertNil(reading.adapterReportedWatts)
        XCTAssertNil(reading.temperatureC)
        XCTAssertNil(reading.cycleCount)
        XCTAssertNil(PowerBatteryReading(voltageMV: .greatestFiniteMagnitude, currentMA: 2).netWatts)
    }
    /// One read-only host query. This checks decoder/collection usability only;
    /// it cannot verify sensor accuracy, cable transitions, sleep or clamshell.
    func testLiveReadOnlyPowerDetailsSmoke() throws {
        let capabilities = SystemProbe.capabilities
        guard capabilities.supportedPlatform else {
            throw XCTSkip("Read-only power-details smoke requires a supported Mac.")
        }
        let reading = SystemProbe.powerBatteryReading()
        if capabilities.internalBattery == true {
            XCTAssertNotNil(reading, "An observed internal battery should produce a reading, even if optional fields are missing.")
        } else if capabilities.hardware == .desktop {
            XCTAssertNil(reading, "A desktop without an internal battery must not acquire an invented battery reading.")
            return
        }
        guard let reading else {
            if capabilities.internalBattery == true { return }
            throw XCTSkip("Internal-battery availability could not be confirmed for this read-only query.")
        }
        XCTAssertTrue(reading.observedAt.timeIntervalSince1970.isFinite)
        if let external = reading.externalConnected {
            XCTAssertEqual(reading.source, external ? .ac : .battery)
        }
        if let percent = reading.batteryPercent { XCTAssertTrue((0...100).contains(percent)) }
        if let voltage = reading.voltageMV {
            XCTAssertTrue(voltage.isFinite && voltage > 0)
            XCTAssertEqual(reading.voltageV, voltage / 1_000)
        }
        if let current = reading.currentMA {
            XCTAssertTrue(current.isFinite)
            XCTAssertEqual(reading.currentA, current / 1_000)
        }
        if let voltage = reading.voltageMV, let current = reading.currentMA {
            let expected = voltage * current / 1_000_000
            if expected.isFinite { XCTAssertEqual(reading.netWatts, expected) }
            else { XCTAssertNil(reading.netWatts) }
        } else {
            XCTAssertNil(reading.netWatts)
        }
        if let watts = reading.netWatts {
            XCTAssertTrue(watts.isFinite)
            XCTAssertEqual(reading.flow, watts > 0 ? .charging : watts < 0 ? .discharging : .idle)
        } else {
            XCTAssertEqual(reading.flow, .unknown)
        }
        if let eta = reading.etaMinutes {
            XCTAssertTrue(eta.isFinite && eta >= 0 && eta < 65_535)
            XCTAssertEqual(reading.isCharging, true)
        }
        if let adapter = reading.adapterReportedWatts {
            XCTAssertTrue(adapter.isFinite && adapter > 0)
            XCTAssertEqual(reading.externalConnected, true)
            XCTAssertEqual(reading.adapterState, .reported)
        } else {
            XCTAssertEqual(reading.adapterState, reading.externalConnected == false ? .disconnected : .unavailable)
        }
        if let temperature = reading.temperatureC {
            XCTAssertTrue(temperature.isFinite && (0...80).contains(temperature))
        }
        if let cycles = reading.cycleCount { XCTAssertGreaterThanOrEqual(cycles, 0) }
    }

}
