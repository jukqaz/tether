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
            log(String(format: "slept %.0f min, charge %@%% -> %@%%%@, dark wakes %@; asleep by %@, woke by %@ (%@)",
                       (slept.duration ?? 0) / 60, slept.percentBefore.map(String.init) ?? "?",
                       slept.percentAfter.map(String.init) ?? "?",
                       slept.drainPerHour.map { String(format: " (%.1f%%/h)", $0) } ?? "", slept.darkWakeSummary,
                       slept.byTether ? "Tether" : (slept.sleepReason ?? "?"), slept.wakeType ?? "?",
                       slept.wakeReason ?? "?"))
            recorded = true
            reconcileSleepLog()
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

    /// Run at startup/full wake, never synchronously inside a power notification or policy loop.
    /// Two bounded reads allow powerd to finish writing the wake event; no continuous polling.
    func reconcileSleepLog(attempt: Int = 0) {
        guard !systemSleepTransition, currentSnapshot().fullWake,
              usage.sleeps.recent.contains(where: { $0.darkWakeCountVerified != true }) else { return }
        guard !sleepLogReadInFlight else { sleepLogReadQueued = true; return }
        let simulated = dryRun
        let fixtureLog = simulated ? fake["powerEventLog"] as? String : nil
        if simulated && fixtureLog == nil { return }
        sleepLogReadInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output: String?
            let readStatus: Int32
            if simulated { output = fixtureLog; readStatus = 0 }
            else {
                let result = Shell.run("/usr/bin/pmset", ["-g", "log"], timeout: 8,
                                       maxOutputBytes: 4 * 1_048_576, keepTail: true)
                readStatus = result.status
                output = result.status == 0 ? result.output : nil
            }
            let events = output.map(SystemSleepEvents.init)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sleepLogReadInFlight = false
                if readStatus != 0 {
                    self.log("sleep log reconciliation unavailable: pmset status=\(readStatus); notification counts remain unverified")
                }
                var sleeps = self.usage.sleeps
                let changed = events.map { sleeps.reconcileDarkWakes(with: $0) } ?? 0
                if changed > 0 {
                    var next = self.usage; next.sleeps = sleeps
                    if JSONFile.write(next, to: self.usagePath, permissions: 0o644) {
                        let corrected = sleeps.recent.filter { row in
                            row.darkWakeCountVerified == true && self.usage.sleeps.recent.contains {
                                $0.sleptAt == row.sleptAt && $0.wokeAt == row.wokeAt && $0.darkWakeCountVerified != true
                            }
                        }
                        self.usage = next
                        self.log("sleep log reconciled: \(changed) record(s), dark wake counts verified against macOS events")
                        for row in corrected {
                            self.log("sleep log interval \(row.sleptAt)...\(row.wokeAt ?? row.sleptAt): darkWakes=\(row.darkWakes) source=pmset")
                        }
                        DarwinNotification.post(TetherPaths.statusChanged)
                    } else { self.log("sleep log reconciliation could not be saved; prior records retained") }
                }
                let queued = self.sleepLogReadQueued
                self.sleepLogReadQueued = false
                if queued { self.reconcileSleepLog() }
                else if attempt == 0, self.usage.sleeps.recent.contains(where: { $0.darkWakeCountVerified != true }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.reconcileSleepLog(attempt: 1) }
                }
            }
        }
    }

    @discardableResult
    func saveState() -> Bool {
        guard !stateJournalUnreadable else {
            lastApplyError = "stateUnreadable"
            return false
        }
        guard JSONFile.write(state, to: statePath, permissions: 0o600, durable: true) else {
            lastApplyError = "writeFailed"; protection.block("stateWriteFailed"); return false
        }
        return true
    }
}
