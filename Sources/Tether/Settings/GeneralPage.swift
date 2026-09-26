import SwiftUI
import TetherCore

struct GeneralPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            Section {
                Toggle(L("Open at login", "로그인하면 자동으로 열기"),
                       isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            } footer: {
                Note(L("Keeping the screen unlocked, dimming with the lid closed and turning the screen off need this app running. The power rules themselves are kept by the helper even when the app is closed.",
                       "화면이 잠기지 않게 붙잡는 일, 덮개를 닫았을 때 어둡게 하기, 화면 끄기는 이 앱이 켜져 있어야 해요. 전원 규칙 자체는 앱이 꺼져 있어도 도우미가 지켜요."))
            }

            Section {
                Picker(L("Language", "언어"), selection: $model.language) {
                    Text(L("Same as macOS", "macOS와 같게")).tag(LanguageChoice.system)
                    Text("English").tag(LanguageChoice.english)
                    Text("한국어").tag(LanguageChoice.korean)
                }
            } footer: {
                Note(L("The tether command in Terminal uses the same language.", "터미널의 tether 명령도 같은 언어를 써요."))
            }

            Section {
                Picker(L("Panel", "패널"), selection: $model.panelCompact) {
                    Text(L("Full", "자세히")).tag(false)
                    Text(L("Compact", "컴팩트")).tag(true)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L("Appearance", "모양"))
            } footer: {
                Note(L("Compact shows the state and one row of controls; the button at the bottom of the panel switches too. Liquid Glass follows System Settings › Accessibility › Display › Reduce transparency.",
                       "컴팩트는 상태와 조작 한 줄만 보여 줘요. 패널 아래 버튼으로도 바꿀 수 있어요. 리퀴드 글래스는 시스템 설정 › 손쉬운 사용 › 디스플레이 › 투명도 줄이기를 따라요."))
            }

            Section {
                Toggle(L("Show the hold countdown and heat temperature", "배터리 유지 남은 시간과 발열 온도 표시"), isOn: $model.menuBarDetails)
            } header: {
                Text(L("Menu Bar", "메뉴바"))
            } footer: {
                Note(L("During a battery hold, a ring around the icon empties and the time left counts down to the second. With the lid closed and running hot, the battery temperature appears next to the icon.",
                       "배터리 유지 중에는 아이콘을 둘러싼 링이 줄어들고 남은 시간이 초 단위로 줄어요. 덮개를 닫고 뜨거울 때는 배터리 온도를 아이콘 옆에 보여 줘요."))
            }
        }
    }
}
