import SwiftUI
import TetherCore

struct LidPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            Section {
                Picker(selection: $model.lidCloseLocks) {
                    Text(L("Stay unlocked, dim the screen", "잠그지 않고 화면만 어둡게")).tag(false)
                    Text(L("Lock the screen", "화면 잠그기")).tag(true)
                } label: {
                    InfoLabel(L("When the lid closes", "덮개를 닫으면"), info: SettingsInfo.lidCloses)
                }
                .disabled(!ScreenLock.available && !model.lidCloseLocks)
            } header: {
                Text(L("Lid Closed", "덮개를 닫았을 때"))
            } footer: {
                Note(model.lidCloseLocks
                     ? L("It locks as the lid closes, and display sleep and locking follow your macOS settings.",
                         "덮개를 닫으면 바로 잠기고, 화면 끄기와 잠금은 macOS 설정을 따라요.")
                     : L("Remote sessions and reopening the lid carry on right away. The screen and keyboard light under the lid go dark and come back when it opens; with an external display, macOS handles the screens.",
                         "원격 접속도, 덮개를 다시 열 때도 바로 이어서 쓸 수 있어요. 덮개 아래 화면과 키보드 조명은 꺼 두었다가 열면 돌아오고, 외장 모니터가 있으면 화면은 macOS가 맡아요."))
            }

            if !model.lidCloseLocks {
                Section {
                    Picker(selection: $model.idleBlankMinutes) {
                        ForEach(AppModel.idleChoices, id: \.self) { minutes in
                            Text(minutes == 0 ? L("Never", "사용 안 함") : L("After \(minutes) min", "\(minutes)분 뒤")).tag(minutes)
                        }
                    } label: {
                        InfoLabel(L("Turn the screen off when idle", "입력이 없으면 화면 끄기"), info: SettingsInfo.idleScreenOff)
                    }
                } header: {
                    Text(L("Screen Off Without Locking", "잠금 없이 화면 끄기"))
                } footer: {
                    Note(L("The screen goes black and comes straight back, unlocked, with any input. It waits during a video or a call.",
                           "화면을 검게 꺼 두었다가, 마우스나 키보드를 쓰면 잠금 없이 바로 돌아와요. 동영상이나 화상 회의 중에는 기다려요."))
                }
            }
        }
    }
}
