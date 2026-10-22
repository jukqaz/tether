import Foundation
import TetherCore

extension Helper {
    func startService() {
        let path = URL(fileURLWithPath: statusPath).deletingLastPathComponent().appendingPathComponent("service.sock").path
        let service = LocalService(path: path)
        do {
            try service.start { [unowned self] request, uid in self.handle(request, uid: uid) }
            self.service = service
            log("service ready (protocol 2)")
        } catch { log("service unavailable: \(error.localizedDescription)"); lastApplyError = "serviceUnavailable" }
    }

    func protectionStatus() -> ProtectionStatus {
        ProtectionStatus(reason: protection.blockReason, error: lastApplyError, dryRun: dryRun)
    }

    func commitControl(_ next: Control) -> Bool {
        guard ControlFile.save(next, previous: control, path: controlPath) else { return false }
        let previousReservation = control.pendingHoldMinutes
        if loadControl(initial: false) { pendingTriggers.insert(.sleepNow) }
        if previousReservation != control.pendingHoldMinutes {
            if control.pendingHoldMinutes != nil { log("activity: battery session reserved") }
            else if control.batteryHoldUntil == nil { log("activity: battery reservation cancelled") }
        }
        return true
    }

    @discardableResult
    func saveProtection() -> Bool {
        guard protection != savedProtection else { return true }
        guard JSONFile.write(protection, to: protectionPath, permissions: 0o600, durable: true) else {
            lastApplyError = "writeFailed"
            return false
        }
        savedProtection = protection
        return true
    }

