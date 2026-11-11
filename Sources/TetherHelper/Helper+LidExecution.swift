import Foundation
import IOKit
import IOKit.pwr_mgt
import TetherCore

struct LidEndExecutionAuthority {
    var action: EndActionAuthority
    var lease: WorkSessionLease
    var power: PowerSource
    var powerGeneration: UInt64
    var guiOwner: GUISessionOwner?
    var appPID: Int32?
    var appStarted: UInt64?
}

/// v3 is an executor of an app decision. Legacy product policy remains isolated
/// behind its old protocol and is never a fallback for a v3 client or restart.
extension Helper {
    var usesV3LidExecution: Bool {
        state.lidExecutionVersion == 3 || workLeaseGate.current?.executionVersion == 3
    }

    var lidExecutionObservationAvailable: Bool {
        if dryRun {
            return systemPowerObservationAvailable
                && fake["powerSourceObservationAvailable"] as? Bool != false
                && fake["lidNotificationAvailable"] as? Bool != false
                && fake["thermalObservationAvailable"] as? Bool != false
        }
        return systemPowerObservationAvailable && powerSourceNotificationsRegistered
            && lidNotificationsRegistered && thermalObserver != nil
    }

    var currentSessionBatteryPermitReceipts: [WorkSessionBatteryPermitReceipt] {
        guard let sessionID = batteryReceiptResponseSessionID else { return [] }
        let receipts = state.batteryPermitReceipts?.filter {
            $0.sessionID == sessionID && $0.isValid(boot: currentBootID) && $0.observedAt <= manualClock
        } ?? []
        return Array(receipts.prefix(128))
    }

    var currentBatteryPermitReceipt: WorkSessionBatteryPermitReceipt? {
        let lease = workLeaseGate.current ?? state.workSessionLease
        let receipts = currentSessionBatteryPermitReceipts
        if let permitID = lease?.lidPermit?.batteryPermitID,
           let current = receipts.first(where: { $0.permitID == permitID }) { return current }
        // Response evidence for an earlier, actually issued ID in this session.
        // Execution still requires the exact current permitID below; this fallback
        // cannot grant a new permit or move its first battery deadline.
        return receipts.last
    }

    /// A terminal receipt identifies evidence after the grant is consumed; it
    /// never replaces the live lease in an execution predicate. A new authenticated
    /// preparation takes priority so an old session cannot leak into a new ACK.
    private var batteryReceiptResponseSessionID: UUID? {
        if let lease = workLeaseGate.current ?? state.workSessionLease { return lease.sessionID }
        if let prepared = workSessionPreparation,
           prepared.isValid(sessionID: prepared.sessionID, epoch: epoch, revision: prepared.revision, now: manualClock) {
            return prepared.sessionID
        }
        var terminal: (sessionID: UUID, observedAt: Double)?
        if let consumed = workSleepConsumption ?? state.workSleepConsumption,
           consumed.isValid(sessionID: consumed.sessionID, sequence: consumed.sequence, now: manualClock, boot: currentBootID) {
            terminal = (consumed.sessionID, consumed.observedAt)
        }
        if let ended = state.lidEndReceipt, ended.phase == .consumed,
           currentBootID != "unknown", !currentBootID.isEmpty, ended.bootID == currentBootID,
           ended.observedAt.isFinite, ended.observedAt >= 0, ended.observedAt <= manualClock,
           terminal.map({ ended.observedAt >= $0.observedAt }) ?? true {
            terminal = (ended.sessionID, ended.observedAt)
        }
        return terminal?.sessionID
    }

    func beginLidExecutorIfNeeded() -> Bool {
        guard state.lidExecutionVersion != 3 else { return true }
        // Stop the old root writer durably before restoring and attaching the
        // new executor. A failed migration cannot reactivate its fallback policy.
        return withRecoveryLock {
            state.lidExecutionVersion = 3; state.userSessionCoordinated = true
            state.workSessionLease = nil
            workLeaseGate.end(); manualSession.end(.sessionEnded)
            holdWasActive = false; holdingOnBattery = false
            guard saveState(), reloadOwnership(), applyOverride(false) else { return false }
            restoreLegacyPowerModes()
            // A known foreign global flag is reported as a lid limitation by
            // the executor, while the app's independent general grant remains
            // representable. We never adopt or clear that foreign value.
            return !ownsOverride && currentSnapshot().observedSleepDisabled != nil
                && state.savedBatteryLowPower == nil && state.savedACLowPower == nil
        } ?? false
    }

    func lidLeaseReasons(snapshot: Snapshot) -> [WorkSessionReason] {
        guard let lease = workLeaseGate.current, lease.executionVersion == 3,
              !systemSleepTransition, !sessionSuspended, state.coordinatedStopPending != true,
              state.lidProtection == nil, protection.blockReason == nil,
              let expiry = lease.expiry, manualClock < expiry, snapshot.power != .unknown else { return [] }
        if snapshot.power == .battery, let permit = lease.lidPermit {
            guard permit.powerScopes.contains(.battery), let receipt = currentBatteryPermitReceipt,
                  receipt.sessionID == lease.sessionID, receipt.permitID == permit.batteryPermitID,
                  receipt.isValid(boot: currentBootID), manualClock < receipt.deadline,
                  permit.batteryDeadline.map({ manualClock < $0 }) ?? true else { return [] }
        }
        return workLeaseGate.reasons(now: manualClock, power: snapshot.power)

    }

