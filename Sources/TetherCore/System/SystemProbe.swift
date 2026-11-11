import Darwin
import Foundation
import IOKit
import CoreGraphics
import IOKit.ps
import IOKit.pwr_mgt

/// Read-only views of power state. Needs no privileges, so the app can use it too.
public enum SystemProbe {
    public static func snapshot(nativeDisplayEvidence: NativeDisplayEvidence? = nil,
                                nativeDisplayProbePending: Bool = false) -> Snapshot {
        var result = Snapshot(
            power: powerSource(),
            lidClosed: observedLidClosed,
            sleepDisabled: rootDomainBool("SleepDisabled") ?? pmsetSleepDisabled(),
            // kIOPMSystemCapabilityGraphics (0x2) is missing during a dark wake.
            fullWake: observedFullWake,
            externalDisplay: true)
        let displays = DisplayProbe.observations()
        result.displayTopology = DisplayProbe.topology(displays)
        result.externalDisplay = result.displayTopology.mayHaveExternal
        let causesSleep = rootDomainBool("AppleClamshellCausesSleep")
        result.nativeDisplayCandidate = nativeDisplayEvidence?.matches(displays) == true
        result.nativeDisplayVerified = nativeDisplayEvidence?.available(snapshot: result,
            observations: displays, causesSleep: causesSleep) == true
        result.nativeDisplayProbePending = nativeDisplayProbePending && result.power == .ac
            && result.observedFullWake == true && result.observedSleepDisabled == false
            && result.observedLidClosed != nil && causesSleep == false
        return result
    }

