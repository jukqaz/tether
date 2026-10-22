import SwiftUI
import TetherCore

struct SafetyPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var alertsExpanded = false
    @State private var rulesExpanded = false

    var body: some View {
        SettingsForm {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                if let reason = model.workProtectionReason {
                    WorkSessionNote(title: L("Stopped for protection", "보호로 유지 중지"),
                        detail: protectionReason(reason), symbol: "exclamationmark.circle", color: .tetherWarning)
                    Button(L("Resume automatic rules", "자동 조건 재개")) { model.setEnabled(true) }
                        .actionButton(prominent: true)
                        .disabled(!model.canResumeWork || model.commandPending)
                    Note(L("Resume after the readings recover. Ended manual sessions are not restored.",
                           "상태가 회복되면 직접 다시 시작하세요. 끝난 수동 유지는 복원되지 않습니다."))
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: protectionReadingsConfirmed ? "checkmark.shield.fill" : "clock")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(observedThermalColor)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(currentStateSummary).font(TetherTypography.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(readingsSummary).font(TetherTypography.secondary)
                            .foregroundStyle(Color.tetherSecondary)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(protectionReadingsConfirmed
                        ? L("Protection normal", "보호 상태 정상")
                        : L("Checking protection state", "보호 상태 확인 중"))
                    .accessibilityValue(readingsSummary)
                }
                Divider().overlay(Color.tetherDivider)
                SettingRow(title: L("Thermal protection", "열 보호")) {
                    Text(L("Always on", "항상 켬")).foregroundStyle(Color.tetherSecondary)
                }
                Note(L("High thermal pressure ends automatic and manual work.", "과열되면 자동·수동 유지를 종료합니다."))
                if model.hasInternalBattery {
                    Divider().overlay(Color.tetherDivider)
                    SettingRow(title: L("Stop below", "잔량 하한"), showsAccessibleTitle: false) {
                        Picker(L("Stop below", "잔량 하한"), selection: Binding(
                            get: { model.batteryFloor }, set: { value in
                                var limits = model.limits; limits.batteryFloor = value; model.setLimits(limits)
                            })) {
                            ForEach(Array(Set(SafetyPolicy.floorChoices + [model.batteryFloor])).sorted(), id: \.self) {
                                Text("\($0)%").tag($0)
                            }
                        }.labelsHidden().pickerStyle(.menu)
                            .frame(width: SettingsMetrics.controlWidth, alignment: .trailing)
                            .disabled(model.commandPending)
                    }
                }
                if model.hasInternalBattery {
                    SettingRow(title: L("Battery manual limit", "배터리 수동 한도")) {
                        Text(L("Up to 2 hours", "최대 2시간")).foregroundStyle(Color.tetherSecondary)
                    }
                    SettingsToggle(title: L("Stop in Low Power Mode", "저전력 모드에서 종료"),
                        detail: L("When enabled, Low Power Mode ends Tether work. Protection remains independent.",
                                  "켜면 저전력 모드에서 Tether 유지를 끝냅니다. 열·잔량 보호는 별도로 동작합니다."),
                        isOn: Binding(get: { model.v4Settings.stopOnLowPowerMode }, set: { model.setV4StopOnLowPowerMode($0) }))
                        .disabled(model.commandPending || !model.acceptingUserCommands)
                }
                if let error = model.errorText { Note(error, color: .tetherError) }
            }
            Divider().overlay(Color.tetherDivider)
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                DisclosureGroup(L("Notifications", "알림"), isExpanded: alertsExpansion) {
                    VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                        NotificationSettingsView(model: model, monitor: model.notificationSettings)
                    }
                    .padding(.top, 6)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-protection-alerts-details")
                Divider().overlay(Color.tetherDivider)
                DisclosureGroup(L("Protection and resuming", "보호 기준과 다시 시작"), isExpanded: rulesExpansion) {
                    protectionRules.padding(.top, 6)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-protection-rules-details")
            }
        }
        .toggleStyle(.switch)
    }

    private var protectionRules: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingRow(title: L("macOS thermal state", "macOS 열 상태")) {
                Text(model.observedThermalSummary)
                    .font(TetherTypography.body.weight(.medium)).foregroundStyle(observedThermalColor)
            }
            if model.hasInternalBattery {
                SettingRow(title: L("Battery", "배터리")) {
                    Text(model.percentText).font(TetherTypography.body.weight(.medium)).monospacedDigit()
                }
            }
            Text(L("Thermal protection criteria", "열 보호 기준"))
                .font(TetherTypography.section).accessibilityAddTraits(.isHeader)
            Note(L("Serious or critical macOS thermal pressure always ends automatic and manual work.",
                   "macOS 열 상태가 심각·위험이면 자동·수동 유지를 항상 끝냅니다."))
            Note(model.hasInternalBattery
                ? L("Applies on AC and battery. Protection follows macOS thermal pressure, not an arbitrary CPU temperature threshold.",
                    "전원·배터리 모두 적용합니다. 임의의 CPU 온도 대신 macOS 열 상태를 기준으로 보호합니다.")
                : L("Protection follows macOS thermal pressure, not an arbitrary CPU temperature threshold.",
                    "임의의 CPU 온도 대신 macOS 열 상태를 기준으로 보호합니다."))
            Note(model.showsLidOptions
                ? L("If closed, release Tether's hold and request sleep once after safety checks.",
                    "닫혀 있으면 자체 유지 해제와 안전 확인 후 잠자기를 한 번 요청합니다.")
                : L("Only Tether's requests end.", "Tether의 요청만 끝냅니다."))
            if model.hasInternalBattery {
                Note(L("Low battery warnings or the reserve can end work early, even when time remains.",
                       "저전력 경고·잔량 하한에 따라 시간이 남아도 유지가 끝날 수 있습니다."))
            }
            Note(L("Resume explicitly when readings recover. Ended manual sessions are not restored. Protection works even with alerts off.",
                   "상태가 회복되면 직접 다시 시작하세요. 끝난 수동 유지는 복원되지 않으며 알림을 꺼도 보호는 동작합니다."))
            Note(L("The reported state is not a Celsius measurement or a guarantee of hardware health.",
                   "표시한 상태는 섭씨 온도 측정값이나 기기 내구성 보증이 아닙니다."))
        }
    }

    private var alertsExpansion: Binding<Bool> {
        disclosures?.protectionAlerts ?? $alertsExpanded
    }

    private var rulesExpansion: Binding<Bool> {
        disclosures?.protectionRules ?? $rulesExpanded
    }

    private var currentStateSummary: String {
        let state = protectionReadingsConfirmed
            ? L("Protection normal", "보호 정상")
            : L("Checking protection state", "보호 상태 확인 중")
        return state
    }

    private var readingsSummary: String {
        model.hasInternalBattery
            ? model.observedThermalSummary + " · " + model.percentText
            : model.observedThermalSummary
    }

    private var observedThermalColor: Color {
        switch model.userSessionStatus?.thermal ?? model.status?.thermal {
        case 1, 2: .tetherWarning
        case 3: .tetherError
        case 0: .tetherPrimary
        default: .tetherSecondary
        }
    }

    private var protectionReadingsConfirmed: Bool {
        guard let thermal = model.userSessionStatus?.thermal ?? model.status?.thermal,
              (0..<2).contains(thermal) else { return false }
        return !model.hasInternalBattery || model.batteryPercent != nil
    }
}