    /// Checks only authority and early rejection; no automatic mode or saved
    /// battery budget is recomputed in this executor.
    func validateLidLease(_ lease: WorkSessionLease) -> String? {
        guard lease.executionVersion == 3 else { return nil }
        if !lease.reasons.isEmpty, lease.lidPermit != nil, !lidExecutionObservationAvailable {
            return "powerObservationUnavailable"
        }
        if !lease.reasons.isEmpty, lease.lidPermit != nil {
            let snapshot = currentSnapshot(), readings = currentReadings()
            guard snapshot.power != .unknown, snapshot.observedLidClosed != nil,
                  snapshot.observedSleepDisabled != nil, (0...3).contains(readings.thermal),
                  lease.configuration.stopOnLowPowerMode != true || lidLowPowerMode != nil else {
                return "powerObservationUnavailable"
            }
        }
        if let receipt = state.lidEndReceipt, receipt.bootID == currentBootID,
           receipt.sessionID == lease.sessionID, !lease.reasons.isEmpty,
           lease.endConsumptionID != receipt.id || lease.sequence <= receipt.sequence {
            return "lidLeaseRevoked"
        }
        if let latch = state.lidProtection, !lease.reasons.isEmpty {
            guard lease.protectionResumeID == latch.id else { return "safetyBlocked" }
            let snapshot = currentSnapshot(), readings = currentReadings()
            guard (0..<2).contains(readings.thermal), snapshot.power != .unknown,
                  snapshot.observedFullWake == true,
                  snapshot.power != .battery || SafetyPolicy.canStartHold(batteryPercent: readings.batteryPercent,
                                                                            user: lease.configuration.limits,
                                                                            lowPowerWarning: readings.lowPowerWarning),
                  !enforcesGUIAuthority || guiControlConfirmed else { return "safetyBlocked" }
        }
        if !lease.reasons.isEmpty, lease.lidPermit != nil, currentSnapshot().power == .battery {
            let readings = currentReadings()
            guard readings.lowPowerWarning != nil,
                  readings.batteryPercent.map({ (0...100).contains($0) }) == true else {
                return "powerObservationUnavailable"
            }
            guard SafetyPolicy.canStartHold(batteryPercent: readings.batteryPercent, user: lease.configuration.limits,
                                            lowPowerWarning: readings.lowPowerWarning) else { return "safetyBlocked" }
        }
        if let permit = lease.lidPermit, let id = permit.batteryPermitID,
           let receipt = state.batteryPermitReceipts?.first(where: { $0.permitID == id && $0.bootID == currentBootID }) {
            guard receipt.sessionID == lease.sessionID, receipt.isValid(boot: currentBootID) else { return "invalidWorkLease" }
            if currentSnapshot().power == .battery, manualClock >= receipt.deadline { return "batteryPermitExpired" }
        }
        return nil
    }

    /// The existing helper-state journal stores the one-use deadline before the
    /// first battery continuation. A later lease may only shorten that record.
    @discardableResult
    func fixBatteryPermit(_ lease: WorkSessionLease, snapshot: Snapshot) -> Bool {
        guard snapshot.power == .battery, let permit = lease.lidPermit,
              permit.powerScopes.contains(.battery), let id = permit.batteryPermitID else { return true }
        let selected = permit.batteryTimeLimit ?? lease.configuration.effectiveBatteryTimeLimit
        let duration = permit.batteryDuration ?? selected.seconds ?? .greatestFiniteMagnitude
        var receipts = state.batteryPermitReceipts ?? []
        receipts.removeAll { $0.bootID != currentBootID || $0.sessionID != lease.sessionID }
        if let index = receipts.firstIndex(where: { $0.permitID == id }) {
            let existing = receipts[index]
            guard existing.isValid(boot: currentBootID), manualClock >= existing.observedAt else {
                lastApplyError = "invalidWorkLease"; return false
            }
            let maximum = min(existing.maximumDeadline ?? selected.seconds.map { existing.observedAt + $0 } ?? .greatestFiniteMagnitude,
                              permit.batteryMaximumDeadline ?? .greatestFiniteMagnitude)
            let committedExtension = permit.extensionID != existing.extensionID
                && permit.extensionID == lease.manualExtensionID && lease.manualRequestID == id
            receipts[index].deadline = min(committedExtension ? maximum : existing.deadline,
                                          permit.batteryDeadline ?? .greatestFiniteMagnitude, maximum)
            receipts[index].maximumDeadline = maximum
            receipts[index].extensionID = permit.extensionID
        } else {
            // Bound retained metadata without evicting a used ID inside a live
            // session. A new authenticated session can start fresh requests.
            guard receipts.count < 128 else { lastApplyError = "permitHistoryFull"; return false }
            let maximum = min(selected.seconds.map { manualClock + $0 } ?? .greatestFiniteMagnitude,
                              permit.batteryMaximumDeadline ?? .greatestFiniteMagnitude)
            let deadline = min(duration == .greatestFiniteMagnitude ? duration : manualClock + duration,
                               permit.batteryDeadline ?? .greatestFiniteMagnitude, maximum)
            guard deadline > manualClock else { lastApplyError = "batteryPermitExpired"; return false }
            receipts.append(WorkSessionBatteryPermitReceipt(bootID: currentBootID,
                sessionID: lease.sessionID, permitID: id, observedAt: manualClock, deadline: deadline,
                extensionID: permit.extensionID, maximumDeadline: maximum, batteryTimeLimit: selected))
        }
        if receipts == state.batteryPermitReceipts {
            prepareBatteryEnd(lease, receipts: receipts)
            return true
        }
        let previous = state.batteryPermitReceipts
        state.batteryPermitReceipts = receipts
        guard saveState() else { state.batteryPermitReceipts = previous; return false }
        prepareBatteryEnd(lease, receipts: receipts)
        log("battery permit fixed: \(id.uuidString); deadline=\(receipts.first { $0.permitID == id }!.deadline)")
        return true
    }

