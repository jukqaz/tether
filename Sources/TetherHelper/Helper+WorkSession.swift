import Foundation
import TetherCore

extension Helper {
    var coordinatedReasons: [WorkSessionReason] {
        if usesV3LidExecution { return lidLeaseReasons(snapshot: currentSnapshot()) }
        guard state.userSessionCoordinated == true, state.coordinatedStopPending != true,
              protection.blockReason == nil, !sessionSuspended, !systemSleepTransition,
              systemPowerObservationAvailable else { return [] }
        let snapshot = currentSnapshot()
        guard workLeaseGate.current?.power == snapshot.power else { return [] }
        return workLeaseGate.reasons(now: manualClock, power: snapshot.power).filter { reason in
            guard snapshot.power == .battery else { return true }
            if reason == .automatic { return false }
            var cap = limits ?? UserLimits()
            cap.maxHoldHours = min(ManualSessionPolicy.batteryMaximum, SafetyPolicy.maxHold(limits)) / 3600
            return (state.manualBatteryBudget ?? ProtectionState()).batteryRemaining(clock: manualClock, user: cap) > 0
        }
    }
    var coordinatedWorkAllowed: Bool { !coordinatedReasons.isEmpty }

    /// Sleep consumes temporary authority, even if a quick wake occurs before its
    /// finite timeout. Keep the app binding, saved trigger, stop latch and budgets;
    /// the app must supply a freshly prepared decision after full wake.
    func consumeCoordinatedWorkForSystemSleep() {
        workExtensionPreparationReceipt = nil; workExtensionRollback = nil; lidManagedSessionID = nil
        cancelPendingLidEnd("systemSleepObserved")
        guard state.userSessionCoordinated == true || workSessionPreparation != nil
            || workLeaseGate.current != nil || state.workSessionLease != nil else { return }
        let live = workLeaseGate.current
        // A restarted helper keeps the old enforcement snapshot for recovery,
        // never an active grant. Fresh preparation is the current controller's
        // evidence and must be consumed before that saved, potentially foreign
        // session; otherwise its first post-wake attach could omit the ACK.
        let consumed = live ?? (workSessionPreparation == nil ? state.workSessionLease : nil)
        // A v3 end revoked the grant before demand Sleep. Its consumed incident
        // still identifies the authority that the subsequently observed OS Sleep
        // ends, so a stalled GUI can acknowledge that real boundary after Wake.
        let ended = usesV3LidExecution ? state.lidEndReceipt.flatMap {
            $0.bootID == currentBootID && $0.phase == .consumed && $0.observedAt <= manualClock ? $0 : nil
        } : nil
        if let sessionID = live?.sessionID ?? workSessionPreparation?.sessionID
            ?? consumed?.sessionID ?? ended?.sessionID ?? workSleepConsumption?.sessionID {
            workSleepConsumption = WorkSessionSleepConsumption(bootID: currentBootID, sessionID: sessionID,
                sequence: consumed?.sequence ?? ended?.sequence ?? 0, observedAt: manualClock,
                continuationToken: consumed?.continuationToken ?? consumed?.powerTransition?.token)
            state.workSleepConsumption = workSleepConsumption
        }
        workLeaseGate.end()
        workSessionPreparation = nil
        state.workSessionLease = nil
        revision &+= 1
        // Work ACKs contain authority that just ended. Preserve unrelated command
        // receipts so a lost acknowledgement cannot replay stop/resume operations.
        replyCache.removeAll {
            [.prepareWorkSession, .attachWorkSession, .syncWorkSession].contains($0.1.action)
        }
        _ = saveState()
        log("system sleep consumed coordinated work; fresh full-wake preparation required")
    }

    func updateCoordinatedWork(_ snapshot: Snapshot, readings: SafetyReadings) {
        // Consume confirmed AC departure even when opposite-power work is empty.
        // Otherwise returning to AC could revive the old legacy grant.
        workLeaseGate.observeTransition(now: manualClock, power: snapshot.power)
        let wanted = coordinatedReasons
        guard !wanted.isEmpty else { return }
        if !readings.isValid { protection.block("sensor") }
        else if readings.thermal >= 2 { protection.block("thermal") }
        else if snapshot.power == .battery,
                !SafetyPolicy.canStartHold(batteryPercent: readings.batteryPercent, user: limits) { protection.block("battery") }
        if snapshot.power == .battery {
            if wanted.contains(.manual) {
                var budget = state.manualBatteryBudget ?? ProtectionState()
                budget.restart(boot: currentBootID)
                budget.prepareBatteryBudget(power: .battery, needed: true, clock: manualClock, boot: currentBootID)
                if budget != state.manualBatteryBudget {
                    state.manualBatteryBudget = budget
                    if !saveState() { protection.block("stateWriteFailed") }
                }
            }
        }
    }

