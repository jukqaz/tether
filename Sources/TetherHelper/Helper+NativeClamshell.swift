import Foundation
import TetherCore

extension Helper {
    var fakeDisplayObservations: [DisplayObservation]? {
        guard let raw = fake["displayObservations"],
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode([DisplayObservation].self, from: data)
    }

    /// Never block event/thermal/lease handling on system_profiler. One bounded read is
    /// permitted at a time; a wake/hotplug invalidates any result still in flight.
    func refreshNativeDisplayEvidence() {
        guard supported, !nativeDisplayReadInFlight else { return }
        let snapshot = currentSnapshot()
        let observations = dryRun && fakePath != nil ? fakeDisplayObservations : DisplayProbe.observations()
        guard let generation = nativeDisplayCache.begin(observations: observations,
            power: snapshot.power, fullWake: snapshot.observedFullWake == true) else { return }
        nativeHandoffGate.reset()
        if dryRun {
            let raw = fake["displayProfile"]
            let profile = raw.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            let report = DisplayProbe.resolve(observations: observations, profile: profile)
            _ = nativeDisplayCache.complete(generation: generation, report: report, observations: fakeDisplayObservations)
            return
        }
        nativeDisplayReadInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = DisplayProbe.inspect()
            DispatchQueue.main.async {
                guard let self else { return }
                self.nativeDisplayReadInFlight = false
                _ = self.nativeDisplayCache.complete(generation: generation, report: report,
                    observations: DisplayProbe.observations())
                self.schedule(.timer)
            }
        }
    }

    @discardableResult
    func updateNativeClamshellHandoff(_ snapshot: Snapshot, eligibility: (() -> Bool)? = nil) -> Bool {
        if snapshot.nativeDisplayVerified {
            // A delayed automatic closed-lid request cannot outlive the native handoff.
            // Explicit user/protection sleep retains its independent authorization.
            if sleepRetryIntent == .closedLid { sleepRetryActive = false }
            return false
        }
        let allowed = eligibility?() ?? Policy.wantsClamshell(snapshot, enabled: effectiveEnabled,
            sleepNowPending: Date() < sleepNowUntil, batteryHold: holdWasActive,
            condition: control.condition, ownsOverride: ownsOverride, manualSession: manualSessionAllowed)
        guard nativeHandoffGate.begin(snapshot: snapshot, allowed: allowed, ownsOverride: ownsOverride) else { return false }
        _ = withRecoveryLock {
            let before = currentSnapshot()
            // Recheck after acquiring the writer/recovery lock. Never trial-release a
            // closed lid merely because a physical monitor was reported earlier.
            guard before.observedLidClosed == false, before.observedFullWake == true, before.power == .ac,
                  before.nativeDisplayCandidate, ownsOverride, before.observedSleepDisabled == true,
                  eligibility?() ?? allowed else { return }
            guard applyOverride(false) else {
                log("native clamshell handoff unconfirmed; own recovery record retained")
                return
            }
            let after = currentSnapshot()
            if after.nativeDisplayVerified {
                if sleepRetryIntent == .closedLid { sleepRetryActive = false }
                note(.clamshellReleased)
                log("native clamshell policy observed after own override release; common work unchanged")
                return
            }
            // Connection evidence alone was insufficient. Restore only the same eligible
            // work's lid extension; general assertions/deadlines were never detached.
            if after.fullWake, eligibility?() ?? Policy.wantsClamshell(after, enabled: effectiveEnabled,
                sleepNowPending: Date() < sleepNowUntil, batteryHold: holdWasActive,
                condition: control.condition, ownsOverride: ownsOverride, manualSession: manualSessionAllowed) {
                _ = applyOverride(true)
            }
            log("native clamshell policy unavailable after release; own eligible lid support retained")
        }
        return true
    }
}