    @discardableResult
    func captureLidEnd(_ kind: WorkSessionEndReceipt.Kind, action: WorkSessionEndAction,
                       approvedLease: WorkSessionLease? = nil, endDeadline: Double? = nil) -> Bool {
        let lease = approvedLease ?? workLeaseGate.current
        guard let lease else { return false }
        // An already terminal grant cannot create a second event from a timer,
        // duplicated notification or recovery of its old lease.
        if let previous = state.lidEndReceipt, previous.sessionID == lease.sessionID,
           previous.sequence >= lease.sequence { return false }
        let snapshot = currentSnapshot()
        observeLidEndPowerBoundary(snapshot)
        let causeTime = endDeadline.map { $0 - EndActionAuthority.cleanupWindow } ?? manualClock
        state.lidEndReceipt = WorkSessionEndReceipt(bootID: currentBootID,
            sessionID: lease.sessionID, sequence: lease.sequence, observedAt: causeTime,
            kind: kind, action: action)
        let authority = EndActionAuthority(causeID: state.lidEndReceipt!.id, observedAt: causeTime)
        state.lidEndReceipt?.cleanupDeadline = authority.cleanupDeadline
        workLeaseGate.end(); workSessionPreparation = nil; state.workSessionLease = nil
        workExtensionPreparationReceipt = nil; workExtensionRollback = nil; lidManagedSessionID = nil
        lidRestoreAttemptCount = 0; lidRestoreFailure = nil
        lidLeaseTimer?.cancel(); lidLeaseTimer = nil
        sleepNowUntil = .distantPast; sleepRetryActive = false
        pendingTriggers.remove(.sleepNow)
        revision &+= 1
        replyCache.removeAll { [.prepareWorkSession, .attachWorkSession, .syncWorkSession].contains($0.1.action) }
        guard saveState() else { protection.block("stateWriteFailed"); return false }
        lidEndAuthority = LidEndExecutionAuthority(action: authority, lease: lease,
            power: snapshot.power, powerGeneration: lidPowerGeneration,
            guiOwner: state.guiOwner, appPID: state.appPID, appStarted: state.appStarted)
        batteryEndPreparation = nil
        log("lid execution ended: \(kind.rawValue); old grant revoked; GUI assertion release unconfirmed")
        return true
    }

    private func prepareBatteryEnd(_ lease: WorkSessionLease, receipts: [WorkSessionBatteryPermitReceipt]) {
        guard let id = lease.lidPermit?.batteryPermitID,
              let receipt = receipts.first(where: { $0.permitID == id }),
              let deadline = SleepRequestPolicy.approvedBatteryEndDeadline(lease: lease, receipt: receipt,
                  boot: currentBootID, now: manualClock) else { return }
        batteryEndPreparation = (lease, deadline)
    }

    func cancelPendingLidEnd(_ outcome: String) {
        batteryEndPreparation = nil
        lidEndAuthority = nil
        guard var receipt = state.lidEndReceipt, receipt.phase != .consumed else { return }
        receipt.phase = .consumed; receipt.outcome = outcome
        state.lidEndReceipt = receipt
        _ = saveState()
        sleepDeferralReason = outcome
    }

    private func captureBatteryEndIfDue(snapshot: Snapshot) {
        guard let prepared = batteryEndPreparation, manualClock >= prepared.deadline else { return }
        batteryEndPreparation = nil
        guard ownsOverride, snapshot.power == .battery,
              manualClock <= prepared.deadline + SleepRequestPolicy.maximumEndActionDelay,
              state.coordinatedStopPending != true, appProcessAlive, !sessionSuspended,
              !enforcesGUIAuthority || guiControlConfirmed,
              workSessionPreparation.map({ $0.sessionID == prepared.lease.sessionID }) ?? true,
              workLeaseGate.current.map({ $0.sessionID == prepared.lease.sessionID }) ?? true,
              lidLeaseReasons(snapshot: snapshot).isEmpty else { return }
        _ = captureLidEnd(.batteryExpired, action: prepared.lease.lidPermit!.disconnectAction,
            approvedLease: prepared.lease,
            endDeadline: prepared.deadline + SleepRequestPolicy.maximumEndActionDelay)
    }

    /// A live controller's detach can race its power notification. Finish an
    /// already observed unplug before discarding the original owner; a dead or
    /// changed GUI never gets a new end permission from this cleanup path.
    func finishLidEndBeforeAppDisconnect() {
        guard usesV3LidExecution, appProcessAlive, !sessionSuspended,
              !enforcesGUIAuthority || guiControlConfirmed else { return }
        _ = withRecoveryLock {
            guard reloadOwnership() else { return }
            let snapshot = currentSnapshot()
            if let lease = workLeaseGate.current, ownsOverride,
               snapshot.power == .battery, snapshot.observedLidClosed == true,
               lastLidLeasePower == .ac, lease.power == .ac,
               lease.expiry.map({ manualClock < $0 }) == true,
               !workLeaseGate.reasons(now: manualClock, power: .ac).isEmpty,
               lease.lidPermit?.powerScopes.contains(.ac) == true,
               lidLeaseReasons(snapshot: snapshot).isEmpty {
                _ = captureLidEnd(.disconnect, action: lease.lidPermit!.disconnectAction)
            }
            if let receipt = state.lidEndReceipt, receipt.phase != .consumed { finishLidEnd(receipt) }
        }
    }

