import CoreFoundation
import Foundation
import IOKit
import IOKit.ps

extension SystemProbe {
    /// One bounded, read-only collection for the details UI. IOPS descriptions
    /// come from one copied info object; registry fields come from copied property
    /// dictionaries. The result is an observation, not an atomic hardware sample.
    /// Native power/wake notifications invalidate it in the UI monitor.
    public static func powerBatteryReading(observedAt: Date = Date()) -> PowerBatteryReading? {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        var internalDescription: [String: Any]?
        var providingSource: String?
        if let info {
            providingSource = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
            if let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
                for source in sources {
                    guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                          description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                          powerDetailBool(description[kIOPSIsPresentKey]) != false else { continue }
                    internalDescription = description
                    break
                }
            }
        }
        let battery = powerDetailProperties(className: "AppleSmartBattery")
        guard internalDescription != nil || battery != nil else { return nil }
        let pack = powerDetailProperties(className: "AppleSmartBatteryPack")
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        return decodePowerBatteryReading(description: internalDescription ?? [:], batteryProperties: battery,
            packProperties: pack, adapterDetails: adapter, providingSource: providingSource, observedAt: observedAt)
    }

    /// Pure decoder shared by real collection and regressions. Never maps query
    /// failure to zero, an unplug event, or a keep-awake policy decision.
    static func decodePowerBatteryReading(description: [String: Any], batteryProperties: [String: Any]?,
                                         packProperties: [String: Any]?, adapterDetails: [String: Any]?,
                                         providingSource: String?, observedAt: Date) -> PowerBatteryReading {
        let battery = batteryProperties ?? [:]
        let pack = packProperties ?? [:]
        let external = powerDetailBool(battery["ExternalConnected"])
            ?? (adapterDetails != nil ? true : nil)
        let source: PowerSource
        switch providingSource ?? (description[kIOPSPowerSourceStateKey] as? String) {
        case kIOPSACPowerValue: source = .ac
        case kIOPSBatteryPowerValue: source = .battery
        default: source = .unknown
        }
        let charging = powerDetailBool(description[kIOPSIsChargingKey]) ?? powerDetailBool(battery["IsCharging"])
        let charged = powerDetailBool(description[kIOPSIsChargedKey]) ?? powerDetailBool(battery["FullyCharged"])

        let percent = powerDetailPercent(current: description[kIOPSCurrentCapacityKey], max: description[kIOPSMaxCapacityKey])
            ?? powerDetailPercent(current: battery["CurrentCapacity"], max: battery["MaxCapacity"])
        let iopsVoltage = powerDetailNumber(description[kIOPSVoltageKey]).flatMap { $0 > 0 ? $0 : nil }
        let iopsCurrent = powerDetailNumber(description[kIOPSCurrentKey])
        let registryVoltage = powerDetailNumber(battery["Voltage"]).flatMap { $0 > 0 ? $0 : nil }
        let registryCurrent = powerDetailSignedCurrent(battery["Amperage"])
        // Do not combine voltage from one source and current from another into W.
        let voltage: Double?, current: Double?
        if iopsVoltage != nil && iopsCurrent != nil {
            (voltage, current) = (iopsVoltage, iopsCurrent)
        } else if registryVoltage != nil && registryCurrent != nil {
            (voltage, current) = (registryVoltage, registryCurrent)
        } else if iopsVoltage != nil || iopsCurrent != nil {
            (voltage, current) = (iopsVoltage, iopsCurrent)
        } else {
            (voltage, current) = (registryVoltage, registryCurrent)
        }
        let packData = pack["BatteryData"] as? [String: Any] ?? [:]
        let batteryData = battery["BatteryData"] as? [String: Any] ?? [:]
        // macOS publishes top-level Temperature in Smart Battery 0.1 K, while
        // VirtualTemperature is explicitly converted to centi-Celsius by Apple.
        // https://github.com/apple-oss-distributions/PowerManagement/blob/main/AppleSmartBatteryManager/AppleSmartBattery.cpp#L1413-L1424
        // https://sbs-forum.org/specs/sbdat110.pdf (Temperature(), section 5.1.9)
        // Nested BatteryData and AppleSmartBatteryPack keys have no established
        // unit contract here; never infer their units from a plausible range.
        let rawTemperature = powerDetailNumber(battery["Temperature"]).map { $0 / 10 - 273.15 }
        let virtualTemperature = powerDetailNumber(battery["VirtualTemperature"]).map { $0 / 100 }
        let temperature = [rawTemperature, virtualTemperature]
            .compactMap { $0 }.first { (0...80).contains($0) }
        let cycles = [battery["CycleCount"], packData["CycleCount"], batteryData["CycleCount"], pack["CycleCount"]]
            .compactMap { powerDetailInteger($0) }.first { $0 >= 0 }
        return PowerBatteryReading(observedAt: observedAt, source: source, externalConnected: external,
            isCharging: charging, isCharged: charged, batteryPercent: percent, voltageMV: voltage, currentMA: current,
            etaMinutes: powerDetailNumber(description[kIOPSTimeToFullChargeKey]),
            adapterReportedWatts: powerDetailNumber(adapterDetails?[kIOPSPowerAdapterWattsKey]),
            temperatureC: temperature, cycleCount: cycles)
    }

    private static func powerDetailProperties(className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties else { return nil }
        return properties.takeRetainedValue() as NSDictionary as? [String: Any]
    }

    private static func powerDetailNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func powerDetailInteger(_ value: Any?) -> Int? {
        guard let value = powerDetailNumber(value), value.rounded(.towardZero) == value,
              value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }

    private static func powerDetailBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func powerDetailPercent(current: Any?, max: Any?) -> Int? {
        guard let current = powerDetailNumber(current), let max = powerDetailNumber(max),
              current >= 0, max > 0, current <= max else { return nil }
        let percent = current / max * 100
        guard percent.isFinite, (0...100).contains(percent) else { return nil }
        return Int(percent.rounded(.towardZero))
    }

    private static func powerDetailSignedCurrent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // IORegistry may represent a signed 64-bit Amperage as an unsigned
        // property. This applies only to this registry key, never other numbers.
        if String(cString: number.objCType) == "Q", number.uint64Value > UInt64(Int64.max) {
            return Double(Int64(bitPattern: number.uint64Value))
        }
        return powerDetailNumber(number)
    }
}
