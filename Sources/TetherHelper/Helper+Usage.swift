import Foundation
import TetherCore

/// Usage stats, lid sessions and the sleep log.
extension Helper {
    func updateUsage(_ s: Snapshot, clamshellOn: Bool, readings r: SafetyReadings) {
        let now = Date()
        let woke = justWoke
        justWoke = false
        var recorded = false
        if let slept = usage.sleeps.awake(at: now.timeIntervalSince1970, fullWake: s.fullWake, justWoke: woke,
                                           percent: r.batteryPercent, onBattery: s.power == .battery,
                                           sleepReason: SystemProbe.rootDomainString("Last Sleep Reason"),
                                           requestedByTether: SystemProbe.sleepRequestedByPID == Int(getpid()),
                                           wakeType: SystemProbe.rootDomainString("Wake Type"),
                                           wakeReason: SystemProbe.rootDomainString("Wake Reason")) {
            log(String(format: "slept %.0f min, charge %@%% -> %@%%%@, %d dark wakes; asleep by %@, woke by %@ (%@)",
                       (slept.duration ?? 0) / 60, slept.percentBefore.map(String.init) ?? "?",
                       slept.percentAfter.map(String.init) ?? "?",
                       slept.drainPerHour.map { String(format: " (%.1f%%/h)", $0) } ?? "", slept.darkWakes,
                       slept.byTether ? "Tether" : (slept.sleepReason ?? "?"), slept.wakeType ?? "?",
                       slept.wakeReason ?? "?"))
            recorded = true
        }
        usage.stats.tick(now: now, sample: UsageSample(lidClosed: s.lidClosed, clamshellOn: clamshellOn,
                                                       holdingOnBattery: holdingOnBattery, temperature: r.temperature,
                                                       thermal: r.thermal, batteryPercent: r.batteryPercent))
        let lowPower = state.savedACLowPower != nil || state.savedBatteryLowPower != nil
        if let session = usage.tracker.update(lidClosed: s.lidClosed, clamshellOn: clamshellOn, readings: r,
                                              onBattery: s.power == .battery, lowPower: lowPower, now: now) {
            usage.add(session)
            recorded = true
            log(String(format: "lid session: %.0f min, max %.1f°C, thermal %d, charge %@%% -> %@%%",
                       session.duration / 60, session.maxTemperature ?? -1, session.maxThermal,
                       session.batteryStart.map(String.init) ?? "?", session.batteryEnd.map(String.init) ?? "?"))
        }
        // The stats tick on every check; a write every few minutes is plenty for them, while a
        // finished sleep or session is saved at once.
        if recorded || now.timeIntervalSince(usageSavedAt) >= 300 {
            JSONFile.write(usage, to: usagePath, permissions: 0o644)
            usageSavedAt = now
        }
    }

    func saveState() {
        JSONFile.write(state, to: statePath, permissions: 0o600)
    }
}
