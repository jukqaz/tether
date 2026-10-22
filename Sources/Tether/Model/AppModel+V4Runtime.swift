import Foundation
import TetherCore

@MainActor
extension AppModel {
    var v4DecisionHistoryIssue: String? { userSession?.activityStorageError }
    var v4CurrentContext: V4ExecutionContext? {
        userSession?.v4Context(now: ContinuousTime.now, lidClosed: capabilities.lidControlAvailable ? snapshot.lidClosed : nil,
            isMacBook: capabilities.hardware == .portable)
    }
    func updateV4Runtime(_ state: UserSessionStatus) {
        guard let controller = userSession, let context = v4CurrentContext else { return }
        let now = ContinuousTime.now
        let trend = v4ChargerTrend.observe(at: now, power: context.power, batteryPercent: state.batteryPercent)
        if v4ACDrainWarning != trend.warningActive { v4ACDrainWarning = trend.warningActive }
        if trend.shouldNotify && notifyBatteryProtection && !userCommandsArePreview {
            NotificationSettingsMonitor.deliver(title: L("Battery is decreasing on AC", "전원 연결 중 배터리 잔량 감소"),
                body: L("Battery charge has decreased during observed AC use. Check the power supply and workload. Tether has not ended work for this advisory.", "AC 관측 구간에서 잔량이 줄었습니다. 전원 공급과 작업 부하를 확인하세요. 이 안내만으로 작업 유지를 종료하지 않습니다."))
        }
        for record in controller.v4WorkEvents.records.values where record.isTerminal && !v4ObservedTerminalJobs.contains(record.id) {
            v4ObservedTerminalJobs.insert(record.id)
            if record.state == .ended && v4Settings.notifyTaskEnd && !userCommandsArePreview {
                NotificationSettingsMonitor.deliver(title: L("Linked work ended", "연동 작업이 끝났습니다"),
                    body: L("The selected work event ended. Other valid requests may continue; this does not prove task success or OS Sleep.", "선택한 작업 이벤트가 종료됐습니다. 다른 유효 요청은 계속될 수 있으며 작업 성공이나 실제 잠자기의 증거는 아닙니다."))
            }
        }
        var manual = controller.v4ManualSnapshot
        if v4ManualApprovalPending { manual?.confirmed = false }
        let notice = v4ExpiryEngine.update(manual: manual, context: context, now: now,
            enabled: v4Settings.expiryNoticeEnabled, notificationsAuthorized: notificationSettings.value.access == .allowed)
        if !userCommandsArePreview {
            v4NotificationDelivery.remove(notice.invalidate)
            if let token = notice.submit { v4NotificationDelivery.submit(token, automaticContinues: state.automaticActive) }
        }
        if let previous = v4PreviousManualID, previous != state.manualRequestID {
            let natural = state.manualEndReason == .time || state.manualEndReason == .batteryBudget || state.manualEndReason == .taskEnded
            let kind = v4UpdateWork[previous]?.kind ?? .timedManual
            v4UpdateWork[previous] = V4UpdateWork(id: previous, kind: kind,
                state: natural ? .completed : .safetyConsumed, hasLinkedProcess: kind == .pidManual)
            if natural && (state.manualEndReason == .taskEnded ? v4Settings.notifyTaskEnd : v4Settings.notifyManualExpiry) && !userCommandsArePreview {
                NotificationSettingsMonitor.deliver(title: L("Manual keep-awake ended", "수동 유지가 끝났습니다"),
                    body: state.automaticActive ? L("AC automatic keep-awake continues.", "AC 자동 유지는 계속됩니다.")
                        : L("Tether released this request. This does not confirm OS Sleep or task success.", "Tether의 해당 요청을 해제했습니다. 실제 잠자기나 작업 성공을 뜻하지 않습니다."))
            }
        }
        v4PreviousManualID = state.manualRequestID
        if let id = state.manualRequestID {
            v4UpdateWork[id] = V4UpdateWork(id: id, kind: controller.hasManualPID ? .pidManual
                : state.manualContinuousDeadline == nil ? .unlimitedManual : .timedManual,
                state: .active, hasLinkedProcess: controller.hasManualPID)
        }
        if v4UpdateWork.count > 1024, v4UpdateWaitEngine.reservationID == nil {
            v4UpdateWork = v4UpdateWork.filter { $0.key == state.manualRequestID }
        }
        if v4UpdateWaitEngine.reservationID != nil { evaluateV4UpdateWait() }
    }
    func handleV4Notice(_ token: V4ExpiryNoticeToken, action: V4ExpiryNoticeAction) {
        guard acceptingUserCommands, v4Settings.expiryNoticeEnabled, let controller = userSession else { return }
        controller.refresh()
        guard let context = v4CurrentContext else { return }
        let result = V4ExpiryNoticeEngine.validate(action: action, token: token,
            manual: controller.v4ManualSnapshot, context: context, now: ContinuousTime.now)
        switch result.intent {
        case .requestExtension(let minutes): extendManualSession(by: minutes)
        case .showDeadline: settingsPage = .general; v4SettingsPresentationID = UUID()
        case .showCurrentState:
            v4SettingsPresentationID = UUID()
            errorText = L("This notification belongs to an ended or changed request. Check the current session.", "종료되거나 바뀐 요청의 알림입니다. 현재 세션을 확인하세요.")
        }
    }
    func rehearseV4(power: PowerSource, lidClosed: Bool, protected: Bool,
                   event: String = "unplug", restoreConfirmed: Bool = true) -> [String] {
        let now = ContinuousTime.now
        let scope = userSession?.v4Scope ?? V4Scope(bootID: "rehearsal", ownerID: "rehearsal", powerGeneration: 0)
        var settings = v4Settings
        let context = V4ExecutionContext(scope: scope, power: V4Power(rawValue: power.rawValue) ?? .unknown,
            validUntil: now + 15, automaticEnabled: automaticEnabled, protectionActive: protected,
            isMacBook: capabilities.hardware == .portable, lidClosed: lidClosed,
            allowDisplay: v3Settings.keepDisplayAwake, allowClosedLid: v3Settings.allowClosedLid)
        let virtualEvent: V4RehearsalEvent
        switch event {
        case "unplug": virtualEvent = .disconnect
        case "conditionEnded": settings.automaticMode = .advanced; settings.activePresetID = nil; virtualEvent = .none
        case "taskCompleted": virtualEvent = .taskEnd
        default: virtualEvent = .none
        }
        var manual = userSession?.v4ManualSnapshot
        if event == "newRequest", manual == nil {
            let id = UUID()
            manual = V4ManualSnapshot(requestID: id, revisionID: id, ownerID: scope.ownerID,
                startedAt: now, deadline: now + 1800, batteryStartedAt: power == .battery ? now : nil,
                options: settings.nextManualOptions)
        }
        let plan = V4RehearsalEngine.evaluate(settings: settings, context: context,
            observations: userSession?.v4RehearsalObservations ?? [], capabilities: userSession?.v4Capabilities ?? [],
            manual: manual, event: virtualEvent, now: now, wallDate: Date(), calendar: .current,
            closedLidAvailable: helperSetupConfirmed, ownRestorationPossible: restoreConfirmed,
            idleSeconds: userSession?.displayIdleObservation?.seconds, idleValidUntil: userSession?.displayIdleObservation?.validUntil, disconnectAction: v3Settings.disconnectAction)
        var lines = [L("Expected behavior · no execution", "예상 동작 · 실행하지 않음"),
            plan.general ? L("General work would be held.", "일반 작업을 유지할 예상입니다.") : L("No general keep-awake request remains.", "일반 유지 요청이 남지 않습니다."),
            plan.display ? L("Display keeping would be requested.", "화면 유지를 요청할 예상입니다.") : L("Display keeping would be released.", "화면 유지 요청은 해제할 예상입니다."),
            plan.closedLid ? L("Closed-lid work is permitted by the simulated choices.", "가상 선택에 따라 덮개 유지를 허용할 예상입니다.") : L("No managed closed-lid request.", "관리하는 덮개 유지 요청이 없습니다.")]
        if event == "taskCompleted" {
            lines.append(L("Assumption: the current manual request is linked to the task that ends. Independent manual work is unchanged by a separate task event.", "가정: 현재 수동 요청에 연결된 작업의 종료입니다. 별도 작업 이벤트가 끝나도 독립 수동 요청은 유지됩니다."))
        }
        switch plan.sleep {
        case .afterOwnRestoration: lines.append(L("After own restoration, request Sleep once. Actual Sleep is not simulated.", "자체 원복 뒤 잠자기를 한 번 요청할 예상입니다. 실제 잠자기는 시험하지 않습니다."))
        case .blockedByRestoration: lines.append(L("Own restoration is unconfirmed; do not send Sleep.", "자체 원복 미확인으로 잠자기 요청을 보내지 않습니다."))
        case .blockedByOwner, .blockedByUnknownLid: lines.append(L("Required facts are missing; do not send Sleep.", "필수 상태를 확인하지 못해 잠자기 요청을 보내지 않습니다."))
        case .notRequested: lines.append(L("Release own requests and let macOS decide Sleep.", "자체 요청을 해제하고 잠자기는 macOS에 맡깁니다."))
        }
        return lines
    }

