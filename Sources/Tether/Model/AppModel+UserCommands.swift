import Foundation
import TetherCore

extension AppModel {
    /// Production uses the app's packaged companion. Previews need an explicit,
    /// private test endpoint and observation provider; rendering never starts one.
    @discardableResult
    func startUserCommandService(path: String = UserSessionEndpoint.path, expectedCompanion: String? = nil,
                                 ownerProbe: (() -> GUISessionObservation)? = nil) -> Bool {
        guard hasCoordinatorAuthority else { return false }
        guard userCommandService == nil else { return true }
        if userCommandsArePreview {
            guard path != UserSessionEndpoint.production, expectedCompanion != nil, ownerProbe != nil else { return false }
        }
        do {
            let registration = try Self.reserveUserCommandService(path: path, expectedCompanion: expectedCompanion) { [weak self] request, peer in
                guard let self else {
                    return UserSessionReply(id: request.id, epoch: UUID(), revision: 0, ok: false, error: "coordinatorUnavailable")
                }
                return await self.handleUserCommand(request, peer: peer)
            }
            userCommandCompanion = registration.companion; userCommandOwnerProbe = ownerProbe; userCommandService = registration.server
            return true
        } catch { errorText = error.localizedDescription; return false }
    }

    /// Reserve before migration/controller construction. A weak destination is bound
    /// only after the model's stored settings are initialized on the main actor.
    static func reserveUserCommandService(path: String, expectedCompanion: String? = nil,
        handle: @escaping @MainActor (UserSessionRequest, UserSessionPeer) async -> UserSessionReply)
        throws -> (server: UserSessionService, companion: String) {
        guard let executable = ProcessIdentity.capture(pid: getpid())?.executable,
              let companion = expectedCompanion ?? UserSessionEndpoint.companionExecutable(forCoordinator: executable) else {
            throw UserSessionFailure("coordinatorUnavailable")
        }
        let server = UserSessionService(path: path)
        try server.start(handle)
        return (server, companion)
    }

    func userCommandReply(_ request: UserSessionRequest, error: String? = nil) -> UserSessionReply {
        var reply = UserSessionReply(id: request.id, epoch: userCommandLedger.epoch, revision: userCommandLedger.revision,
            ok: error == nil && userSession != nil, error: error ?? (userSession == nil ? "coordinatorUnavailable" : nil), status: userSession?.status)
        if !hasInternalBattery { reply.status?.canStartBatteryHold = false }
        reply.helperBuild = status?.build
        reply.workScope = userSession?.v4Scope
        reply.recordingUntil = userSession?.activity.recordingUntil
        reply.commonActivity = userSession?.activity.entries
        reply.helperConnected = coordinatingLid || lidReleasePending ? helperResponding : nil
        if lidReleasePending { reply.lidSupport = .pending }
        else if capabilities.helperInstallTarget == .desktop { reply.lidSupport = .notRequired }
        else if !capabilities.lidControlAvailable || !coordinatingLid { reply.lidSupport = .unavailable }
        else if lidCommandPending { reply.lidSupport = .pending }
        else if coordinatedLidError != nil || coordinatedLidBlockReason != nil { reply.lidSupport = .error }
        else { reply.lidSupport = clamshellActive ? .active : .inactive }
        reply.lidClosed = capabilities.lidControlAvailable ? snapshot.lidClosed : nil
        reply.lidError = coordinatedLidError ?? coordinatedLidBlockReason.map(protectionReason)
        return reply
    }

