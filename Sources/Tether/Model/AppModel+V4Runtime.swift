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
            enabled: v4Settings.expiryNoticeEnabled, notificationsAuthorized: notificationSettings.value.access == .allowed,
            warningMinutes: v4Settings.expiryNoticeMinutes)
        if !userCommandsArePreview {
            v4NotificationDelivery.remove(notice.invalidate)
            if let token = notice.submit { v4NotificationDelivery.submit(token, automaticContinues: state.automaticActive, sound: v4Settings.notificationSound) }
        }
        if let previous = v4PreviousManualID, previous != state.manualRequestID {
            let natural = state.manualEndReason == .time || state.manualEndReason == .batteryBudget || state.manualEndReason == .taskEnded
            if natural && (state.manualEndReason == .taskEnded ? v4Settings.notifyTaskEnd : v4Settings.notifyManualExpiry) && !userCommandsArePreview {
                NotificationSettingsMonitor.deliver(title: L("Manual keep-awake ended", "수동 유지가 끝났습니다"),
                    body: state.automaticActive ? L("AC automatic keep-awake continues.", "AC 자동 유지는 계속됩니다.")
                        : L("Tether released this request. This does not confirm OS Sleep or task success.", "Tether의 해당 요청을 해제했습니다. 실제 잠자기나 작업 성공을 뜻하지 않습니다."))
            }
        }
        v4PreviousManualID = state.manualRequestID

    }
    func handleV4Notice(_ token: V4ExpiryNoticeToken, action: V4ExpiryNoticeAction) {
        guard acceptingUserCommands, v4Settings.expiryNoticeEnabled, let controller = userSession else { return }
        controller.refresh()
        guard let context = v4CurrentContext else { return }
        let result = V4ExpiryNoticeEngine.validate(action: action, token: token,
            manual: controller.v4ManualSnapshot, context: context, now: ContinuousTime.now)
        switch result.intent {
        case .requestExtension(let minutes): extendManualSession(by: minutes)
        case .showDeadline:
            reviewingManualDeadline = true
            settingsPage = .general
            v4SettingsPresentationID = UUID()
        case .showCurrentState:
            v4SettingsPresentationID = UUID()
            errorText = L("This notification belongs to an ended or changed request. Check the current session.", "종료되거나 바뀐 요청의 알림입니다. 현재 세션을 확인하세요.")
        }
    }
    /// Block new acquisition only while Sparkle is preparing an explicit install.
    /// No work-completion watcher or automatic installation reservation remains.
    var v4AcquisitionBlocked: Bool { updater.installationRequested }
    var v4ReplacementBoundaryValid: Bool {
        guard hasCoordinatorAuthority, let context = v4CurrentContext,
              context.permitsWork(at: ContinuousTime.now), context.power == .ac,
              !context.isMacBook || context.lidClosed == false,
              !lidReleasePending, coordinatedLidError == nil else { return false }
        return true
    }
    var v4CanReplaceNow: Bool { acceptingUserCommands && v4ReplacementBoundaryValid }
    func installUpdateNow() {
        userSession?.refresh()
        guard !userCommandsArePreview, !developmentService, v4CanReplaceNow else {
            errorText = L("Confirm AC, an open MacBook and protection/recovery before installing.", "설치 전에 AC·열린 MacBook·보호 및 원복 상태를 확인하세요."); return
        }
        // Sparkle presents the selected update and owns any authentication.
        // Every eventual install/relaunch reply and quit checks the gate again.
        checkForUpdates(force: true)
    }
}