    var v4UpdateSnapshot: V4UpdateSnapshot? {
        guard let context = v4CurrentContext, let version = updateStatus.candidateBuild,
              let package = updateStatus.packageIdentity else { return nil }
        let tracked = v4UpdateWaitEngine.waitingFor
        var work = v4UpdateWork.values.filter { $0.state == .active || $0.state == .waiting || $0.state == .idle || tracked.contains($0.id) }
        work += (userSession?.v4WorkEvents.records.values.filter { !$0.isTerminal || tracked.contains($0.id) }.map { record in
            let state: V4UpdateWorkState = record.state == .ended ? .completed
                : record.state == .expired ? .observationExpired : record.state == .revoked ? .safetyConsumed
                : record.state == .waiting ? .waiting : record.state == .idle ? .idle : .active
            return V4UpdateWork(id: record.id, kind: .taskEvent, state: state)
        } ?? [])
        if v4ManualApprovalPending, let id = userSession?.manualRequestID {
            work.removeAll { $0.id == id }
            work.append(V4UpdateWork(id: id, kind: userSession?.manualExtensionPending == true ? .pendingExtension : .pendingStart, state: .active))
        }
        return V4UpdateSnapshot(context: context,
            identity: V4UpdateIdentity(version: version, packageIdentity: package, channel: updateChannel.rawValue,
                settingsGeneration: v4ConfigurationGeneration), work: work,
            packageValidated: updateStatus.packageVerified, compatible: supportedMac,
            restorationPending: lidReleasePending || coordinatedLidError != nil,
            authenticationRequired: updateStatus.authenticationRequired)
    }
    var v4UpdateNeedsAuthentication: Bool { v4UpdateWaitResult?.state == .authenticationRequired }
    var v4UpdateWaitTitle: String? {
        guard let result = v4UpdateWaitResult else { return nil }
        switch result.state {
        case .none, .cancelled: return nil
        case .waiting: return L("Update reserved · waiting for tracked work and preparation", "업데이트 예약 · 추적 작업 종료와 준비 대기")
        case .ready: return L("Ready to replace the app", "앱 교체 준비됨")
        case .authenticationRequired: return L("Administrator approval required", "관리자 인증 후 설치 필요")
        case .confirmationRequired: return L("Reservation approval ended · review before choosing again", "예약 승인 종료 · 확인 후 다시 선택")
        case .committing: return L("Preparing app replacement", "앱 교체 준비 중")
        case .expired: return L("Update reservation expired", "업데이트 예약 기간 만료")
        }
    }
    var v4UpdateWaitUnavailableReason: String? {
        if manualSessionActive && manualSessionUntil == nil && userSession?.hasManualPID != true {
            return L("Unlimited manual work has no linked end. Choose Install now when ready.", "무제한 수동에는 확인할 종료 사건이 없습니다. 준비되면 ‘지금 설치’를 선택하세요.")
        }
        if updateStatus.packageIdentity == nil && availableUpdate != nil { return L("Waiting for the selected update identity.", "선택한 업데이트의 식별 정보를 확인 중입니다.") }
        return nil
    }
    var canScheduleUpdateAfterWork: Bool {
        guard acceptingUserCommands, !userCommandsArePreview, !developmentService,
              v4UpdateWaitUnavailableReason == nil, let snapshot = v4UpdateSnapshot else { return false }
        return snapshot.context.permitsWork(at: ContinuousTime.now) && snapshot.context.power == .ac
    }
    func scheduleUpdateAfterWork() {
        userSession?.refresh()
        guard canScheduleUpdateAfterWork, let snapshot = v4UpdateSnapshot else { return }
        v4UpdateWaitResult = v4UpdateWaitEngine.reserve(id: UUID(), snapshot: snapshot, now: ContinuousTime.now)
        updater.deferUntilWorkEnds = true
        updater.downloadReservedUpdate()
    }
    func cancelScheduledUpdate() {
        v4UpdateWaitEngine.cancel(); v4UpdateWaitResult = nil
        updater.cancelDeferredInstallation()
    }
    func evaluateV4UpdateWait() {
        if updateStatus.error != nil || (updateStatus.packageIdentity == nil && !updateStatus.checking) {
            v4UpdateWaitEngine.cancel(); v4UpdateWaitResult = nil
            updater.cancelDeferredInstallation(); return
        }
        guard let snapshot = v4UpdateSnapshot else { return }
        v4UpdateWaitResult = v4UpdateWaitEngine.evaluate(snapshot: snapshot, now: ContinuousTime.now)
        if v4UpdateWaitResult?.state == .ready {
            let result = v4UpdateWaitEngine.beginReplacement(snapshot: snapshot, now: ContinuousTime.now)
            v4UpdateWaitResult = result
            if result.state == .committing { _ = updater.installVerifiedDeferredUpdate() }
        } else if [.confirmationRequired, .expired].contains(v4UpdateWaitResult?.state) {
            updater.cancelDeferredInstallation()
        }
    }
    var v4AcquisitionBlocked: Bool { v4UpdateWaitEngine.state == .committing }
    var v4ReplacementBoundaryValid: Bool {
        guard hasCoordinatorAuthority, let context = v4CurrentContext, context.permitsWork(at: ContinuousTime.now),
              context.power == .ac, !context.isMacBook || context.lidClosed == false,
              !lidReleasePending, coordinatedLidError == nil else { return false }
        if v4UpdateWaitEngine.state == .committing, let snapshot = v4UpdateSnapshot {
            return v4UpdateWaitEngine.finalCheck(snapshot: snapshot, now: ContinuousTime.now).state == .committing
        }
        return true
    }
    var v4CanReplaceNow: Bool { acceptingUserCommands && v4ReplacementBoundaryValid }
    func installUpdateNow() {
        userSession?.refresh()
        guard !userCommandsArePreview, !developmentService, v4CanReplaceNow else {
            errorText = L("Confirm AC, an open MacBook and protection/recovery before installing.", "설치 전에 AC·열린 MacBook·보호 및 원복 상태를 확인하세요."); return
        }
        v4UpdateWaitEngine.cancel(); v4UpdateWaitResult = nil
        if !updater.installVerifiedDeferredUpdate() && !updater.beginExplicitReservedPreparation() {
            updater.deferUntilWorkEnds = false; checkForUpdates(force: true)
        }
    }
}