    func handleUserCommand(_ request: UserSessionRequest, peer: UserSessionPeer) async -> UserSessionReply {
        let now = ContinuousTime.now
        guard request.version == 1, request.build == TetherPaths.build else { return userCommandReply(request, error: "unsupportedVersion") }
        guard request.isValid(now: now) else { return userCommandReply(request, error: "invalidRequest") }
        guard acceptingUserCommands, let current = ProcessIdentity.capture(pid: peer.process.pid),
              peer.uid == getuid(), peer.process.matchesLifetime(current),
              let companion = userCommandCompanion,
              ProcessIdentity.sameExecutable(current.executable, companion) else {
            return userCommandReply(request, error: "unauthorized")
        }
        // Keep decoding the legacy field so old same-build clients receive an
        // explicit rejection. No new timer, replay receipt or PID watcher starts.
        guard request.manualPID == nil else { return userCommandReply(request, error: "processBoundManualRemoved") }
        if request.command == .status && request.workEvent == nil && request.recording == nil { return userCommandReply(request) }
        let owner = explicitSleepOwnerObservation()
        guard UserSessionAccess.permits(client: current, uid: peer.uid, peerLogin: peer.login,
                                        owner: owner, expectedExecutable: companion) else {
            return userCommandReply(request, error: "guiSessionUnavailable")
        }
        switch userCommandLedger.check(request, client: current) {
        case .replay(let original):
            var reply = userCommandReply(request)
            reply.ok = original.ok; reply.error = original.error; reply.replayed = true
            reply.workEventResult = original.workEventResult
            reply.recordingID = original.recordingID
            if let id = original.workEventResult?.record?.id {
                reply.workEventResult?.record = userSession?.v4WorkEvents.records[id]
            }
            return reply
        case .stale: return userCommandReply(request, error: "staleRevision")
        case .busy: return userCommandReply(request, error: "busy")
        case .invalidReplay: return userCommandReply(request, error: "invalidReplay")
        case .ready: break
        }
        if let recording = request.recording {
            guard let controller = userSession else { return userCommandReply(request, error: "coordinatorUnavailable") }
            let accepted = controller.applyActivityRecording(recording, requestID: request.id)
            userCommandLedger.advance()
            var reply = userCommandReply(request, error: accepted ? nil : "coordinatorUnavailable")
            if accepted { reply.recordingID = request.id }
            userCommandLedger.record(request, client: current, reply: reply)
            return reply
        }
        let stopsExisting = request.command == .off || request.command == .endManual
            || request.command == .cancelHold || request.command == .automatic(false)
        let endingEvent = request.workEvent.map { [.finished, .failed, .cancelled].contains($0.kind) } == true
        if v4AcquisitionBlocked && !stopsExisting && !endingEvent && request.command != .sleep {
            return userCommandReply(request, error: "updateBusy")
        }
        guard stopsExisting || endingEvent || (!userCommandBusy && !commandPending && !v4ManualApprovalPending) else { return userCommandReply(request, error: "busy") }
        guard let controller = userSession else { return userCommandReply(request, error: "coordinatorUnavailable") }
        userCommandBusy = true
        defer { userCommandBusy = false }
        var commandError: String?
        if let event = request.workEvent {
            let result = controller.applyWorkEvent(event)
            var reply = userCommandReply(request,
                error: [.accepted, .alreadyProcessed].contains(result.disposition) ? nil : result.reason)
            reply.workEventResult = result
            userCommandLedger.advance(); reply.revision = userCommandLedger.revision
            userCommandLedger.record(request, client: current, reply: reply)
            return reply
        }
        switch request.command {
        case .status: break
        case .on, .off, .toggle:
            let on = request.command == .toggle ? !controller.status.enabled : request.command == .on
            userEnableSequence &+= 1
            do { try await applyUserEnabled(on, sequence: userEnableSequence, deadline: request.deadline) }
            catch let failure as ServiceFailure { commandError = failure.code }
            catch let failure as UserSessionFailure { commandError = failure.code }
            catch { commandError = "failed" }
        case .hold(let minutes):
            if let error = validateBatteryAction() { commandError = error }
            else if controller.status.power != .battery { commandError = "batteryRequired" }
            else if !canAcquireManualFeatures || !controller.start(duration: Double(minutes) * 60) { commandError = "safetyBlocked" }
            else if let id = controller.manualRequestID {
                acceptedUserWorkIntent(); v4ManualApprovalPending = true
                if !(await verifyManualStart(requestID: id, deadline: request.deadline)) { commandError = "requestVerificationFailed" }
            }
        case .extendHold(let minutes):
            if let error = validateBatteryAction() { commandError = error }
            else if !(await performManualExtension(minutes: minutes, deadline: request.deadline)) { commandError = "safetyBlocked" }
        case .cancelHold: controller.cancelBatteryHold()
        case .manual(let minutes):
            if minutes == nil && controller.status.power != .ac { commandError = "acRequired" }
            else if !canAcquireManualFeatures { commandError = "requestVerificationFailed" }
            else if !controller.start(duration: minutes.map { Double($0) * 60 }) { commandError = "safetyBlocked" }
            else {
                acceptedUserWorkIntent()
                if let id = controller.manualRequestID {
                    v4ManualApprovalPending = true
                    if !(await verifyManualStart(requestID: id, deadline: request.deadline)) { commandError = "requestVerificationFailed" }
                }
            }
        case .extendManual(let minutes):
            if !(await performManualExtension(minutes: minutes, deadline: request.deadline)) { commandError = "safetyBlocked" }
        case .endManual: controller.endManual()
        case .automatic(let enabled):
            controller.setAutomatic(enabled)
            if controller.status.automaticEnabled != enabled { commandError = "safetyBlocked" }
            else if enabled && controller.status.automaticActive { acceptedUserWorkIntent() }
        case .condition(let condition):
            if condition != .ac, let error = validateBatteryAction() { commandError = error }
            else {
                controller.setPowerCondition(condition)
                if controller.status.powerCondition != condition { commandError = "safetyBlocked" }
                else if controller.status.automaticActive { acceptedUserWorkIntent() }
            }
        case .sleep:
            if !explicitSleepExecutionAllowed { commandError = "sleepUnavailable" }
            else {
                do {
                    let intent = try beginExplicitSleep(deadline: request.deadline, expectedOwner: owner.login)
                    guard controller.pauseForUserSleep() else {
                        throw UserSessionFailure("releaseUnconfirmed")
                    }
                    commandError = await executeExplicitSleep(intent)
                } catch let failure as UserSessionFailure { commandError = failure.code }
                catch { commandError = "failed" }
            }
        }
        // Give the root relay its bounded acknowledgement window. A remaining lid
        // error or pending result is explicit, never reported as general-work failure.
        let waitUntil = min(request.deadline, ContinuousTime.now + 3)
        while lidCommandPending, ContinuousTime.now < waitUntil, acceptingUserCommands {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if controller.status.error != nil, commandError == nil { commandError = "requestVerificationFailed" }
        userCommandLedger.advance()
        let reply = userCommandReply(request, error: commandError)
        userCommandLedger.record(request, client: current, reply: reply)
        return reply
    }

}
