import SwiftUI
import TetherCore

struct LidPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            Section {
                Picker(L("When the lid closes", "덮개를 닫으면"), selection: $model.lidCloseLocks) {
                    Text(L("Stay unlocked, dim the screen", "잠그지 않고 화면만 어둡게")).tag(false)
                    Text(L("Lock the screen", "화면 잠그기")).tag(true)
                }
                .disabled(!ScreenLock.available && !model.lidCloseLocks)
                LabeledContent(L("Built-in screen and keyboard light", "내장 화면과 키보드 조명")) {
                    Text(L("dimmed to 0 · restored when the lid opens", "0으로 내림 · 덮개를 열면 복원"))
                }
                LabeledContent(L("With an external display", "외장 모니터가 있을 때")) {
                    Text(L("left to macOS · never locked", "macOS에 맡김 · 잠그지 않음"))
                }
            } header: {
                Text(L("Lid Closed", "덮개를 닫았을 때"))
            } footer: {
                Note(model.lidCloseLocks
                     ? L("It locks the moment the lid closes. Opening the lid or connecting remotely asks for your password or Touch ID, and display sleep and locking follow your macOS settings.",
                         "덮개를 닫는 순간 잠겨요. 덮개를 열거나 원격으로 접속하면 암호나 Touch ID가 필요하고, 화면 끄기와 잠금은 macOS 설정을 그대로 따라요.")
                     : L("Nothing locks, so remote sessions and reopening the lid carry on right away. The screen under the lid is dimmed so it doesn't heat up.",
                         "잠그지 않으니 원격 접속이나 덮개를 열 때 바로 이어서 쓸 수 있어요. 덮개 아래에서 화면이 켜진 채 열이 나지 않도록 어둡게 해요."))
            }

            Section {
                Picker(L("Turn the screen off when idle", "입력이 없으면 화면 끄기"), selection: $model.idleBlankMinutes) {
                    ForEach(AppModel.idleChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? L("Never", "사용 안 함") : L("After \(minutes) min", "\(minutes)분 뒤")).tag(minutes)
                    }
                }
            } header: {
                Text(L("Screen Off Without Locking", "잠금 없이 화면 끄기"))
            } footer: {
                Note(model.lidCloseLocks
                     ? L("With “Lock the screen”, macOS's own display sleep and lock apply, so this isn't used.",
                         "'화면 잠그기'를 고르면 macOS의 화면 끄기·잠금 설정을 따르므로 쓰지 않아요.")
                     : L("In clamshell mode macOS's display sleep is held off so nothing locks. Instead, when idle, Tether turns the screen black; any input brings it straight back. It waits while another app keeps the screen on, like a video or a call.",
                         "클램쉘 모드에서는 화면이 잠기지 않도록 macOS의 화면 끄기를 막아요. 대신 입력이 없으면 Tether가 화면을 검게 만들고, 마우스나 키보드를 쓰면 바로 돌아와요. 동영상이나 화상 회의처럼 다른 앱이 화면을 켜 두는 동안에는 끄지 않아요."))
            }
            .disabled(model.lidCloseLocks)
        }
    }
}