    func acceptWorkSession(_ lease: WorkSessionLease, attaching: Bool) -> String? {
        let firstCoordinatedHandoff = state.userSessionCoordinated != true
        guard !stateJournalUnreadable else { return "stateUnreadable" }
        guard !systemSleepTransition, currentSnapshot().observedFullWake == true else { return "sessionUnavailable" }
        guard lease.reasons.isEmpty || systemPowerObservationAvailable else { return "powerObservationUnavailable" }
        if let consumed = workSleepConsumption, consumed.sessionID == lease.sessionID,
           lease.sleepConsumptionID != consumed.id || lease.sequence <= consumed.sequence { return "invalidWorkLease" }
        // A legacy active grant cannot acknowledge durable disconnect revocation
        // after helper restart. Empty preparation/release remains compatible.
        if !lease.reasons.isEmpty, lease.executionVersion != 3 { return "unsupportedVersion" }
        if let error = validateLidLease(lease) { return error }
        let replacesACBoundary = lease.executionVersion == 3 && lease.power == .battery
            && !lease.reasons.isEmpty && lastLidLeasePower == .ac
        if replacesACBoundary, workLeaseGate.current?.configuration.effectiveDisconnectPolicy == .endAll {
            // The controller can consume unplug and approve a genuinely new
            // battery manual before its empty release reaches this process.
            // A refresh of the same old ID is still pre-unplug intent, including
            // a battery-origin request whose intermediate AC lease was delayed.
            guard lease.reasons == [.manual], let requestID = lease.manualRequestID,
                  workLeaseGate.current?.manualRequestID != requestID else { return "invalidWorkLease" }
        }
        if replacesACBoundary, lease.reasons.contains(.automatic),
           lease.automaticRequestID != workLeaseGate.current?.automaticRequestID {
            guard lease.configuration.effectiveDisconnectPolicy == .continueEligible,
                  lease.configuration.startAutomaticOnBatteryDisconnect == true,
                  lease.configuration.condition.includesBattery, lease.automaticRequestID != nil else { return "invalidWorkLease" }
        }
        var extensionCommitPrevious: WorkSessionLease?
        if let rollbackID = lease.extensionRollbackID {
            guard lease.extensionPreparation == nil, let rollback = workExtensionRollback,
                  rollbackID == rollback.committedID, let previous = workLeaseGate.current,
                  previous.manualExtensionID == rollbackID,
                  previous.manualRequestID == rollback.previous.manualRequestID,
                  lease.manualRequestID == rollback.previous.manualRequestID,
                  lease.manualDeadline == rollback.previous.manualDeadline,
                  lease.manualExtensionID == rollback.previous.manualExtensionID,
                  lease.sessionID == previous.sessionID, lease.reasons.contains(.manual),
                  lease.manualDeadline.map({ manualClock < $0 }) == true else { return "invalidExtensionRollback" }
        } else if let pending = lease.extensionPreparation {
            guard let previous = workLeaseGate.current,
                  pending.matches(current: previous, incoming: lease, now: manualClock) else {
                return "invalidExtensionPreparation"
            }
        } else if let previous = workLeaseGate.current, lease.reasons.contains(.manual),
                  lease.manualRequestID == previous.manualRequestID {
            let deadlineIncreased = lease.manualDeadline.map { proposed in
                previous.manualDeadline.map { proposed > $0 } ?? false
            } ?? false
            if deadlineIncreased || lease.manualExtensionID != previous.manualExtensionID {
                guard workExtensionPreparationReceipt?.permitsCommit(current: previous, incoming: lease, now: manualClock) == true
                else { return "extensionNotPrepared" }
                extensionCommitPrevious = previous
            }
        }
        if lease.executionVersion == 3, !beginLidExecutorIfNeeded() { return lastApplyError ?? "writeFailed" }
        let acknowledgingEnd = state.lidEndReceipt.map {
            lease.endConsumptionID == $0.id && lease.sessionID == $0.sessionID && lease.sequence > $0.sequence
        } == true
        var nextGate = workLeaseGate
        guard nextGate.accept(lease, now: manualClock, attaching: attaching || acknowledgingEnd),
              lease.reasons.isEmpty || lease.power == currentSnapshot().power else { return "invalidWorkLease" }
        if state.coordinatedStopPending == true, !lease.reasons.isEmpty { return "coordinatorRequired" }
        let configuration = lease.configuration
        var next = control
        next.enabled = configuration.enabled && configuration.automaticEnabled
        // The legacy control journal intentionally rejects retired autonomous
        // battery settings. P0 execution scope lives only in the finite lease.
        next.powerCondition = .ac; next.automaticHoldMinutes = configuration.automaticMinutes
        next.limits = configuration.limits
        if firstCoordinatedHandoff {
            next.limits = UserLimits(batteryFloor: max(SafetyPolicy.floor(control.limits), SafetyPolicy.floor(configuration.limits)),
                maxHoldHours: min(SafetyPolicy.maxHold(control.limits), SafetyPolicy.maxHold(configuration.limits)) / 3600)
        }
        next.batteryHoldUntil = nil; next.pendingHoldMinutes = nil; next.holdSource = nil
        guard next == control || commitControl(next) else {
            workLeaseGate.end(); protection.block("stateWriteFailed")
            return "writeFailed"
        }
        // Capture the old permit before an app-first empty battery decision
        // overwrites it. The following evaluation restores/requeries once using
        // the same durable incident as a helper-first power notification.
        guard captureLidDisconnectBeforeReplacing(with: lease) else {
            return lastApplyError ?? "writeFailed"
        }
        let previous = state
        state.userSessionCoordinated = true
        state.workSessionLease = lease
        if lease.executionVersion == 3 { state.lidExecutionVersion = 3 }
        if lease.reasons.isEmpty { state.coordinatedStopPending = false }
        guard saveState() else {
            state = previous; workLeaseGate.end(); protection.block("stateWriteFailed")
            return "writeFailed"
        }
        manualSession.end(.sessionEnded)
        holdWasActive = false; holdingOnBattery = false
        workLeaseGate = nextGate
        if replacesACBoundary {
            // The old grant was replaced by this current-battery approval. Do
            // not let the next evaluation consume that new ID as the old AC
            // grant or synthesize a terminal receipt that would end newer intent.
            lastLidLeasePower = .battery
        }
        if let pending = lease.extensionPreparation {
            workExtensionPreparationReceipt = WorkSessionExtensionPreparationReceipt(sessionID: lease.sessionID,
                sequence: lease.sequence, observedAt: manualClock, preparation: pending)
            workExtensionRollback = nil
        } else { workExtensionPreparationReceipt = nil }
        if let previous = extensionCommitPrevious, let id = lease.manualExtensionID {
            workExtensionRollback = (id, previous)
        } else if lease.extensionRollbackID != nil || !lease.reasons.contains(.manual)
            || workExtensionRollback?.previous.manualRequestID != lease.manualRequestID {
            workExtensionRollback = nil
        }
        if lease.executionVersion == 3 {
            if lease.protectionResumeID == state.lidProtection?.id, state.lidProtection != nil {
                let previousProtection = protection
                let retainedLatch = state.lidProtection
                guard protection.clearBlock(snapshot: currentSnapshot(), readings: currentReadings(), user: limits) else {
                    workLeaseGate.end(); return "safetyBlocked"
                }
                // Keep the native exec latch until the other durable protection
                // record is clean. A failed second write cannot expose a grant
                // that the helper itself rejected.
                guard saveProtection() else {
                    protection = previousProtection; workLeaseGate.end()
                    state.workSessionLease = nil; _ = saveState()
                    return "writeFailed"
                }
                state.lidProtection = nil
                if !saveState() {
                    state.lidProtection = retainedLatch
                    protection = previousProtection; _ = saveProtection()
                    workLeaseGate.end(); protection.block("stateWriteFailed")
                    return "writeFailed"
                }
            }
            armLidLeaseDeadline()
        }
        // Only a current, accepted holding decision supersedes old automatic retries.
        if !lease.configuration.enabled || !lease.reasons.isEmpty {
            batteryEndPreparation = nil
            if let end = state.lidEndReceipt, end.phase != .consumed {
                cancelPendingLidEnd("cancelled")
            }
            sleepRetryActive = false; sleepNowUntil = .distantPast; pendingTriggers.remove(.sleepNow)
        }
        if let prepared = batteryEndPreparation,
           lease.sessionID != prepared.lease.sessionID || !lease.configuration.enabled
            || (lease.reasons.isEmpty && manualClock < prepared.deadline) {
            batteryEndPreparation = nil
        }
        log("work lease accepted: sequence=\(lease.sequence) reasons=\(lease.reasons.map(\.rawValue).sorted().joined(separator: ","))")
        return nil
    }
}