    /// Incoming empty work has no execution scope. Only its explicit power-end
    /// intent may preserve our still-live AC-only permit; no saved setting,
    /// foreign assertion or display fact can create an incident here.
    func captureLidDisconnectBeforeReplacing(with lease: WorkSessionLease) -> Bool {
        if let endedID = lease.manualTaskEndRequestID, lease.executionVersion == 3,
           lease.reasons.isEmpty, lease.power == .battery,
           let previous = workLeaseGate.current, previous.power == .battery, previous.manualRequestID == endedID,
           previous.reasons.contains(.manual), previous.expiry.map({ manualClock < $0 }) == true,
           let permit = previous.lidPermit {
            return withRecoveryLock {
                guard reloadOwnership() else { return false }
                let snapshot = currentSnapshot()
                guard (ownsOverride || lidManagedSessionID == previous.sessionID),
                      snapshot.power == .battery, snapshot.observedLidClosed == true,
                      snapshot.observedFullWake == true, appProcessAlive, !sessionSuspended,
                      !enforcesGUIAuthority || guiControlConfirmed else { return true }
                return captureLidEnd(.taskEnded, action: permit.disconnectAction, approvedLease: previous)
            } ?? false
        }
        guard lease.executionVersion == 3, lease.disconnectEndRequested == true,
              lease.reasons.isEmpty, lease.power == .battery, lease.configuration.enabled,
              let previous = workLeaseGate.current, previous.executionVersion == 3,
              previous.power == .ac, previous.expiry.map({ manualClock < $0 }) == true,
              previous.reasons.contains(where: { $0 != .manual || previous.manualDeadline.map({ manualClock < $0 }) ?? true }),
              let permit = previous.lidPermit, permit.powerScopes.contains(.ac),
              lastLidLeasePower == .ac else { return true }
        return withRecoveryLock {
            guard reloadOwnership() else { return false }
            let snapshot = currentSnapshot(), readings = currentReadings()
            guard ownsOverride || lidManagedSessionID == previous.sessionID,
                  snapshot.power == .battery, snapshot.observedLidClosed == true,
                  snapshot.observedFullWake == true, lidExecutionObservationAvailable,
                  !systemSleepTransition, !sessionSuspended, appProcessAlive,
                  !enforcesGUIAuthority || guiControlConfirmed,
                  state.coordinatedStopPending != true, state.lidProtection == nil,
                  protection.blockReason == nil, lidProtectionReason(snapshot: snapshot, readings: readings) == nil,
                  (0..<2).contains(readings.thermal) else { return true }
            return captureLidEnd(.disconnect, action: permit.disconnectAction)
        } ?? false
    }