    func handle(_ request: ServiceRequest, uid: UInt32) -> ServiceReply {
        func reply(_ error: String? = nil) -> ServiceReply {
            var response = ServiceReply(id: request.id, ok: error == nil, error: error, epoch: epoch, revision: revision,
                                        control: control, protection: protectionStatus())
            var status = latestStatus
            status?.protection = nil
            response.status = status
            response.workSessionBridge = WorkSessionBridge(coordinated: state.userSessionCoordinated == true,
                automaticBudget: protection, manualBudget: state.manualBatteryBudget,
                stopRequested: state.coordinatedStopPending == true)
            response.workSessionBridge?.powerTransition = workLeaseGate.transitionReceipt
            response.workSessionBridge?.sleepConsumption = workSleepConsumption
            response.workSessionBridge?.batteryPermitReceipt = currentBatteryPermitReceipt
            response.workSessionBridge?.batteryPermitReceipts = currentSessionBatteryPermitReceipts
            response.workSessionBridge?.lidProtection = state.lidProtection
            response.workSessionBridge?.lidEndReceipt = state.lidEndReceipt
            response.workSessionBridge?.extensionPreparationReceipt = workExtensionPreparationReceipt.flatMap {
                $0.isValid(now: manualClock) ? $0 : nil
            }
            if state.appUID == uid, state.appPID == request.authenticatedPID {
                response.workSessionPreparation = workSessionPreparation
            }
            return response
        }
        guard request.version == 2 else { return reply("unsupportedVersion") }
        let previousAuthority = guiAuthority.status
        if refreshGUIAuthority() || previousAuthority != guiAuthority.status { evaluate() }
        // Check before idempotent cached success: an old GUI login cannot replay a
        // control request after losing the active console.
        if let error = guiRequestError(request, uid: uid) { return reply(error) }
        if [.prepareWorkSession, .attachWorkSession, .syncWorkSession].contains(request.action),
           systemSleepTransition || currentSnapshot().observedFullWake != true {
            // The OS sleep message can precede the ordinary Full Wake observation.
            // No cached ACK or new preparation may authorize work across that gap.
            return reply("sessionUnavailable")
        }
        if [.attachWorkSession, .syncWorkSession].contains(request.action),
           request.workSession?.reasons.isEmpty == false, !systemPowerObservationAvailable {
            // A cached holding ACK is not current authority when the OS Sleep
            // observer is unavailable. Preparation/empty work still lets the GUI
            // read retained protection and positively release its own root state.
            evaluate()
            return reply("powerObservationUnavailable")
        }
        if let cached = replyCache.first(where: { $0.0 == uid && $0.1.id == request.id }) {
            guard cached.1 == request else { return reply("requestIDConflict") }
            // Idempotence preserves the original processing result, not a stale
            // snapshot claiming that expired or consumed work is still active.
            evaluate()
            return reply(cached.2.error)
        }
        if request.action == .snapshot { return reply() }
        if state.userSessionCoordinated == true,
           [.configure, .startHold, .startManualSession, .endManualSession, .attachApp].contains(request.action) {
            return reply("coordinatorRequired")
        }
        let before = protection
        var commandError: String?
        let now = Date().timeIntervalSince1970
        switch request.action {
        case .snapshot: return reply()
        case .markDiagnostic:
            // No arbitrary note text or payload enters a root-owned log.
            log("diagnostic marker \(request.id.uuidString)")
        case .attachApp, .prepareWorkSession, .attachWorkSession:
            if request.action != .attachApp {
                guard request.epoch == epoch, request.revision == revision else { return reply("staleRevision") }
                guard let lease = request.workSession, lease.isValid(now: manualClock),
                      lease.reasons.isEmpty || lease.power == currentSnapshot().power else { return reply("invalidWorkLease") }
                if request.action == .prepareWorkSession {
                    guard lease.reasons.isEmpty else { return reply("invalidWorkLease") }
                    // One live grant belongs to one controller. A foreign
                    // preparation cannot replace the identity that Sleep must
                    // consume while that grant is still current.
                    if let live = workLeaseGate.current, live.sessionID != lease.sessionID {
                        return reply("invalidWorkLease")
                    }
                } else {
                    guard let preparation = workSessionPreparation,
                          preparation.isValid(sessionID: lease.sessionID, epoch: epoch, revision: revision, now: manualClock),
                          state.appUID == uid, state.appPID == request.authenticatedPID,
                          let pid = request.authenticatedPID,
                          ProcessIdentity.capture(pid: pid)?.started == state.appStarted else { return reply("invalidWorkLease") }
                }
            }
            guard let pid = request.authenticatedPID, let identity = ProcessIdentity.capture(pid: pid),
                  identity.uid == uid else { return reply("sessionUnavailable") }
            if appProcessAlive, state.appPID != pid { return reply("notOwner") }
            let previous = state
            state.appSessionRequired = true; state.appPID = pid; state.appStarted = identity.started; state.appUID = uid
            if enforcesGUIAuthority, let login = request.authenticatedGUILogin {
                state.guiOwner = GUISessionOwner(bootID: currentBootID, process: identity, login: login)
                state.controllerUID = state.controllerUID ?? uid
            }
            guard saveState() else { state = previous; return reply("writeFailed") }
            if let owner = state.guiOwner { guiAuthority.bind(owner.login); _ = refreshGUIAuthority() }
            log("app session connected")
            watchAppExit()
            if request.action == .prepareWorkSession, let lease = request.workSession {
                workSessionPreparation = WorkSessionPreparation(sessionID: lease.sessionID, epoch: epoch,
                    revision: revision, expiresAt: manualClock + IdleSessionPolicy.healthTTL)
                log("work session prepared; settings revision=\(revision); no new grant")
            }
            if request.action == .attachWorkSession, let lease = request.workSession,
               let error = acceptWorkSession(lease, attaching: true) {
                workLeaseGate.end(); evaluate(); return reply(error)
            }
            if request.action == .attachWorkSession { workSessionPreparation = nil }
        case .syncWorkSession:
            guard state.userSessionCoordinated == true, state.appUID == uid,
                  state.appPID == request.authenticatedPID, let lease = request.workSession else { return reply("notOwner") }
            if let error = acceptWorkSession(lease, attaching: false) { commandError = error }
        case .detachApp:
            guard state.appUID == uid, state.appPID == request.authenticatedPID else { return reply("notOwner") }
            if !disconnectApp(reason: "app requested detach") { commandError = "writeFailed" }
            workSessionPreparation = nil
        case .configure:
            guard request.epoch == epoch, request.revision == revision else { return reply("staleRevision") }
            guard var next = request.control, next.isSupported, !next.hasRetiredSettings else { return reply("invalidRequest") }
            if next.debugLogUntil != control.debugLogUntil, let until = next.debugLogUntil {
                next.debugLogUntil = min(until, now + DiagnosticRecording.maximumDuration)
            }
            // Configuration changes never clear a safety stop or revive a consumed timer.
            if !next.enabled { next.batteryHoldUntil = nil; next.pendingHoldMinutes = nil; next.holdSource = nil }
            if (next.batteryHoldUntil != control.batteryHoldUntil && next.batteryHoldUntil != nil)
                || (next.pendingHoldMinutes != control.pendingHoldMinutes && next.pendingHoldMinutes != nil) {
                guard effectiveEnabled, next.enabled, protection.blockReason == nil else { return reply("safetyBlocked") }
                let r = currentReadings()
                guard r.isValid, r.thermal < 2,
                      SafetyPolicy.canStartHold(batteryPercent: r.batteryPercent, user: next.limits) else { return reply("safetyBlocked") }
            }
            guard commitControl(next) else { return reply("writeFailed") }
        case .startHold:
            // Retired root-side hold/reservation fields are migration evidence.
            // Current hold commands use the common battery manual controller;
            // never pretend a schema write failure is an executable old timer.
            return reply("unsupportedVersion")
        case .startManualSession:
            guard supported, appSessionAlive, !sessionSuspended, !systemSleepTransition else { return reply("sessionUnavailable") }
            guard systemPowerObservationAvailable else { return reply("powerObservationUnavailable") }
            guard protection.blockReason == nil else { return reply("safetyBlocked") }
            guard request.minutes.map({ (1...Int(ManualSessionPolicy.maximumTimedDuration / 60)).contains($0) }) ?? true,
                  ManualSessionPolicy.validContinuationMinutes(request.manualBatteryContinuationMinutes) else {
                return reply("invalidRequest")
            }
            let snapshot = currentSnapshot(), readings = currentReadings()
            guard snapshot.fullWake, snapshot.power != .unknown, readings.isValid, readings.thermal < 2,
                  snapshot.power != .battery || SafetyPolicy.canStartHold(batteryPercent: readings.batteryPercent, user: limits) else {
                return reply("safetyBlocked")
            }
            if request.minutes == nil, snapshot.power != .ac { return reply("acRequired") }
            if manualSession.active { return reply("holdAlreadyRunning") }
            if snapshot.power == .battery, manualSession.batteryRemaining(now: manualClock, user: limits) <= 0 {
                return reply("manualBatteryBudget")
            }
            let previous = manualSession
            guard manualSession.setBatteryContinuationMinutes(request.manualBatteryContinuationMinutes, now: manualClock, user: limits),
                  manualSession.start(duration: request.minutes.map { Double($0) * 60 },
                power: snapshot.power, now: manualClock, user: limits) else { manualSession = previous; return reply("safetyBlocked") }
            guard persistManualBudget() else { manualSession = previous; return reply("writeFailed") }
            // A new explicit session supersedes earlier sleep retries, not the saved trigger.
            sleepNowUntil = .distantPast; sleepRetryActive = false
            pendingTriggers.remove(.sleepNow)
            log("manual session started: \(request.minutes.map { String($0) + "m" } ?? "unlimited-ac"); automatic trigger preserved")
        case .endManualSession:
            manualSession.end()
            log("manual session ended by user; automatic trigger preserved")
        case .stop, .sleep:
            if request.action == .stop { cancelPendingLidEnd("cancelled") }
            if request.action == .sleep, currentSnapshot().observedSleepDisabled == nil {
                return reply("powerObservationUnavailable")
            }
            if request.action == .sleep, currentSnapshot().sleepDisabled, !ownsOverride {
                return reply("powerConflict")
            }
            var next = control
            next.enabled = false; next.batteryHoldUntil = nil; next.pendingHoldMinutes = nil; next.holdSource = nil
            if request.action == .sleep { next.sleepNowRequest = now }
            guard commitControl(next) else { return reply("writeFailed") }
            if state.userSessionCoordinated == true || workSessionPreparation != nil {
                state.coordinatedStopPending = true
                if !saveState() { commandError = "writeFailed" }
            }
            if usesV3LidExecution, request.action == .sleep { captureLidEnd(.user, action: .sleepIfClosed) }
            manualSession.end(request.action == .sleep ? .sessionEnded : .cancelled)
        case .resume:
            cancelPendingLidEnd("cancelled")
            // Explicit recovery may retry a previously unchanged failed setter;
            // routine notifications never create a write retry loop.
            lidRestoreFailure = nil; legacyRestoreFailures.removeAll()
            guard !sessionSuspended else { return reply("sessionUnavailable") }
            let observed = currentSnapshot()
            guard observed.lidControlObservationAvailable else { return reply("powerObservationUnavailable") }
            guard !observed.sleepDisabled || ownsOverride else { return reply("powerConflict") }
            if ["budget", "time"].contains(protection.blockReason ?? ""), !powerGate.confirmedAC {
                return reply("powerUnconfirmed")
            }
            do {
                _ = try SettingsMigration.migrate(controlPath: controlPath, usage: usage)
                _ = loadControl(initial: false)
            } catch { return reply("configurationUnreadable") }
            guard protection.clearBlock(snapshot: currentSnapshot(), readings: currentReadings(), user: limits) else {
                return reply("safetyBlocked")
            }
            guard saveProtection() else { protection = before; return reply("writeFailed") }
            var next = control
            next.enabled = true; next.batteryHoldUntil = nil; next.pendingHoldMinutes = nil; next.holdSource = nil
            automaticHoldGate.reset(eligible: false)
            displayGate.reset()
            guard commitControl(next) else {
                protection = before; _ = saveProtection()
                return reply("writeFailed")
            }
            if state.userSessionCoordinated != true, state.coordinatedStopPending == true {
                state.coordinatedStopPending = false
                guard saveState() else { return reply("writeFailed") }
            }
            // An explicit resume supersedes any earlier sleep command, including retries.
            sleepNowUntil = .distantPast
            sleepRetryActive = false
            pendingTriggers.remove(.sleepNow)
        }
        pendingTriggers.insert(.settings)
        if request.action == .sleep { pendingTriggers.insert(.sleepNow) }
        evaluate()
        let result = reply(commandError ?? lastApplyError)
        replyCache.append((uid, request, result))
        if replyCache.count > 128 { replyCache.removeFirst(replyCache.count - 128) }
        return result
    }
}
