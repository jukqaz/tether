import SwiftUI
import TetherCore

/// Updates are explicit. There is no reservation tied to running work.
struct UpdateInstallationView: View {
    @ObservedObject var model: AppModel
    @State private var confirmInstall = false

    var body: some View {
        if model.availableUpdate != nil {
            VStack(alignment: .leading, spacing: 8) {
                Button(L("Install now…", "지금 설치…")) {
                    confirmInstall = true
                }.actionButton()
                    .disabled(model.userCommandsArePreview || model.developmentService || model.commandPending)
                    .accessibilityIdentifier("update-install-now")
                Note(model.capabilities.hardware == .portable
                    ? L("Connect power and open the lid before installing. Tether ends its work and restores its changes first.",
                        "전원을 연결하고 덮개를 연 뒤 설치하세요. Tether의 유지를 끝내고 변경을 원복한 다음 설치합니다.")
                    : L("Tether ends its work and restores its changes before installing.",
                        "Tether의 유지를 끝내고 변경을 원복한 다음 설치합니다."))
            }
            .confirmationDialog(L("Install the update now?", "지금 업데이트를 설치할까요?"), isPresented: $confirmInstall) {
                Button(L("End own work and install", "자체 유지 종료 후 설치")) {
                    model.installUpdateNow()
                }
            } message: {
                Text(L("Ending Tether's work may interrupt closed-lid or remote work. Ended timers will not restart.",
                       "Tether의 유지가 끝나면 덮개·원격 작업이 중단될 수 있습니다. 끝난 타이머는 다시 시작하지 않습니다."))
            }
        }
    }
}