    func evaluateLidLease(snapshot initial: Snapshot, readings initialReadings: SafetyReadings, triggers: Set<Trigger>) {
        // v3 has one actual-expiry timer; the old fast policy/sleep loops stop.
        fastTimer?.cancel(); fastTimer = nil
        closedLidSleep.reset(); sleepRetryActive = false
        restoreLegacyPowerModes()
        if state.appPID != nil, !appProcessAlive { _ = disconnectApp(reason: "process no longer alive") }
        _ = withRecoveryLock {
            guard reloadOwnership() else { return }
            var snapshot = currentSnapshot()
            observeLidEndPowerBoundary(snapshot)
            // A busy recovery lock has not processed this power boundary. Keep
            // the prior AC observation so the next successful transaction can
            // capture the same unplug incident before releasing the override.
            let observedPower = snapshot.power
            defer { if observedPower != .unknown { lastLidLeasePower = observedPower } }
            let readings = currentReadings()
            // A positively accepted Stop outranks unknown-observation grace.
            // Explicit Sleep already consumed its live grant into a separate
            // end authority, so this branch cannot discard that one-shot action.
            if state.coordinatedStopPending == true, let active = workLeaseGate.current,
               !active.reasons.isEmpty {
                workLeaseGate.end(); workSessionPreparation = nil; state.workSessionLease = nil
                workExtensionPreparationReceipt = nil; workExtensionRollback = nil
                batteryEndPreparation = nil; lidManagedSessionID = nil
                lidLeaseTimer?.cancel(); lidLeaseTimer = nil
                cancelPendingLidEnd("cancelled")
                sleepNowUntil = .distantPast; sleepRetryActive = false
                pendingTriggers.remove(.sleepNow)
                _ = saveState()
                // A failed read/write retains the ownership journal and retry
                // debt; consuming work never claims that OS restoration passed.
                _ = restoreLidOverride()
                return
            }
            let observationsHealthy = snapshot.power != .unknown && (0..<lidThermalStopThreshold).contains(readings.thermal)
                && snapshot.observedFullWake == true && appProcessAlive
                && (workLeaseGate.current?.lidPermit == nil || (snapshot.observedSleepDisabled != nil && snapshot.observedLidClosed != nil))
                && (workLeaseGate.current?.configuration.stopOnLowPowerMode != true || lidLowPowerMode != nil)
                && (!enforcesGUIAuthority || guiControlConfirmed)
                && (snapshot.power != .battery || (readings.batteryPercent.map { (0...100).contains($0) } == true
                    && readings.lowPowerWarning != nil))
            if observationsHealthy {
                lastHealthyLidObservationAt = manualClock; lastHealthyLidSnapshot = snapshot
            }
            // A dual-scope AC grant already approves the first bounded battery
            // use. Fix that first anchor before deciding whether unplug ends it;
            // this does not renew its original finite health expiry.
            var boundaryGate = workLeaseGate
            boundaryGate.observeTransition(now: manualClock, power: snapshot.power)
            if snapshot.power == .battery, observationsHealthy,
               !boundaryGate.reasons(now: manualClock, power: .battery).isEmpty,
               let active = workLeaseGate.current,
               !fixBatteryPermit(active, snapshot: snapshot) {
                workLeaseGate.end(); state.workSessionLease = nil; workSessionPreparation = nil
                protection.block(lastApplyError ?? "stateWriteFailed")
                _ = saveState(); _ = saveProtection(); _ = restoreLidOverride()
                return
            }
            workLeaseGate.observeTransition(now: manualClock, power: snapshot.power)
            let live = workLeaseGate.current
            let priorOwned = ownsOverride
            // Consume the power boundary even with the lid open or a stale
            // battery continuation field. It must not reacquire old work after
            // reconnecting while the GUI notification is delayed.
            if let live, lastLidLeasePower == .ac, snapshot.power == .battery,
               live.expiry.map({ manualClock < $0 }) == true, !live.reasons.isEmpty,
               workLeaseGate.reasons(now: manualClock, power: .battery).isEmpty {
                if live.reasons.allSatisfy({ $0 == .manual && !(live.manualDeadline.map { manualClock < $0 } ?? true) }) {
                    // The manual endpoint already ended the last reason. Consume
                    // its stale grant without inventing a new terminal Sleep.
                    workLeaseGate.end(); workSessionPreparation = nil; state.workSessionLease = nil
                    workExtensionPreparationReceipt = nil; workExtensionRollback = nil
                    batteryEndPreparation = nil; lidManagedSessionID = nil
                    lidLeaseTimer?.cancel(); lidLeaseTimer = nil
                    guard saveState() else { protection.block("stateWriteFailed"); _ = applyOverride(false); return }
                } else {
                    let managed = priorOwned || lidManagedSessionID == live.sessionID
                    _ = captureLidEnd(.disconnect,
                        action: managed && snapshot.observedLidClosed == true
                            ? (live.lidPermit?.disconnectAction ?? .followOS) : .followOS)
                }
            }
            // Unknown does not manufacture an unplug/protection event. Preserve
            // only an already-owned finite grant; never acquire or renew here.
            // Freshly confirmed unplug and known protection always win first.
            let confirmedProtection = (lidThermalStopThreshold...3).contains(readings.thermal)
                || (workLeaseGate.current?.configuration.stopOnLowPowerMode == true && lidLowPowerMode == true)
                || (snapshot.power == .battery && readings.batteryPercent != nil && readings.lowPowerWarning != nil
                    && (readings.lowPowerWarning == true || !SafetyPolicy.canStartHold(batteryPercent: readings.batteryPercent, user: limits)))
            if !observationsHealthy, !confirmedProtection, let active = workLeaseGate.current,
               !active.reasons.isEmpty {
                let origin = lastHealthyLidObservationAt
                let prior = lastHealthyLidSnapshot
                let finiteExpiry = active.expiry ?? manualClock
                let observationExpiry = origin.map { $0 + IdleSessionPolicy.healthTTL } ?? manualClock
                let scopePower = snapshot.power == .unknown ? prior?.power ?? .unknown : snapshot.power
                // Unknown readback is not an observed false. Preserve only the
                // already owned journal/finite grant; do not assert an OS effect
                // or issue another writer until fresh verification returns.
                let canPreserve = (active.lidPermit == nil || (ownsOverride && snapshot.observedSleepDisabled != false))
                    && origin.map { manualClock >= $0 } == true
                    && manualClock < min(finiteExpiry, observationExpiry)
                    && !workLeaseGate.reasons(now: manualClock, power: scopePower).isEmpty
                    && appProcessAlive && (!enforcesGUIAuthority || guiAuthority.canPreserveExisting(now: guiClock))
                    && snapshot.observedFullWake != false && !systemSleepTransition
                if canPreserve { armLidLeaseDeadline(); return }
                workLeaseGate.end(); state.workSessionLease = nil; workSessionPreparation = nil
                batteryEndPreparation = nil; workExtensionPreparationReceipt = nil; workExtensionRollback = nil
                cancelPendingLidEnd("powerObservationUnavailable")
                protection.block("powerObservationUnavailable")
                state.lidProtection = WorkSessionProtectionLatch(bootID: currentBootID,
                    reason: "powerObservationUnavailable", observedAt: manualClock,
                    sessionID: active.sessionID, sequence: active.sequence)
                _ = saveState(); _ = saveProtection(); _ = restoreLidOverride()
                return
            }
            if let live, !live.reasons.isEmpty, let reason = lidProtectionReason(snapshot: snapshot, readings: readings) {
                if state.lidProtection == nil {
                    state.lidProtection = WorkSessionProtectionLatch(bootID: currentBootID,
                        reason: reason, observedAt: manualClock, sessionID: live.sessionID, sequence: live.sequence)
                }
                protection.block(reason)
                // Persist the protection marker before an OS write or any Sleep.
                guard saveState(), saveProtection() else {
                    workLeaseGate.end(); _ = applyOverride(false); return
                }
                // The gate retains an expired grant as evidence. Protection may
                // still latch, but only a current reason can authorize its Sleep.
                // Check the original power so a live AC grant can protect an
                // unplug transition before the GUI publishes its empty decision.
                if !workLeaseGate.reasons(now: manualClock, power: live.power).isEmpty {
                    captureLidEnd(.protection, action: live.lidPermit?.protectiveAction ?? .followOS)
                }
            } else if let live = workLeaseGate.current, live.lidPermit != nil {
                let batteryFixed = fixBatteryPermit(live, snapshot: snapshot)
                let validBattery = batteryFixed && !lidLeaseReasons(snapshot: snapshot).isEmpty
                    && live.lidPermit?.powerScopes.contains(.battery) == true
                // Match the GUI-first path: an expired grant or ended manual
                // reason may release our override, but cannot authorize a new Sleep.
                if (priorOwned || lidManagedSessionID == live.sessionID), lastLidLeasePower == .ac, snapshot.power == .battery, !validBattery,
                   live.expiry.map({ manualClock < $0 }) == true,
                   live.reasons.contains(where: { $0 != .manual || live.manualDeadline.map({ manualClock < $0 }) ?? true }) {
                    captureLidEnd(.disconnect, action: live.lidPermit!.disconnectAction)
                }
            }

            captureBatteryEndIfDue(snapshot: snapshot)
            // Reconcile an earlier accepted-but-unreadable own write before
            // treating a changed value as a foreign conflict.
            // Foreign global state matters only to a requested lid extension.
            // General-only work must not inherit the legacy clamshell policy.
            if ownsOverride || pendingOverrideVerification != nil { observeOwnership(snapshot) }
            if let receipt = state.lidEndReceipt, receipt.phase != .consumed {
                finishLidEnd(receipt)
            } else {
                snapshot = currentSnapshot()
                let wanted = workLeaseGate.current?.lidPermit != nil && !lidLeaseReasons(snapshot: snapshot).isEmpty
                let readingsOK = (0..<lidThermalStopThreshold).contains(readings.thermal) && (snapshot.power != .battery
                    || SafetyPolicy.canStartHold(batteryPercent: readings.batteryPercent, user: limits,
                                                lowPowerWarning: readings.lowPowerWarning))
                let acquisitionScoped = ownsOverride || workLeaseGate.current?.power == snapshot.power
                    || (!lidLeaseReasons(snapshot: snapshot).isEmpty && workLeaseGate.current?.lidPermit?.powerScopes.contains(snapshot.power) == true)
                // An unknown GUI observation may preserve only the already-owned
                // value inside its original authority/lease deadlines. Acquisition,
                // lease renewal and terminal Sleep still require confirmed GUI control.
                let canKeepOwnedGUI = ownsOverride && snapshot.observedSleepDisabled == true
                    && guiAuthority.canPreserveExisting(now: guiClock)
                let canExecute = wanted && acquisitionScoped && readingsOK && lidExecutionObservationAvailable && !sessionSuspended
                    && (!enforcesGUIAuthority || guiControlConfirmed || canKeepOwnedGUI) && snapshot.lidControlObservationAvailable
                    && snapshot.observedFullWake == true && state.savedBatteryLowPower == nil && state.savedACLowPower == nil
                if !canExecute { _ = restoreLidOverride() }
                else {
                    // The executor uses the same verified native handoff as the
                    // legacy backend, but only its current finite grant can
                    // authorize the trial and any restoration after that trial.
                    let attemptedHandoff = updateNativeClamshellHandoff(snapshot, eligibility: { self.canHandoffLidLease() })
                    snapshot = currentSnapshot()
                    if !attemptedHandoff, !ownsOverride, !snapshot.nativeDisplayVerified,
                       !snapshot.nativeDisplayProbePending, lastApplyError == nil {
                        if snapshot.observedSleepDisabled == true {
                            protection.block("powerConflict"); _ = saveProtection()
                        } else { _ = applyOverride(true) }
                    }
                }
            }
            armLidLeaseDeadline()
            updateAuthorizedLidDisplay()
        }
        let clamshellOn = ownsOverride && currentSnapshot().observedSleepDisabled == true
        if clamshellOn, let live = workLeaseGate.current { lidManagedSessionID = live.sessionID }
        // Usage observation is independent from the bounded display action above.
        updateUsage(currentSnapshot(), clamshellOn: clamshellOn, readings: initialReadings)
        _ = saveProtection()
        writeStatus(readings: currentReadings())
    }

