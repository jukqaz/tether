import Foundation
import TetherCore

/// Snapshots and sensor readings, fakeable in dry-run for scenario tests without unplugging.
extension Helper {
    /// Dry-run only: JSON with any of power, lid ("closed"/"open"), sleepDisabled, temperature,
    /// thermal, battery. Re-read on every evaluation so a script can walk through a scenario.
    var fake: [String: Any] {
        guard dryRun, let fakePath, let data = FileManager.default.contents(atPath: fakePath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func currentSnapshot() -> Snapshot {
        var s = SystemProbe.snapshot()
        let f = fake
        if let p = (f["power"] as? String).flatMap(PowerSource.init(rawValue:)) { s.power = p }
        if let lid = f["lid"] as? String { s.lidClosed = lid == "closed" }
        if let sd = f["sleepDisabled"] as? Bool { s.sleepDisabled = sd }
        return s
    }

    func currentReadings() -> SafetyReadings {
        var r = SystemProbe.safetyReadings()
        let f = fake
        if let t = f["temperature"] as? Double { r.temperature = t }
        if let t = f["thermal"] as? Int { r.thermal = t }
        if let b = f["battery"] as? Int { r.batteryPercent = b }
        return r
    }
}
