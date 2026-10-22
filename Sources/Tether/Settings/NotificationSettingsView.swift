import SwiftUI
import TetherCore

struct NotificationSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: NotificationSettingsMonitor
    private var canConfigure: Bool { !model.userCommandsArePreview && !model.developmentService && model.acceptingUserCommands }

    var body: some View {
        SettingsToggle(title: L("Manual deadline notification", "수동 유지 종료 알림"), isOn: Binding(
            get: { model.notifySessionEnd }, set: { model.setNotifySessionEnd($0) }))
            .disabled(!canConfigure)
        SettingsToggle(title: L("Warn 5 minutes before expiry", "만료 5분 전 예고"),
            detail: L("Off by default. Once per manual request; no catch-up alert when 5 minutes or less remain.",
                      "기본 꺼짐. 수동 요청당 한 번이며, 남은 시간이 5분 이하면 지난 예고를 바로 보내지 않습니다."),
            isOn: Binding(get: { model.notifyExpiryWarning }, set: { model.setNotifyExpiryWarning($0) }))
            .disabled(!canConfigure)
        Note(L("Deadline review is always available in the notice. +15 minutes appears only when the whole extension is allowed; ended work never restarts.",
               "예고에서 기한을 확인할 수 있습니다. 15분 전체 연장이 가능할 때만 +15분을 제공하며, 끝난 작업을 다시 시작하지 않습니다."))
        Divider()
        SettingsToggle(title: L("Overheating or state-check failure", "과열·상태 확인 실패"), isOn: $model.notifyHeat)
            .disabled(!canConfigure)
        if model.hasInternalBattery {
            SettingsToggle(title: L("Battery protection", "배터리 부족"), isOn: $model.notifyBatteryProtection)
                .disabled(!canConfigure)
        }
        SettingRow(title: L("Notification permission", "알림 허용")) {
            Text(monitor.value.title).foregroundStyle(.secondary)
        }.task { if canConfigure { await monitor.refresh() } }
        HStack(spacing: 12) {
            if monitor.value.access == .notRequested {
                Button(L("Allow notifications…", "알림 허용…")) { Task { await monitor.requestPermission() } }
            } else if monitor.value.access == .denied || monitor.value.access == .unavailable || !monitor.value.alerts {
                Button(L("Open Notification settings…", "알림 설정 열기…")) { model.open(.notifications) }
                    .buttonStyle(.link)
            }
            Spacer(minLength: 8)
            if monitor.busy {
                ProgressView().controlSize(.small).accessibilityLabel(L("Checking notification permission", "알림 권한 확인 중"))
            }
            Button(L("Check again", "다시 확인")) { Task { await monitor.refresh() } }.buttonStyle(.borderless)
                .accessibilityLabel(L("Check notification permission again", "알림 권한 다시 확인"))
        }.disabled(!canConfigure || monitor.busy)
        if let error = monitor.error { Note(error) }
        DisclosureGroup(L("Notification details", "알림 안내")) {
            Note(L("Alerts report overheating, missing observations or low battery. Turning alerts on does not replay old events. macOS Focus and notification style can affect delivery; protection works without alerts.",
                   "과열·관측 실패·배터리 부족을 알립니다. 알림을 켜도 지난 동작을 다시 알리지 않습니다. 집중 모드·알림 표시 방식에 따라 보이지 않을 수 있으며, 보호 기능은 알림 없이도 동작합니다."))
        }
    }
}