    /// Reuse the existing evaluation/finite lease timer, never a display loop.
    /// A preserved grant under missing observations authorizes no new display
    /// write. Only the recovery-lock transaction that freshly confirms our live
    /// closed-lid override may apply the selected display behavior.
    private func updateAuthorizedLidDisplay() {
        guard recoveryLockDepth > 0 else { return }
        let snapshot = currentSnapshot(), readings = currentReadings()
        let noPendingEnd = state.lidEndReceipt.map { $0.phase == .consumed } ?? true
        let live = workLeaseGate.current
        let healthyBattery = snapshot.power != .battery
            || (readings.batteryPercent.map { (0...100).contains($0) } == true
                && SafetyPolicy.canStartHold(batteryPercent: readings.batteryPercent,
                    user: limits, lowPowerWarning: readings.lowPowerWarning))
        guard noPendingEnd, state.coordinatedStopPending != true,
              !systemSleepTransition, !sessionSuspended,
              state.lidProtection == nil, protection.blockReason == nil,
              appProcessAlive, !enforcesGUIAuthority || guiControlConfirmed,
              lidExecutionObservationAvailable, snapshot.lidControlObservationAvailable,
              snapshot.power != .unknown, snapshot.observedFullWake == true,
              snapshot.observedLidClosed == true, ownsOverride,
              snapshot.observedSleepDisabled == true,
              live?.executionVersion == 3, live?.lidPermit != nil,
              live?.expiry.map({ manualClock < $0 }) == true,
              !lidLeaseReasons(snapshot: snapshot).isEmpty,
              (0..<lidThermalStopThreshold).contains(readings.thermal), healthyBattery,
              live?.configuration.stopOnLowPowerMode != true || lidLowPowerMode == false,
              state.savedBatteryLowPower == nil, state.savedACLowPower == nil else {
            // Only a positively observed incident end resets retry accounting;
            // unknown facts must not silently replenish its recovery budget.
            if snapshot.observedLidClosed == false
                || (!ownsOverride && snapshot.observedSleepDisabled == false) {
                displayGate.reset()
            }
            return
        }
        updateDisplay(snapshot, clamshellOn: true)
    }

    private func canHandoffLidLease() -> Bool {
        let snapshot = currentSnapshot(), readings = currentReadings()
        return workLeaseGate.current?.lidPermit != nil && !lidLeaseReasons(snapshot: snapshot).isEmpty
            && workLeaseGate.current?.power == snapshot.power && snapshot.power == .ac
            && (0..<lidThermalStopThreshold).contains(readings.thermal) && lidExecutionObservationAvailable
            && !sessionSuspended && appProcessAlive && (!enforcesGUIAuthority || guiControlConfirmed)
            && snapshot.lidControlObservationAvailable && snapshot.observedFullWake == true
            && state.savedBatteryLowPower == nil && state.savedACLowPower == nil
    }

