import SwiftUI
import TetherCore

struct V4UpdateAfterWorkView: View {
    @ObservedObject var model: AppModel
    @State private var confirmInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = model.v4UpdateWaitTitle {
                PolicyNote(title).accessibilityIdentifier("update-after-work-status")
                HStack(spacing: 8) {
                    Button(L("Cancel reservation", "설치 예약 취소")) { model.cancelScheduledUpdate() }
                        .actionButton().accessibilityIdentifier("update-after-work-cancel")
                    installButton
                }
            } else if model.availableUpdate != nil {
                HStack(spacing: 8) {
                    Button(L("Install after this work", "이번 작업 후 설치")) { model.scheduleUpdateAfterWork() }
                        .actionButton().disabled(!model.canScheduleUpdateAfterWork || controlsDisabled)
                        .accessibilityIdentifier("update-after-work-schedule")
                    installButton
                }
            }
            if let reason = model.v4UpdateWaitUnavailableReason { PolicyNote(reason) }
            Note(L("Waits for tracked manual or linked work, not every app on the Mac. A new session or extension is checked again before replacement.",
                   "추적되는 수동·연결 작업을 기다립니다. Mac의 모든 앱 작업 완료를 보장하지 않으며, 교체 전에 새 작업과 연장을 다시 확인합니다."))
            PolicyNote(model.capabilities.hardware == .portable
                ? L("Required before replacement: normal AC, safe thermal state, valid session, own changes restored, and MacBook lid open.",
                    "교체 허용 조건: 정상 AC·열 상태·유효한 사용자·자체 변경 원복 완료·MacBook 덮개 열림.")
                : L("Required before replacement: normal AC, safe thermal state, valid session, and own changes restored.",
                    "교체 허용 조건: 정상 AC·열 상태·유효한 사용자·자체 변경 원복 완료."))
            Note(L("Reservation is for this app session only, for up to 24 hours. Restart, sleep, unplugging, protection or Pause all cancels approval. Choose again when ready.",
                   "예약은 현재 앱 실행 중 최대 24시간입니다. 재시작·Sleep·전원 분리·보호·모두 일시중지 시 설치 승인이 취소되며 준비되면 다시 선택하세요."))
            if model.v4UpdateNeedsAuthentication {
                PolicyNote(L("Administrator approval is required. Continue only with the install button; Tether does not authenticate automatically.",
                             "관리자 인증이 필요합니다. 설치 버튼으로 직접 계속하세요. 자동으로 인증하지 않습니다."))
            }
        }
        .confirmationDialog(L("Install the update now?", "지금 업데이트를 설치할까요?"), isPresented: $confirmInstall) {
            Button(model.v4UpdateNeedsAuthentication ? L("Authenticate and install…", "인증 후 설치…") : L("End own work and install", "자체 유지 종료 후 설치")) {
                model.installUpdateNow()
            }
        } message: {
            Text(L("Tether ends its own work and restores its changes first. Closed-lid or remote work may be interrupted. Ended manual sessions will not be restored.",
                   "Tether의 자체 유지를 종료하고 변경을 원복합니다. 덮개·원격 작업에 영향을 줄 수 있으며, 끝난 수동 유지는 복원하지 않습니다."))
        }
    }

    private var controlsDisabled: Bool { model.userCommandsArePreview || model.developmentService || model.commandPending }
    private var installButton: some View {
        Button(model.v4UpdateNeedsAuthentication ? L("Authenticate and install…", "인증 후 설치…") : L("Install now…", "지금 설치…")) {
            confirmInstall = true
        }.actionButton().disabled(controlsDisabled)
            .accessibilityIdentifier("update-install-now")
    }
}
