import SwiftUI
import TetherCore

struct NotificationsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            Section {
                Toggle(L("A summary when the lid opens", "덮개를 열 때 세션 요약"), isOn: $model.sessionNotifications)
                Toggle(L("Sleep used a lot of battery", "잠자는 동안 배터리를 많이 썼을 때"), isOn: $model.notifySleepDrain)
                Toggle(L("A battery hold ended", "배터리 유지가 끝났을 때"), isOn: $model.notifyHoldEnd)
                Toggle(L("Overheating with the lid closed", "덮개를 닫은 채 과열될 때"), isOn: $model.notifyHeat)
                Toggle(L("Turned on or off from Shortcuts or a URL", "단축어·URL로 켜고 끌 때"), isOn: $model.notifyToggle)
            } footer: {
                Note(L("Sleep use is reported above \(Int(SleepLog.highDrain))% an hour. A stopped helper is always reported.",
                       "잠자는 동안 사용량은 시간당 \(Int(SleepLog.highDrain))%를 넘으면 알려요. 도우미가 멈췄을 때는 항상 알려요."))
            }
            Section {
                LabeledContent(L("macOS notification settings", "macOS 알림 설정")) {
                    Button(L("Open…", "열기…")) { model.open(.notifications) }
                }
            }
        }
    }
}