    private var lidThermalStopThreshold: Int {
        workLeaseGate.current?.configuration.stopOnSeriousThermal == false ? 3 : 2
    }
    private var lidLowPowerMode: Bool? {
        if dryRun { return fake.keys.contains("lowPowerMode") ? fake["lowPowerMode"] as? Bool : false }
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    private func lidProtectionReason(snapshot: Snapshot, readings: SafetyReadings) -> String? {
        if (lidThermalStopThreshold...3).contains(readings.thermal) { return "thermal" }
        if workLeaseGate.current?.configuration.stopOnLowPowerMode == true {
            if lidLowPowerMode == true { return "lowPowerMode" }
            if lidLowPowerMode == nil { return "powerObservationUnavailable" }
        }
        guard snapshot.power == .battery else { return nil }
        guard readings.isValid, let warning = readings.lowPowerWarning else { return "sensor" }
        return warning || !SafetyPolicy.canStartHold(batteryPercent: readings.batteryPercent, user: limits) ? "battery" : nil
    }

    /// Changes of a confirmed supply are lineage boundaries. Unknown is not a
    /// fabricated unplug, but can never authorize a terminal effect.
    private func observeLidEndPowerBoundary(_ snapshot: Snapshot) {
        guard snapshot.power != .unknown else { return }
        if let previous = lastLidBoundaryPower, previous != snapshot.power { lidPowerGeneration &+= 1 }
        lastLidBoundaryPower = snapshot.power
    }

    private func lidEndLineageValid(_ execution: LidEndExecutionAuthority,
                                    receipt: WorkSessionEndReceipt, snapshot: Snapshot) -> Bool {
        observeLidEndPowerBoundary(snapshot)
        let currentWork = workLeaseGate.current
        let superseded = currentWork.map { $0.sessionID != receipt.sessionID || !$0.reasons.isEmpty } == true
            || workSessionPreparation.map { $0.sessionID != receipt.sessionID } == true
        // Opening the lid cancels only a conditional closed-lid action. Explicit
        // user Sleep remains usable on an open Mac; power/owner changes still cancel.
        let conditionalBoundary = receipt.kind != .user && snapshot.observedLidClosed != true
        return receipt.bootID == currentBootID && execution.action.causeID == receipt.id
            && execution.lease.sessionID == receipt.sessionID && execution.lease.sequence == receipt.sequence
            && execution.powerGeneration == lidPowerGeneration && execution.power == snapshot.power
            && execution.guiOwner == state.guiOwner && execution.appPID == state.appPID
            && execution.appStarted == state.appStarted && !superseded && !conditionalBoundary
            && snapshot.power != .unknown && lidExecutionObservationAvailable
            && snapshot.observedFullWake == true && !systemSleepTransition
            && appProcessAlive && !sessionSuspended && (!enforcesGUIAuthority || guiControlConfirmed)
            && (!dryRun || fake["finalOwnerUnavailable"] as? Bool != true)
            && (receipt.kind == .user || state.coordinatedStopPending != true)
    }

    private func lidEndFactsAllow(_ receipt: WorkSessionEndReceipt, snapshot: Snapshot,
                                  readings: SafetyReadings) -> Bool {
        let batteryProtectionActive = state.lidProtection?.reason == "battery"
            && lidProtectionReason(snapshot: snapshot, readings: readings) == "battery"
        let finalFactsValid = receipt.kind == .user || ((0...3).contains(readings.thermal)
            && (snapshot.power != .battery || (readings.batteryPercent.map({ (0...100).contains($0) }) == true
                && readings.lowPowerWarning != nil)))
        return finalFactsValid && SleepRequestPolicy.allowsCoordinatedEnd(receipt.kind, action: receipt.action,
            snapshot: snapshot, ownerConfirmed: true,
            restoreConfirmed: !ownsOverride && snapshot.observedSleepDisabled == false,
            batteryPermitValid: !lidLeaseReasons(snapshot: snapshot).isEmpty
                || (dryRun && fake["finalBatteryPermitValid"] as? Bool == true),
            thermal: readings.thermal, observerConfirmed: lidExecutionObservationAvailable && !systemSleepTransition,
            batteryProtectionActive: batteryProtectionActive)
    }

    /// Consume work immediately; cleanup may continue without renewing that work.
    /// Restoration after the cleanup boundary is still useful but never mints Sleep.
    private func finishLidEnd(_ incident: WorkSessionEndReceipt) {
        guard recoveryLockDepth > 0, state.lidEndReceipt?.id == incident.id else { return }
        var receipt = incident
        let snapshot = currentSnapshot()
        guard var execution = lidEndAuthority,
              execution.action.canCleanUp(now: manualClock),
              lidEndLineageValid(execution, receipt: receipt, snapshot: snapshot) else {
            let expired = lidEndAuthority.map { !($0.action.canCleanUp(now: manualClock)) } ?? true
            cancelPendingLidEnd(expired ? "endAuthorityExpired" : "cancelled")
            // New work owns the new decision; do not release its resources here.
            if workLeaseGate.current?.reasons.isEmpty ?? true { _ = restoreLidOverride() }
            return
        }
        let restored = restoreLidOverride()
        let afterRestore = currentSnapshot()
        guard restored, !ownsOverride, afterRestore.observedSleepDisabled == false else {
            receipt.phase = ownsOverride ? .captured : .consumed
            receipt.outcome = afterRestore.observedSleepDisabled == true && !ownsOverride ? "foreignGlobalOverride" : "restoreUnverified"
            state.lidEndReceipt = receipt; _ = saveState()
            if receipt.phase == .consumed { lidEndAuthority = nil }
            sleepDeferralReason = receipt.outcome
            return
        }
        receipt.phase = .restored; state.lidEndReceipt = receipt
        guard saveState() else { return }
        let final = finalLidEndSnapshot(), readings = finalLidEndReadings()
        guard lidEndLineageValid(execution, receipt: receipt, snapshot: final),
              lidEndFactsAllow(receipt, snapshot: final, readings: readings),
              execution.action.issue(now: manualClock) else {
            cancelPendingLidEnd(execution.action.canCleanUp(now: manualClock) ? "cancelled" : "endAuthorityExpired")
            return
        }
        receipt.actionID = execution.action.actionID
        receipt.actionIssuedAt = execution.action.issuedAt
        receipt.actionDeadline = execution.action.actionDeadline
        // Persist one-shot consumption before the effect. Neither a crash nor a
        // late response may replay this action or resurrect the original work.
        guard execution.action.consume(now: manualClock) else { cancelPendingLidEnd("endAuthorityExpired"); return }
        receipt.phase = .consumed; receipt.outcome = "requestCommitted"
        state.lidEndReceipt = receipt; lidEndAuthority = execution
        guard saveState() else { lidEndAuthority = nil; return }
        func canDispatch() -> Bool {
            let facts = finalLidEndSnapshot(dispatch: true)
            return state.lidEndReceipt?.id == receipt.id && lidEndAuthority?.action.actionID == receipt.actionID
                && execution.action.canDispatch(now: manualClock)
                && lidEndLineageValid(execution, receipt: receipt, snapshot: facts)
                && lidEndFactsAllow(receipt, snapshot: facts, readings: finalLidEndReadings())
        }
        guard canDispatch() else {
            lidEndAuthority = nil; receipt.outcome = "endActionCancelled"
            state.lidEndReceipt = receipt; _ = saveState(); sleepDeferralReason = receipt.outcome
            return
        }
        let result: IOReturn
        if dryRun {
            log("[dry-run] IOPMSleepSystem [v3 \(receipt.kind.rawValue)]")
            result = fake["sleepFailure"] as? Bool == true ? -1 : kIOReturnSuccess
        } else {
            let pm = IOPMFindPowerManagement(kIOMainPortDefault)
            // The port lookup and durable write are not permission snapshots.
            result = pm != 0 && canDispatch() ? IOPMSleepSystem(pm) : -1
            if pm != 0 { IOServiceClose(pm) }
        }
        lidEndAuthority = nil
        receipt.outcome = result == kIOReturnSuccess ? "commandAccepted" : "commandRejected"
        state.lidEndReceipt = receipt; _ = saveState()
        sleepDeferralReason = result == kIOReturnSuccess ? nil : "endActionRejected"
        lastSleepRequestAt = Date(); usage.stats.recordSleepRequestAttempt(now: Date())
        note(result == kIOReturnSuccess ? (receipt.kind == .protection ? .protectionSleep : receipt.kind == .user ? .sleepNow : .lidSleep) : .sleepRefused)
        log("single Sleep result: \(receipt.outcome!); actual OS Sleep not yet confirmed; GUI assertion release unconfirmed")
    }

    private func finalLidEndSnapshot(dispatch: Bool = false) -> Snapshot {
        var snapshot = currentSnapshot()
        guard dryRun, let injected = (dispatch ? fake["dispatchSnapshot"] ?? fake["finalSnapshot"] : fake["finalSnapshot"]) as? [String: Any] else { return snapshot }
        if let value = (injected["power"] as? String).flatMap(PowerSource.init(rawValue:)) { snapshot.power = value }
        if let value = injected["lid"] as? String { snapshot.observedLidClosed = value == "closed" ? true : value == "open" ? false : nil }
        if injected["lid"] is NSNull { snapshot.observedLidClosed = nil }
        if let value = injected["sleepDisabled"] as? Bool { snapshot.observedSleepDisabled = value }
        if injected["sleepDisabled"] is NSNull { snapshot.observedSleepDisabled = nil }
        if let value = injected["fullWake"] as? Bool { snapshot.observedFullWake = value }
        if injected["fullWake"] is NSNull { snapshot.observedFullWake = nil }
        return snapshot
    }

    private func finalLidEndReadings() -> SafetyReadings {
        var readings = currentReadings()
        guard dryRun else { return readings }
        let values = fake
        if values.keys.contains("finalThermal") { readings.thermal = values["finalThermal"] as? Int ?? -1 }
        if values.keys.contains("finalLowPowerWarning") { readings.lowPowerWarning = values["finalLowPowerWarning"] as? Bool }
        if values.keys.contains("finalBattery") { readings.batteryPercent = values["finalBattery"] as? Int }
        return readings
    }

    func armLidLeaseDeadline() {
        lidLeaseTimer?.cancel(); lidLeaseTimer = nil
        guard usesV3LidExecution else { return }
        var deadlines: [Double] = []
        let snapshot = currentSnapshot()
        if let lease = workLeaseGate.current, var deadline = lease.expiry {
            if lidLeaseReasons(snapshot: snapshot) == [.manual], let manual = lease.manualDeadline { deadline = min(deadline, manual) }
            if snapshot.power == .battery, let permit = currentBatteryPermitReceipt { deadline = min(deadline, permit.deadline) }
            deadlines.append(deadline)
        }
        if let prepared = batteryEndPreparation { deadlines.append(prepared.deadline) }
        if let end = lidEndAuthority {
            deadlines.append(end.action.actionDeadline ?? end.action.cleanupDeadline)
        }
        if ownsOverride, let last = lastHealthyLidObservationAt { deadlines.append(last + IdleSessionPolicy.healthTTL) }
        guard let deadline = deadlines.filter({ $0 > manualClock }).min() else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + deadline - manualClock)
        timer.setEventHandler { [weak self] in self?.schedule(.timer) }
        timer.resume(); lidLeaseTimer = timer
    }

