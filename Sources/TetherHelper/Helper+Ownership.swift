import Foundation
import TetherCore

extension Helper {
    var ownershipPath: String { URL(fileURLWithPath: statusPath).deletingLastPathComponent().appendingPathComponent("power-ownership.json").path }
    var recoveryLockPath: String {
        RecoveryLock.path(supportDirectory: URL(fileURLWithPath: statusPath).deletingLastPathComponent().path)
    }
    var writerJournalPath: String {
        URL(fileURLWithPath: statusPath).deletingLastPathComponent().appendingPathComponent("power-writer.json").path
    }

    /// All callers run on the helper's main queue. Nested operations share this transaction.
    func withRecoveryLock<T>(_ action: () -> T) -> T? {
        if recoveryLockDepth > 0 { return action() }
        do {
            let lock: RecoveryLock
            do { lock = try RecoveryLock.acquire(at: recoveryLockPath) }
            catch RecoveryLock.Failure.busy {
                guard PowerWriterJournal.read(writerJournalPath) != .absent,
                      PowerWriterJournal.resolve(writerJournalPath, boot: currentBootID,
                          expectedExecutable: "/usr/bin/pmset", stopExpired: true) == .resolved else {
                    throw RecoveryLock.Failure.busy
                }
                lock = try RecoveryLock.acquire(at: recoveryLockPath)
            }
            guard PowerWriterJournal.clearResolved(writerJournalPath, boot: currentBootID,
                    expectedExecutable: "/usr/bin/pmset") else {
                lastApplyError = "powerWriterUnresolved"
                log("power transaction deferred: previous writer remains unresolved")
                withExtendedLifetime(lock) {}
                return nil
            }
            recoveryLockDepth = 1
            activeRecoveryLock = lock
            defer { activeRecoveryLock = nil; recoveryLockDepth = 0; withExtendedLifetime(lock) {} }
            return action()
        } catch {
            lastApplyError = (error as? RecoveryLock.Failure) == .busy ? "recoveryLockBusy" : "recoveryLockUnavailable"
            log("power transaction deferred: \(lastApplyError!)")
            return nil
        }
    }

    func reloadOwnership() -> Bool {
        var entry = stat()
        if lstat(ownershipPath, &entry) != 0, errno == ENOENT {
            ownership = PowerOwnership(); return true
        }
        guard let latest = JSONFile.read(PowerOwnership.self, from: ownershipPath) else {
            lastApplyError = "ownershipUnreadable"; protection.block("ownershipUnreadable"); return false
        }
        ownership = latest
        return true
    }
    // Simulation has its own boot identity; the live executor always uses the OS boot UUID.
    var currentBootID: String { dryRun ? (fake["bootID"] as? String ?? "dry-run") : ContinuousTime.bootID }
    var ownsOverride: Bool { ownership.isValid(for: currentBootID) && ownership.owned }
    var sessionSuspended: Bool { (enforcesGUIAuthority || state.appSessionRequired == true || control.appPath != nil) && !appSessionAlive }
    var appProcessAlive: Bool {
        guard let pid = state.appPID, let start = state.appStarted,
              let identity = PowerProcessIdentity.read(pid) else { return false }
        return identity.started == start
    }
    var appSessionAlive: Bool {
        appProcessAlive && (!enforcesGUIAuthority || guiAuthority.canPreserveExisting(now: guiClock))
    }

    @discardableResult
    func saveOwnership() -> Bool {
        guard recoveryLockDepth > 0 else { lastApplyError = "recoveryLockUnavailable"; return false }
        guard JSONFile.write(ownership, to: ownershipPath, permissions: 0o600, durable: true) else {
            lastApplyError = "writeFailed"; protection.block("ownershipUnreadable"); return false
        }
        return true
    }

    func observeOwnership(_ snapshot: Snapshot) {
        _ = withRecoveryLock {
            guard reloadOwnership() else { return }
            observeOwnershipLocked(currentSnapshot())
        }
    }

