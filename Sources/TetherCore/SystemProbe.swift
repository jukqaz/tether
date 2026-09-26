import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Read-only views of power state. Needs no privileges, so the app can use it too.
public enum SystemProbe {
    public static func snapshot() -> Snapshot {
        Snapshot(
            power: powerSource(),
            lidClosed: rootDomainBool("AppleClamshellState") ?? false,
            sleepDisabled: rootDomainBool("SleepDisabled") ?? pmsetSleepDisabled(),
            // kIOPMSystemCapabilityGraphics (0x2) is missing during a dark wake.
            fullWake: rootDomainInt("System Capabilities").map { $0 & 0x2 != 0 } ?? true,
            externalDisplay: rootDomainBool("AppleClamshellCausesSleep").map { !$0 } ?? false)
    }

    public static func powerSource() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return .unknown }
        switch type {
        case "AC Power": return .ac
        case "Battery Power": return .battery
        default: return .unknown
        }
    }

    /// Battery pack temperature in °C, in hundredths of a degree in the registry. macOS 27 keeps
    /// it on the AppleSmartBatteryPack child (BatteryData.Temperature); older layouts had it on
    /// AppleSmartBattery itself, so both are tried.
    public static func batteryTemperature() -> Double? {
        for className in ["AppleSmartBatteryPack", "AppleSmartBattery"] {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
            guard service != 0 else { continue }
            defer { IOObjectRelease(service) }
            let data = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            let top = { (key: String) in
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int
            }
            let raw = (data?["Temperature"] as? Int) ?? (data?["VirtualTemperature"] as? Int)
                ?? top("Temperature") ?? top("VirtualTemperature")
            // Sanity range guards against a unit change turning a bad reading into a verdict.
            if let raw, (500...9000).contains(raw) { return Double(raw) / 100 }
        }
        return nil
    }

    public static func batteryPercent() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return current * 100 / max
        }
        return nil
    }

    /// The saved `lowpowermode` (0 off, 1 on) for "Battery Power" or "AC Power" in the output of
    /// `pmset -g custom`. Needs no privileges.
    public static func lowPowerMode(section: String) -> Int? {
        lowPowerMode(in: Shell.run("/usr/bin/pmset", ["-g", "custom"]).output, section: section)
    }

    /// Both at once, from one `pmset` run.
    public static func lowPowerModes() -> (battery: Int?, ac: Int?) {
        let output = Shell.run("/usr/bin/pmset", ["-g", "custom"]).output
        return (lowPowerMode(in: output, section: "Battery Power"), lowPowerMode(in: output, section: "AC Power"))
    }

    public static func lowPowerMode(in pmsetCustom: String, section: String) -> Int? {
        var inSection = false
        for line in pmsetCustom.split(separator: "\n") {
            if !line.hasPrefix(" ") {
                inSection = line.hasPrefix(section)
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            if inSection, fields.first == "lowpowermode", let value = fields.last.flatMap({ Int($0) }) {
                return value
            }
        }
        return nil
    }

    /// A built-in battery is present. Desktops have none, and Tether must leave them alone: to
    /// them every moment is "on AC", which would mean never sleeping.
    public static var hasBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            (IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any])?[kIOPSTypeKey] as? String
                == kIOPSInternalBatteryType
        }
    }

    /// The Mac has a lid (IOPMrootDomain publishes a clamshell state).
    public static var hasLid: Bool { rootDomainValue("AppleClamshellState") != nil }

    /// Tether's rules apply: a laptop with a lid and a battery.
    public static var isSupportedMac: Bool { hasBattery && hasLid }

    /// Processes other than `excluding` holding power assertions that keep the Mac or its display
    /// awake, e.g. an app's "prevent sleep" setting. powerd's own display-on assertion is left out.
    public static func sleepBlockers(excluding: [Int32] = []) -> [SleepBlocker] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var out: [SleepBlocker] = []
        for (pid, assertions) in byProcess where !excluding.contains(pid.int32Value) {
            for a in assertions {
                // powerd names every process for us; proc_name cannot read root processes.
                let name = a["Process Name"] as? String ?? processName(pid.int32Value)
                if name == "powerd" { continue }
                guard (a["AssertLevel"] as? Int ?? 255) != 0, let type = a["AssertType"] as? String,
                      let kind = SleepBlocker.Kind(assertionType: type) else { continue }
                out.append(SleepBlocker(pid: pid.int32Value, process: name, kind: kind,
                                        reason: a["AssertName"] as? String ?? ""))
            }
        }
        return out.sorted { ($0.process, $0.kind.rawValue) < ($1.process, $1.kind.rawValue) }
    }

    private static func processName(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }

    public static func safetyReadings() -> SafetyReadings {
        SafetyReadings(temperature: batteryTemperature(),
                       thermal: ProcessInfo.processInfo.thermalState.rawValue,
                       batteryPercent: batteryPercent())
    }

    private static func rootDomainValue(_ key: String) -> Any? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func rootDomainBool(_ key: String) -> Bool? { rootDomainValue(key) as? Bool }
    private static func rootDomainInt(_ key: String) -> Int? { rootDomainValue(key) as? Int }

    /// "Last Sleep Reason", "Wake Type", "Wake Reason": what IOPMrootDomain says about the last
    /// sleep and wake.
    public static func rootDomainString(_ key: String) -> String? { rootDomainValue(key) as? String }

    /// The process that asked for the last sleep.
    public static var sleepRequestedByPID: Int? { rootDomainInt("SleepRequestedByPID") }

    /// Fallback for macOS versions that do not publish SleepDisabled in the registry.
    private static func pmsetSleepDisabled() -> Bool {
        let output = Shell.run("/usr/bin/pmset", ["-g"]).output
        return output.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.first == "SleepDisabled" && fields.last == "1"
        }
    }
}

public enum Shell {
    @discardableResult
    public static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// One power assertion another process holds.
public struct SleepBlocker: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Stops idle sleep (on battery too); a closed lid and forced sleep still win.
        case system
        /// Keeps the display on, which also keeps the system awake.
        case display

        init?(assertionType: String) {
            switch assertionType {
            case "PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "PreventSystemSleep", "PreventDiskIdle": self = .system
            case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": self = .display
            default: return nil
            }
        }
    }

    public var pid: Int32
    public var process: String
    public var kind: Kind
    /// The name the process gave the assertion, e.g. "Electron", "Playing audio".
    public var reason: String
}