    @discardableResult
    private func restoreLidOverride() -> Bool {
        let snapshot = currentSnapshot()
        let now = manualClock
        let key = "\(ownsOverride)|\(snapshot.power)|\(String(describing: snapshot.observedLidClosed))|\(String(describing: snapshot.observedSleepDisabled))|\(String(describing: snapshot.observedFullWake))"
        if let failed = lidRestoreFailure, now < failed.retryAt, ownsOverride {
            lastApplyError = failed.error
            return false
        }
        if applyOverride(false) {
            lidRestoreFailure = nil
            lidRestoreAttemptCount = 0
            lidRestoreRetryTimer?.cancel(); lidRestoreRetryTimer = nil
            return true
        }
        // An owned restore debt must survive a transient setter failure without
        // requiring a user action or changed lid/power. The error-only timer
        // retries through the same recovery lock and writer journal; faster
        // notifications are suppressed. Pending end authority is revalidated;
        // a consumed Sleep is never replayed.
        // Dry-run fault injection uses this same observation key and retry bound.
        lidRestoreAttemptCount += 1
        let next = state.lidEndReceipt.map {
            SleepRequestPolicy.nextRestoreRetry(observedAt: $0.observedAt, failedAttempts: lidRestoreAttemptCount, now: now)
        } ?? (now + 30)
        lidRestoreFailure = (key, lastApplyError ?? "restoreUnverified", next)
        lidRestoreRetryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, next - manualClock))
        timer.setEventHandler { [weak self] in
            self?.lidRestoreRetryTimer?.cancel(); self?.lidRestoreRetryTimer = nil
            self?.schedule(.timer)
        }
        timer.resume(); lidRestoreRetryTimer = timer
        return false
    }
}