    public static func displayTopology() -> DisplayTopology {
        DisplayProbe.topology(DisplayProbe.observations())
    }
    public static func externalDisplayConnected() -> Bool? {
        DisplayProbe.observations().map { $0.contains { !$0.builtIn } }
    }
    public static func builtInDisplaySleeping() -> Bool? {
        DisplayProbe.observations()?.first(where: \.builtIn)?.asleep
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

    /// IOPowerSources.h: None=1, Early=2, Final=3. Unknown values remain unavailable.
    /// This is the OS battery warning, not the energy-saving Low Power Mode preference.
    public static func lowBatteryWarning() -> Bool? {
        lowBatteryWarning(level: Int(IOPSGetBatteryWarningLevel().rawValue))
    }

    public static func lowBatteryWarning(level: Int) -> Bool? {
        switch level {
        case 1: false
        case 2, 3: true
        default: nil
        }
    }

    /// The saved `lowpowermode` (0 off, 1 on) for "Battery Power" or "AC Power" in the output of
    /// `pmset -g custom`. Needs no privileges.
    public static func lowPowerMode(section: String) -> Int? {
        lowPowerMode(in: Shell.run("/usr/bin/pmset", ["-g", "custom"], timeout: 2).output, section: section)
    }

    /// Both at once, from one `pmset` run.
    public static func lowPowerModes() -> (battery: Int?, ac: Int?) {
        let output = Shell.run("/usr/bin/pmset", ["-g", "custom"], timeout: 2).output
        return (lowPowerMode(in: output, section: "Battery Power"), lowPowerMode(in: output, section: "AC Power"))
    }

    public static func powerModeSetting(section: String) -> PowerModeSetting? {
        powerModeSetting(in: Shell.run("/usr/bin/pmset", ["-g", "custom"], timeout: 2).output, section: section)
    }

    public static func lowPowerMode(in pmsetCustom: String, section: String) -> Int? {
        powerModeSetting(in: pmsetCustom, section: section)?.value
    }

    public static func powerModeSetting(in pmsetCustom: String, section: String) -> PowerModeSetting? {
        var inSection = false
        for line in pmsetCustom.split(separator: "\n") {
            if line.first?.isWhitespace != true { inSection = line == section + ":"; continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard inSection, fields.count == 2, let value = Int(fields[1]),
                  let key = PowerModeSetting.Key(rawValue: String(fields[0])) else { continue }
            let setting = PowerModeSetting(key: key, value: value)
            if setting.arguments(onBattery: true, value: value) != nil { return setting }
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
    public static var observedLidClosed: Bool? { rootDomainBool("AppleClamshellState") }
    public static var hasLid: Bool { rootDomainValue("AppleClamshellState") != nil }

    public static var observedFullWake: Bool? { rootDomainInt("System Capabilities").map { $0 & 0x2 != 0 } }

    /// Product support is independent from battery and lid capabilities.
    public static var isSupportedMac: Bool { capabilities.generalIdleAvailable }

    /// Processes other than `excluding` holding power assertions that keep the Mac or its display
    /// awake, e.g. an app's "prevent sleep" setting. powerd's own display-on assertion is left out.
    public static func sleepBlockers(excluding: [Int32] = []) -> [SleepBlocker] {
        sleepBlockerSnapshot(excluding: excluding) ?? []
    }

    /// Nil is a failed query, distinct from a successful observation with no assertions.
    public static func sleepBlockerSnapshot(excluding: [Int32] = []) -> [SleepBlocker]? {
        sleepBlockerSnapshot(excluding: excluding, closedLidSleepOnly: false)
    }

    /// The inspector observes activity separately from work assertions. A missing
    /// activity type in a fallback status remains unavailable, not "no input".
    public static func powerActivitySnapshot(excluding: [Int32] = []) -> PowerActivityObservation {
        guard let observed = PowerAssertionSnapshot.read(relevantTypes: PowerAssertionSnapshot.activityTypes) else {
            return PowerActivityObservation(blockers: sleepBlockerSnapshot(excluding: excluding), signals: nil)
        }
        return PowerActivityObservation(blockers: decodeSleepBlockers(observed, excluding: excluding, closedLidSleepOnly: false),
            signals: decodeActivitySignals(observed, excluding: excluding))
    }

    static func decodeActivitySignals(_ observed: PowerAssertionSnapshot.ByProcess, excluding: [Int32]) -> [PowerActivitySignal] {
        var signals: [PowerActivitySignal] = []
        for (pid, assertions) in observed where !excluding.contains(pid.int32Value) {
            for assertion in assertions {
                guard let level = assertion["AssertLevel"] as? Int, level > 0,
                      let type = assertion["AssertType"] as? String else { continue }
                let kind: PowerActivitySignal.Kind
                switch type {
                case "UserIsActive": kind = .userActivity
                case "InternalPreventDisplaySleep": kind = .displayDelay
                default: continue
                }
                let name = assertion["Process Name"] as? String ?? processName(pid.int32Value)
                signals.append(PowerActivitySignal(pid: pid.int32Value, process: name, kind: kind,
                    sourcePID: kind == .userActivity ? PowerActivitySignal.inputSourcePID(owner: name, name: assertion["AssertName"] as? String) : nil))
            }
        }
        return Array(Set(signals.map(\.id))).sorted().compactMap { id in signals.first { $0.id == id } }
    }

    /// A screen/network request is not a system keep-awake request. Preserve the
    /// requests themselves while respecting only other system work at this gate.
    public static func closedLidSleepBlockerSnapshot(excluding: [Int32] = []) -> [SleepBlocker]? {
        sleepBlockerSnapshot(excluding: excluding, closedLidSleepOnly: true)
    }

    private static func sleepBlockerSnapshot(excluding: [Int32], closedLidSleepOnly: Bool) -> [SleepBlocker]? {
        let types = closedLidSleepOnly ? PowerAssertionSnapshot.closedLidSleepBlockerTypes : PowerAssertionSnapshot.blockerTypes
        guard let byProcess = PowerAssertionSnapshot.read(relevantTypes: types) else { return nil }
        return decodeSleepBlockers(byProcess, excluding: excluding, closedLidSleepOnly: closedLidSleepOnly)
    }

    static func decodeSleepBlockers(_ byProcess: PowerAssertionSnapshot.ByProcess, excluding: [Int32],
                                   closedLidSleepOnly: Bool) -> [SleepBlocker] {
        var out: [SleepBlocker] = []
        for (pid, assertions) in byProcess where !excluding.contains(pid.int32Value) {
            for a in assertions {
                // powerd names every process for us; proc_name cannot read root processes.
                let name = a["Process Name"] as? String ?? processName(pid.int32Value)
                if name == "powerd" { continue }
                guard (a["AssertLevel"] as? Int ?? 255) != 0, let type = a["AssertType"] as? String,
                      let kind = SleepBlocker.Kind(assertionType: type) else { continue }
                if closedLidSleepOnly, kind != .system && kind != .legacySystem { continue }
                out.append(SleepBlocker(pid: pid.int32Value, process: name, kind: kind,
                                        reason: a["AssertName"] as? String ?? "", assertionType: type,
                                        purpose: PowerRequestPurpose(assertionName: a["AssertName"] as? String)))
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
                       batteryPercent: batteryPercent(), current: batteryCurrent(),
                       lowPowerWarning: lowBatteryWarning())
    }

    /// Battery current in mA from IOPS: negative while the battery drains, also on a charger that
    /// can't keep up.
    public static func batteryCurrent() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            return description[kIOPSCurrentKey] as? Int
        }
        return nil
    }

    /// IOPMrootDomain lives as long as the system does, so it is looked up once, not per read.
    private static let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

    private static func rootDomainValue(_ key: String) -> Any? {
        guard rootDomain != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?
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
    private static func pmsetSleepDisabled() -> Bool? {
        let result = Shell.run("/usr/bin/pmset", ["-g"], timeout: 2)
        return sleepDisabled(in: result)
    }

    /// A successful command without the exact setting is still an unavailable observation.
    /// Reject duplicate/ambiguous values and output from failed or unfinished readers.
    public static func sleepDisabled(in result: Shell.Result) -> Bool? {
        guard result.status == 0, !result.timedOut, result.terminationConfirmed else { return nil }
        let rows = result.output.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace) }
            .filter { $0.first == "SleepDisabled" }
        guard rows.count == 1, rows[0].count == 2 else { return nil }
        switch rows[0][1] {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }
}

/// One power assertion another process holds.
public struct SleepBlocker: Equatable, Sendable {
    public enum Kind: String, Sendable, Hashable {
        /// Stops idle sleep (on battery too); a closed lid and forced sleep still win.
        case system
        /// Keeps the display on, which also keeps the system awake.
        case display
        /// Network work can keep the system active without requesting a lit display.
        case network
        /// Deprecated assertion, kept visible without claiming modern sleep guarantees.
        case legacySystem

        init?(assertionType: String) {
            switch assertionType {
            case "PreventUserIdleSystemSleep", "NoIdleSleepAssertion": self = .system
            case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": self = .display
            case "NetworkClientActive": self = .network
            case "PreventSystemSleep": self = .legacySystem
            default: return nil
            }
        }
    }

    public var pid: Int32
    public var process: String
    public var kind: Kind
    /// The name the process gave the assertion, e.g. "Electron", "Playing audio".
    public var reason: String
    public var assertionType: String?
    public var purpose: PowerRequestPurpose?

    public init(pid: Int32, process: String, kind: Kind, reason: String, assertionType: String? = nil,
                purpose: PowerRequestPurpose? = nil) {
        self.pid = pid; self.process = process; self.kind = kind; self.reason = reason; self.assertionType = assertionType
        self.purpose = purpose
    }
}
