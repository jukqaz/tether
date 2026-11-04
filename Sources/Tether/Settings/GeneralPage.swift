import SwiftUI
import TetherCore

/// Edits future manual defaults only; current work stays in the menu.
struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var manualBatteryExpanded = false
    @State private var showLinkedWork = false

    var body: some View {
        SettingsForm {
            SettingsContentGroup(L("Defaults for the Next Manual Start", "다음 시작 기본값")) {
                ManualDefaultsOptionsView(model: model, embedded: true)
            }
            if model.hasInternalBattery {
                SettingsDisclosure(title: L("Power Range & Time Limit", "전원 범위와 시간 한도"),
                    summary: model.v3Settings.manualPowerCondition.title, isExpanded: manualBatteryExpansion) {
                    SettingRow(title: L("Allowed power source", "사용할 전원")) {
                        CompactPopUp(title: L("Manual work power range", "수동 유지 전원 범위"),
                            selection: Binding(get: { model.v3Settings.manualPowerCondition }, set: { model.setManualPowerCondition($0) }),
                            choices: PowerCondition.allCases.map { PopupChoice($0, $0.title) },
                            identifier: "settings-manual-power-condition")
                            .disabled(settingsControlsDisabled)
                    }
                    SettingRow(title: L("Maximum on battery", "배터리 최대 유지 시간")) {
                        CompactPopUp(title: L("Battery time limit", "배터리 시간 한도"),
                            selection: Binding(get: { model.v3Settings.batteryTimeLimit }, set: { model.setBatteryTimeLimit($0) }),
                            choices: WorkSessionBatteryLimit.allCases.map { PopupChoice($0, model.batteryLimitTitle($0)) },
                            identifier: "settings-battery-manual-limit")
                            .disabled(settingsControlsDisabled)
                    }
                    Note(L("These two settings save immediately for the next start. Current work keeps its original limits. Reconnecting power does not refill battery time.",
                           "전원·한도는 변경 즉시 저장되어 다음 시작부터 적용됩니다. 현재 작업의 한도는 그대로이며 전원 재연결로 배터리 시간이 늘지 않습니다."))
                        .accessibilityIdentifier("settings-manual-limits-save-scope")
                }.accessibilityIdentifier("settings-manual-battery-details")
            }
            SettingsContentGroup(L("Start & Control", "시작과 조작")) {
                Note(L("Choose a duration, start, extend or end current work from the menu.",
                       "시간 선택·시작·연장·현재 작업 종료는 메뉴에서 합니다."))
                SettingRow(title: L("Until connected work ends", "연결된 작업이 끝날 때까지")) {
                    CompactPushButton(L("Connection Guide…", "연동 방법…"), identifier: "settings-linked-work-guide") {
                        showLinkedWork = true
                    }
                }
            }
        }
        .alert(L("Connected Work", "작업 연결"), isPresented: $showLinkedWork) {
            Button(L("Close", "닫기"), role: .cancel) {}
        } message: {
            Text(L("Start command- or PID-linked work with the CLI. When the connected work ends, only that request ends. This differs from an automatic running-app condition.",
                   "명령이나 PID에 연결한 유지는 CLI로 시작합니다. 연결된 작업이 끝나면 해당 요청만 끝납니다. 앱 실행 여부를 보는 자동 조건과는 별개입니다."))
        }
        .alert(L("Current manual session", "현재 수동 유지"), isPresented: $model.reviewingManualDeadline) {
            Button(L("Close", "닫기"), role: .cancel) {}
        } message: {
            if model.manualSessionActive, let until = model.manualSessionUntil {
                Text(L("Ends at \(Texts.time(until)). Extend or end it from the menu.", "\(Texts.time(until))에 끝납니다. 메뉴에서 연장하거나 끝낼 수 있습니다."))
            } else if model.manualSessionActive {
                Text(L("The original power, battery and protection limits still apply.", "시작할 때의 전원·배터리·보호 한도는 계속 적용됩니다."))
            } else { Text(L("This manual session has ended.", "이 수동 유지는 끝났습니다.")) }
        }
    }

    var lidAvailability: LidOptionAvailability { LidOptionAvailability(model: model) }
    var lidControlDisabled: Bool { lidAvailability.isDisabled }
    var lidBinding: Binding<Bool> {
        Binding(get: { model.v3Settings.allowClosedLid }, set: { value in
            guard lidAvailability.permits(value) else { return }
            model.setAllowClosedLid(value)
        })
    }
    private var settingsControlsDisabled: Bool { !model.acceptingUserCommands || model.commandPending }
    private var manualBatteryExpansion: Binding<Bool> { disclosures?.manualBattery ?? $manualBatteryExpanded }
}

/// Content only: protection stays within the page's one scroll viewport.
struct ProtectionSettingsContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingRow(title: L("Thermal protection", "열 보호")) {
                Text(L("Critical is always on", "위험 단계는 항상 켬")).foregroundStyle(Color.tetherSecondary)
            }
            SettingsToggle(title: L("Also stop at serious thermal pressure", "심각한 열 상태에서도 중지"),
                isOn: Binding(get: { model.v3Settings.stopOnSeriousThermal }, set: { model.setStopOnSeriousThermal($0) }))
                .disabled(model.commandPending || !model.acceptingUserCommands)
            SettingRow(title: L("Current thermal state", "현재 열 상태")) {
                Text(model.observedThermalSummary).foregroundStyle(thermalColor)
            }
            if model.hasInternalBattery {
                SettingRow(title: L("Stop below battery level", "배터리가 이보다 낮으면 끝내기"), showsAccessibleTitle: false) {
                    CompactPopUp(title: L("Stop below", "잔량 하한"), selection: Binding(
                        get: { model.batteryFloor }, set: { value in
                            var limits = model.limits; limits.batteryFloor = value; model.setLimits(limits)
                        }), choices: Array(Set(SafetyPolicy.floorChoices + [model.batteryFloor])).sorted().map {
                            PopupChoice($0, "\($0)%")
                        }, identifier: "settings-battery-protection-floor-control")
                        .disabled(model.commandPending || !model.acceptingUserCommands)
                }.accessibilityIdentifier("settings-battery-protection-floor")
            }
            SettingsToggle(title: L("Stop in Low Power Mode", "저전력 모드가 되면 멈추기"),
                isOn: Binding(get: { model.v4Settings.stopOnLowPowerMode }, set: { model.setV4StopOnLowPowerMode($0) }))
                .disabled(model.commandPending || !model.acceptingUserCommands)
                .accessibilityIdentifier("settings-low-power-stop")
            Note(L("Thermal state comes from macOS, not a Celsius reading. Critical always stops work; turning off notifications never disables protection.",
                   "열 상태는 macOS 기준이며 섭씨 온도가 아닙니다. 위험 단계는 항상 중지하고, 알림을 꺼도 보호는 계속됩니다."))
        }
    }

    private var thermalColor: Color {
        switch model.userSessionStatus?.thermal ?? model.status?.thermal {
        case 1, 2: .tetherWarning
        case 3: .tetherError
        case 0: .tetherPrimary
        default: .tetherSecondary
        }
    }
}
