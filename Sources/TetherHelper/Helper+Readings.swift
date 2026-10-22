import Foundation
import TetherCore

/// Snapshots and sensor readings, fakeable in dry-run for scenario tests without unplugging.
extension Helper {
    /// Dry-run only: JSON with any of power, lid ("closed"/"open"), sleepDisabled, fullWake,
    /// external, temperature, thermal, battery, lowPowerWarning, current (mA, negative while draining). Re-read on
    /// every evaluation so a script can walk through a scenario.
    var fake: [String: Any] {
        guard dryRun, let fakePath, let data = FileManager.default.contents(atPath: fakePath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func currentSnapshot() -> Snapshot {
        var s = dryRun && fakePath != nil
            ? Snapshot(power: .unknown, lidClosed: false, sleepDisabled: false)
            : SystemProbe.snapshot(nativeDisplayEvidence: nativeDisplayCache.evidence,
                nativeDisplayProbePending: nativeDisplayCache.pending)
        let f = fake
        if let p = (f["power"] as? String).flatMap(PowerSource.init(rawValue:)) { s.power = p }
        if let lid = f["lid"] as? String {
            s.observedLidClosed = lid == "closed" ? true : lid == "open" ? false : nil
        }
        if f["lid"] is NSNull { s.observedLidClosed = nil }
        if let sd = f["sleepDisabled"] as? Bool { s.sleepDisabled = sd }
        if let value = simulatedSleepDisabled { s.sleepDisabled = value }
        // Explicit external-change injection; ordinary fixtures retain successful OS writes.
        if let value = f["externalOverride"] as? Bool { s.sleepDisabled = value }
        // Failed live queries override even a previously successful simulated OS write.
        if f["sleepDisabled"] is NSNull { s.observedSleepDisabled = nil }
        if let failureAfter = f["sleepDisabledUnreadableAfterWrite"] as? Bool,
           simulatedSleepDisabled == failureAfter { s.observedSleepDisabled = nil }
        if let full = f["fullWake"] as? Bool { s.fullWake = full }
        if f["fullWake"] is NSNull { s.observedFullWake = nil }
        if let external = f["external"] as? Bool {
            s.externalDisplay = external; s.displayTopology = external ? .externalUnverified : .none
        }
        if let raw = f["displayTopology"] as? String, let topology = DisplayTopology(rawValue: raw) {
            s.displayTopology = topology; s.externalDisplay = topology.mayHaveExternal
        }
        if f["displayObservations"] != nil {
            let displays = fakeDisplayObservations
            s.displayTopology = DisplayProbe.topology(displays)
            s.externalDisplay = s.displayTopology.mayHaveExternal
            s.nativeDisplayCandidate = nativeDisplayCache.evidence?.matches(displays) == true
            s.nativeDisplayVerified = nativeDisplayCache.evidence?.available(snapshot: s,
                observations: displays, causesSleep: f["clamshellCausesSleep"] as? Bool) == true
        }
        // Test-owned handoff evidence only. The live path never accepts this from a client
        // or upgrades a CoreGraphics extra-screen count into verified native operation.
        if let verified = f["nativeDisplayVerified"] as? Bool { s.nativeDisplayVerified = verified }
        if let pending = f["nativeDisplayProbePending"] as? Bool { s.nativeDisplayProbePending = pending }
        return s
    }

    func currentReadings() -> SafetyReadings {
        var r = dryRun && fakePath != nil
            ? SafetyReadings(temperature: nil, thermal: 0, batteryPercent: nil)
            : SystemProbe.safetyReadings()
        let f = fake
        if f["temperature"] is NSNull { r.temperature = nil }
        if f["battery"] is NSNull { r.batteryPercent = nil }
        if let t = f["temperature"] as? Double { r.temperature = t }
        if let t = f["thermal"] as? Int { r.thermal = t }
        if let b = f["battery"] as? Int { r.batteryPercent = b }
        if f.keys.contains("lowPowerWarning") { r.lowPowerWarning = f["lowPowerWarning"] as? Bool }
        if let c = f["current"] as? Int { r.current = c }
        return r
    }

    func currentPowerMode(onBattery: Bool) -> PowerModeSetting? {
        if dryRun, fakePath != nil {
            if fake["powerModeUnreadable"] as? Bool == true { return nil }
            let key = PowerModeSetting.Key(rawValue: fake["powerModeKey"] as? String ?? "powermode") ?? .powermode
            let value = fake[onBattery ? "externalBatteryPowerMode" : "externalACPowerMode"] as? Int
                ?? simulatedPowerModes[onBattery] ?? (fake[onBattery ? "batteryPowerMode" : "acPowerMode"] as? Int ?? 0)
            return PowerModeSetting(key: key, value: value)
        }
        return SystemProbe.powerModeSetting(section: onBattery ? "Battery Power" : "AC Power")
    }
}