    private func observeOwnershipLocked(_ snapshot: Snapshot) {
        guard let sleepDisabled = snapshot.observedSleepDisabled else { return }
        if let pending = pendingOverrideVerification {
            pendingOverrideVerification = nil
            if pending.ownership == ownership, sleepDisabled == pending.enabled {
                if !pending.enabled { ownership.release(); _ = saveOwnership() }
                log("previous own power write confirmed after observation recovered")
                return
            }
        }
        if ownsOverride, !sleepDisabled {
            ownership.release(); _ = saveOwnership()
            protection.block("powerConflict")
            consumeHold()
            manualSession.end(.protection)
            log("power override changed externally; automatic reapplication suspended")
        }
        if !ownsOverride, sleepDisabled,
           Policy.wantsClamshell(snapshot, enabled: effectiveEnabled, sleepNowPending: false,
                                 batteryHold: holdWasActive, condition: control.condition, manualSession: manualSessionAllowed) {
            protection.block("powerConflict")
            consumeHold()
            manualSession.end(.protection)
            log("existing unowned sleep override: leaving it unchanged")
        }
    }

    @discardableResult
    func applyOverride(_ enabled: Bool) -> Bool {
        withRecoveryLock {
            guard reloadOwnership() else { return false }
            return applyOverrideLocked(enabled)
        } ?? false
    }

    private func applyOverrideLocked(_ enabled: Bool) -> Bool {
        if !enabled, !ownsOverride { return true }
        let before = currentSnapshot()
        guard let sleepDisabled = before.observedSleepDisabled else {
            lastApplyError = "powerObservationUnavailable"
            return false
        }
        if enabled {
            guard systemPowerObservationAvailable, before.observedLidClosed != nil,
                  before.observedFullWake == true, before.power != .unknown else {
                lastApplyError = "powerObservationUnavailable"
                return false
            }
            guard !enforcesGUIAuthority || guiControlConfirmed else { lastApplyError = "guiSessionUnavailable"; return false }
            guard !sleepDisabled, !ownsOverride else { return false }
            guard ownership.acquire(boot: currentBootID) else {
                lastApplyError = "bootSessionUnavailable"
                protection.block("bootSessionUnavailable")
                log("boot session unavailable; refusing an override that cannot be identified for recovery")
                return false
            }
            guard saveOwnership() else { ownership.release(); return false }
        } else {
            guard ownsOverride else { return true }
            if !sleepDisabled { pendingOverrideVerification = nil; ownership.release(); return saveOwnership() }
        }
        // Journal is persisted before the OS write, retained on failures for recovery.
        guard pmset(["-a", "disablesleep", enabled ? "1" : "0"]) else {
            if enabled, writerTerminationConfirmed, currentSnapshot().observedSleepDisabled == false {
                ownership.release(); _ = saveOwnership()
            }
            return false
        }
        let after = currentSnapshot().observedSleepDisabled
        guard after == enabled else {
            if after == nil {
                pendingOverrideVerification = (enabled, ownership)
                lastApplyError = "powerObservationUnavailable"
                return false
            }
            lastApplyError = "powerVerificationFailed"; return false
        }
        pendingOverrideVerification = nil
        if !enabled { ownership.release(); return saveOwnership() }
        return true
    }

    @discardableResult
    func disconnectApp(reason: String) -> Bool {
        finishLidEndBeforeAppDisconnect()
        cancelPendingLidEnd("ownerUnavailable")
        manualSession.end(.sessionEnded)
        workLeaseGate.end()
        workSessionPreparation = nil
        state.workSessionLease = nil
        log("app session disconnected: \(reason); ending temporary work and releasing owned power changes")
        state.appPID = nil; state.appStarted = nil; state.appUID = nil
        state.guiOwner = nil
        if enforcesGUIAuthority { guiAuthority = GUISessionAuthority() }
        sleepNowUntil = .distantPast; sleepRetryActive = false
        pendingTriggers.remove(.sleepNow)
        displayGate.stop()
        state.consumedHold = state.holdValue
        holdWasActive = false
        let stateSaved = saveState()
        var next = control
        next.sleepNowRequest = nil
        next.batteryHoldUntil = nil; next.pendingHoldMinutes = nil; next.holdSource = nil
        let controlSaved = commitControl(next)
        if !controlSaved { protection.block("stateWriteFailed") }
        appExitObserver?.cancel(); appExitObserver = nil
        return stateSaved && controlSaved
    }

    func watchAppExit() {
        appExitObserver?.cancel(); appExitObserver = nil
        guard appProcessAlive, let pid = state.appPID else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.disconnectApp(reason: "process exited")
            self.schedule(.settings)
        }
        source.resume(); appExitObserver = source
    }
}
