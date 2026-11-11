import SwiftUI
import TetherCore

struct NotificationSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: NotificationSettingsMonitor
    @State private var warningDetailsExpanded = false
    @State private var notificationDetailsExpanded = false
    private var canConfigure: Bool { !model.userCommandsArePreview && !model.developmentService && model.acceptingUserCommands }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsToggle(title: L("Notify when manual time expires", "수동 유지 시간 만료 알림"), isOn: Binding(
                get: { model.notifySessionEnd }, set: { model.setNotifySessionEnd($0) }))
                .disabled(!canConfigure)
            SettingsToggle(title: L("Linked work completion notification", "연동 작업 종료 알림"), isOn: Binding(
                get: { model.notifyLinkedTaskEnd }, set: { model.setNotifyLinkedTaskEnd($0) }))
                .disabled(!canConfigure)
            SettingsToggle(title: L("Expiry warning", "만료 전 예고"),
                detail: L("Once per timed manual session", "시간제 수동 유지마다 한 번"),
                isOn: Binding(get: { model.notifyExpiryWarning }, set: { model.setNotifyExpiryWarning($0) }))
                .disabled(!canConfigure)
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                SettingRow(title: L("Warn before expiry", "만료 전 알림 시점")) {
                    Picker(L("Warning time", "예고 시점"), selection: Binding(get: { model.v4Settings.expiryNoticeMinutes },
                        set: { model.setExpiryNoticeMinutes($0) })) {
                        ForEach(V4Settings.expiryNoticeMinuteChoices, id: \.self) { minutes in
                            Text(L("\(minutes) min", "\(minutes)분")).tag(minutes)
                        }
                    }.labelsHidden().pickerStyle(.menu)
                        // Rebuild the native menu so its selected title follows an in-place language change.
                        .id(model.language)
                        .disabled(!canConfigure || !model.notifyExpiryWarning)
                        .accessibilityIdentifier("settings-expiry-warning-minutes")
                }
                SettingsToggle(title: L("Expiry warning sound", "만료 예고 소리"), isOn: Binding(
                    get: { model.v4Settings.notificationSound }, set: { model.setNotificationSound($0) }))
                    .disabled(!canConfigure || !model.notifyExpiryWarning)
                SettingsDisclosure(title: L("Warnings and extensions", "만료 예고와 연장"),
                    isExpanded: $warningDetailsExpanded, groupsSection: false) {
                    Note(L("Past warning times are not replayed. The notice shows the deadline and offers +15 minutes only when the full extension is allowed. Ended manual work does not restart.",
                           "지난 예고는 다시 알리지 않습니다. 알림에서 기한을 확인하며 15분 전체 연장이 가능할 때만 +15분을 제공합니다. 종료된 수동 유지는 재시작하지 않습니다."))
                }.accessibilityIdentifier("settings-expiry-warning-details")
            }.padding(.leading, SettingsMetrics.hierarchyIndent)
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
            SettingsDisclosure(title: L("Notification details", "알림 안내"),
                isExpanded: $notificationDetailsExpanded, groupsSection: false) {
                Note(L("Past events are not replayed. macOS Focus and notification style can affect delivery; protection continues without alerts.",
                       "지난 동작은 다시 알리지 않습니다. 집중 모드·표시 방식에 따라 알림이 보이지 않아도 보호는 계속됩니다."))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-notifications-content")
    }
}
