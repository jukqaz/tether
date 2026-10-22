import Foundation
import TetherCore

extension Helper {
    func updateDisplay(_ snapshot: Snapshot, clamshellOn: Bool) {
        // Brightness ownership lives in the attached GUI. Neither failure nor
        // unavailability may silently substitute displaysleepnow for its choice.
        // The retained decision also suppresses a fallback while lid teardown
        // completes; it never grants an additional work/closed-lid hold.
        let displayMode = (workLeaseGate.current ?? state.workSessionLease)?.effectiveClosedLidDisplayMode ?? .off
        guard displayMode == .off else { displayGate.reset(); return }
        // A transient lid/power query failure is not a new display incident. Preserve
        // the previous retry budget and stopped state; issue nothing until reads recover.
        guard snapshot.lidControlObservationAvailable else { return }
        let closedHold = clamshellOn && snapshot.observedLidClosed == true
            && snapshot.observedFullWake == true && snapshot.observedSleepDisabled == true
        guard closedHold else { displayGate.reset(); return }
        // A failed topology query is represented conservatively as an external screen,
        // but it is not a verified end of this incident. Preserve spent retries and a
        // stopped recovery latch; a later successful query cannot rearm screen commands.
        guard snapshot.displayTopology != .unknown else { return }
        // A virtual/physical output pauses all-display commands, not the closed-hold
        // incident. Preserve its stopped latch, spent attempts and retry spacing across
        // reconnects; a confirmed open lid or ended hold starts a new incident.
        guard !snapshot.externalDisplay else { return }
        // Display observation and recovery never terminate work or consume a timer.
        // Do not fight a remote framebuffer, video player or any valid display request.
        if foreignDisplayRequestNeedsDeferral() {
            if displayGate.phase != .deferred && displayGate.phase != .stopped {
                log("all-display sleep deferred: foreign screen request present or request query unavailable; work retained")
            }
            displayGate.deferRequests()
            return
        }
        let reading = displaySleepReading()
        let now = dryRun ? (fake["displayClock"] as? Double ?? ProcessInfo.processInfo.systemUptime) : ProcessInfo.processInfo.systemUptime
        let previouslyUnavailable = displayGate.unavailableSince
        let wasStopped = displayGate.phase == .stopped
        let wasPending = displayGate.pending
        let previousRequests = displayGate.requestCount
        let decision = displayGate.evaluate(eligible: true, sleeping: reading.sleeping, now: now)
        if previousRequests > 0, displayGate.requestCount == 0, reading.sleeping == true {
            log("display sleep stable for \(Int(DisplaySleepGate.stableSleepWindow))s with bounded observation gaps; incident recovery budget renewed")
        }
        if previouslyUnavailable == nil, displayGate.unavailableSince != nil {
            log("display observation unavailable; rechecking for up to \(Int(DisplaySleepGate.acknowledgementWindow))s; \(reading.detail)")
        } else if previouslyUnavailable != nil, reading.sleeping == true {
            log("display sleep observation recovered; hold retained; \(reading.detail)")
            log("activity: display sleep confirmed")
        } else if wasPending, reading.sleeping == true {
            log("display sleep confirmed; hold retained; requests=\(displayGate.requestCount)/\(DisplaySleepGate.maximumRequests); \(reading.detail)")
            log("activity: display sleep confirmed")
        }
        switch decision {
        case .none: break
        case .request:
            // A cable/display/lid change may have arrived while processing this pass.
            // In particular, never turn a newly connected external display off on a retry.
            let current = currentSnapshot()
            guard ((workLeaseGate.current ?? state.workSessionLease)?.effectiveClosedLidDisplayMode ?? .off) == .off else {
                displayGate.reset(); return
            }
            guard current.lidControlObservationAvailable, current.power != .unknown else { return }
            guard current.observedLidClosed == true, current.observedFullWake == true,
                  ownsOverride, current.observedSleepDisabled == true,
                  Policy.wantsClamshell(current, enabled: effectiveEnabled,
                    sleepNowPending: Date() < sleepNowUntil, batteryHold: holdWasActive, condition: control.condition,
                    ownsOverride: ownsOverride,
                    manualSession: manualSessionAllowed)
            else { displayGate.reset(); return }
            guard current.displayTopology != .unknown, !current.externalDisplay else { return }
            guard !foreignDisplayRequestNeedsDeferral() else { displayGate.deferRequests(); return }
            if displayGate.requestCount > 1 { log("activity: display recovery requested") }
            log("display-off attempt \(displayGate.requestCount)/\(DisplaySleepGate.maximumRequests); \(reading.detail); \(displayRequestOwners())")
            if !pmset(["displaysleepnow"]) {
                displayGate.stop()
                log("display-off request failed; \(reading.detail)")
                log("activity: display recovery stopped")
            }
        case .conflict:
            let cause = reading.sleeping == false ? "awake observed" : "observation unavailable beyond budget"
            if !wasStopped {
                log("display sleep not maintained; cause=\(cause); \(reading.detail); requests=\(displayGate.requestCount)/\(DisplaySleepGate.maximumRequests); \(displayRequestOwners()); screen recovery exhausted, work retained")
                log("activity: display recovery stopped")
            }
        }
    }

    private func foreignDisplayRequestNeedsDeferral() -> Bool {
        if dryRun { return fake["foreignDisplayRequest"] as? Bool == true || fake["displayRequestsUnavailable"] as? Bool == true }
        let ownPIDs = [getpid(), state.appPID].compactMap { $0 }
        guard let requests = SystemProbe.sleepBlockerSnapshot(excluding: ownPIDs) else { return true }
        return requests.contains { $0.kind == .display }
    }

    private func displayRequestOwners() -> String {
        guard !dryRun else { return "displayRequestPIDs=fixture" }
        guard let blockers = SystemProbe.sleepBlockerSnapshot() else { return "displayRequestPIDs=unavailable" }
        // Do not persist assertion payloads, which can contain document titles or URLs.
        let pids = Set(blockers.filter { $0.kind == .display }.map(\.pid)).sorted()
        return "displayRequestPIDs=" + (pids.isEmpty ? "none" : pids.prefix(16).map(String.init).joined(separator: ","))
    }

    func currentDisplaySleeping() -> Bool? {
        displaySleepReading().sleeping
    }

    private func displaySleepReading() -> (sleeping: Bool?, detail: String) {
        if dryRun, fakePath != nil {
            let value = fake["displaySleeping"] as? Bool
            return (value, "source=fixture sleeping=\(value.map(String.init) ?? "unknown")")
        }
        guard let displays = DisplayProbe.observations() else {
            return (nil, "source=CoreGraphics list=unavailable sleeping=unknown")
        }
        guard let builtIn = displays.first(where: \.builtIn) else {
            return (nil, "source=CoreGraphics onlineCount=\(displays.count) builtIn=absent sleeping=unknown")
        }
        return (builtIn.asleep, "source=CoreGraphics onlineCount=\(displays.count) builtIn=present active=\(builtIn.active) sleeping=\(builtIn.asleep)")
    }
}
