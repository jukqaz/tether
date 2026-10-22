import Foundation
import TetherCore

/// Stable action identifiers shared by App Intents and the app's command entry points.
/// The retired global keyboard shortcut feature does not own these commands.
enum V4AutomationAction: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case startManual, endManual, pauseAll, automaticOn, automaticOff, status
    var id: Self { self }
    var title: String {
        switch self {
        case .startManual: L("Start manual work", "수동 시작")
        case .endManual: L("End manual only", "수동만 종료")
        case .pauseAll: L("Stop all", "모두 중지")
        case .automaticOn: L("AC automatic on", "AC 자동 켬")
        case .automaticOff: L("AC automatic off", "AC 자동 끔")
        case .status: L("Check status", "상태 확인")
        }
    }
}

struct V4AutomationResult: Equatable, Sendable {
    enum Outcome: String, Sendable { case accepted, alreadyProcessed, rejected, limited, unconfirmed }
    var outcome: Outcome
    var action: V4AutomationAction
    var message: String
    var succeeded: Bool { outcome == .accepted || outcome == .alreadyProcessed }
}

extension AppModel {
    /// No second power executor, unbounded queue or automatic permission request is introduced here.
    /// The optional preview boundary exists only for isolated regression tests.
    func performV4Automation(_ action: V4AutomationAction, minutes: Int? = nil,
                             useSavedDuration: Bool = true, allowPreview: Bool = false) async -> V4AutomationResult {
        func reply(_ outcome: V4AutomationResult.Outcome, _ message: String) -> V4AutomationResult {
            V4AutomationResult(outcome: outcome, action: action, message: message)
        }
        guard acceptingUserCommands, userSession != nil, !userCommandsArePreview || allowPreview else {
            return reply(.unconfirmed, L("Tether is not connected to the current app session. Open Tether and try again.",
                                         "현재 Tether에 연결할 수 없습니다. 앱을 연 뒤 다시 시도하세요."))
        }
        if action == .status {
            return reply(.accepted, presentation.title + " · " + powerValue)
        }
        guard !Task.isCancelled else { return reply(.unconfirmed, L("Command cancelled before confirmation.", "확인 전에 명령이 취소됐습니다.")) }
        if commandPending && action != .pauseAll && action != .endManual && action != .automaticOff {
            return reply(.rejected, L("Another command is being checked. Try again; this command will not replay later.",
                                      "다른 조작을 확인하고 있습니다. 다시 시도하세요. 이 명령은 나중에 재생하지 않습니다."))
        }
        switch action {
        case .startManual:
            guard !v4ManualApprovalPending, !manualSessionActive else {
                return reply(.rejected, L("A manual request already exists or is being checked. Its deadline was kept.",
                                          "이미 수동 유지가 있거나 확인 중입니다. 기존 마감을 보존했습니다."))
            }
            let duration = useSavedDuration ? (selectedManualMinutes == 0 ? nil : selectedManualMinutes) : minutes
            if !useSavedDuration, let duration, ![5, 10, 15, 30, 60, 120].contains(duration) {
                return reply(.limited, L("Choose 5, 10, 15, 30, 60, 120 minutes or Unlimited on AC.",
                                         "5·10·15·30·60·120분 또는 AC 무제한을 선택하세요."))
            }
            startManualSession(minutes: duration)
            guard let controller = userSession, let requestID = controller.manualRequestID else {
                return reply(.rejected, errorText ?? manualStartBlockedDetail)
            }
            // Delivery is not approval: the existing helper verification owns any rollback.
            let deadline = ContinuousTime.now + 5
            while v4ManualApprovalPending || lidCommandPending {
                guard controller.manualRequestID == requestID, controller.status.manualActive else {
                    return reply(.rejected, errorText ?? L("The manual request ended before confirmation.", "확인 전에 수동 요청이 종료됐습니다."))
                }
                guard ContinuousTime.now < deadline, !Task.isCancelled, acceptingUserCommands else {
                    return reply(.unconfirmed, L("The request was delivered but its result is unconfirmed. Check Tether; do not assume it started.",
                                                 "요청은 전달됐지만 결과를 확인하지 못했습니다. 시작됐다고 가정하지 말고 Tether에서 확인하세요."))
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard controller.manualRequestID == requestID, controller.status.manualActive, controller.status.holding else {
                return reply(.rejected, errorText ?? manualStartBlockedDetail)
            }
            if !controller.manualDisplayConfirmed, let displayError = controller.status.displayError {
                return reply(.unconfirmed, L("General work is active, but the requested display state is unconfirmed: ",
                                             "일반 유지는 동작하지만 요청한 화면 상태를 확인하지 못했습니다: ") + displayError)
            }
            return reply(.accepted, L("Manual request approved. Check Tether for the current display and closed-lid state.",
                                      "수동 유지 요청을 승인했습니다. 화면·덮개 적용 상태는 Tether에서 확인하세요."))
        case .endManual:
            guard manualSessionActive || v4ManualApprovalPending else {
                return reply(.alreadyProcessed, L("No manual work is active. Automatic choices were kept.", "실행 중인 수동 유지가 없습니다. 자동 선택은 보존했습니다."))
            }
            endManualSession()
            return manualSessionActive
                ? reply(.unconfirmed, L("Manual end is not confirmed. Check Tether.", "수동 종료를 확인하지 못했습니다. Tether에서 확인하세요."))
                : reply(.accepted, L("Manual request ended. Enabled AC automatic rules remain in effect.", "수동 요청을 종료했습니다. 켜 둔 AC 자동 조건은 계속 적용됩니다."))
        case .pauseAll:
            let alreadyPaused = workPaused && !manualSessionActive
            setEnabled(false)
            guard workPaused, !manualSessionActive else {
                return reply(.unconfirmed, L("Pause is not confirmed. Check Tether.", "일시중지를 확인하지 못했습니다. Tether에서 확인하세요."))
            }
            return reply(alreadyPaused ? .alreadyProcessed : .accepted,
                         L("Manual work ended and automatic rules paused. Saved automatic choices were kept.", "수동 유지를 끝내고 자동 조건을 일시중지했습니다. 저장된 자동 선택은 보존했습니다."))
        case .automaticOn, .automaticOff:
            let on = action == .automaticOn
            let unchanged = automaticEnabled == on
            setAutomaticEnabled(on)
            guard automaticEnabled == on else {
                return reply(.rejected, errorText ?? L("Automatic choice could not be saved.", "자동 선택을 저장하지 못했습니다."))
            }
            return reply(unchanged ? .alreadyProcessed : .accepted,
                on ? L("AC automatic enabled. Current power and protection still determine execution; paused work was not resumed.",
                       "AC 자동을 켰습니다. 실제 실행은 현재 전원·보호 조건을 따르며 일시중지를 해제하지 않습니다.")
                   : L("AC automatic disabled. Manual work was kept.", "AC 자동을 껐습니다. 수동 유지는 보존했습니다."))
        case .status: fatalError("Handled before mutation")
        }
    }
}
