import SwiftUI
import TetherCore

/// Edits future manual defaults only; current work stays in the menu.
struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var manualBatteryExpanded = false
    @State private var manualLimitsDetailsExpanded = false

    var body: some View {
        SettingsForm {
            SettingsContentGroup(model.showsLidOptions ? L("Display & Lid", "화면·덮개") : L("Display", "화면"),
                summary: L("Apply to next start", "다음 시작에 적용")) {
                ManualDefaultsOptionsView(model: model, embedded: true, applicationDetails: disclosures?.manualApplication)
            }
            if model.hasInternalBattery {
                SettingsDisclosure(title: L("Power & Time Limits", "전원·시간 한도"),
                    summary: manualLimitsSummary, isExpanded: manualBatteryExpansion) {
                    Note(L("Saves immediately. Applies to future work.",
                           "즉시 저장되고 이후 유지부터 적용됩니다."))
                        .accessibilityIdentifier("settings-manual-limits-save-summary")
                    SettingRow(title: L("Manual power source", "수동 유지 전원"),
                        detail: L("Applies to new manual work", "다음 수동 유지부터 적용")) {
                        CompactPopUp(title: L("Manual work power range", "수동 유지 전원 범위"),
                            selection: Binding(get: { model.v3Settings.manualPowerCondition }, set: { model.setManualPowerCondition($0) }),
                            choices: PowerCondition.allCases.map { PopupChoice($0, $0.title) },
                            identifier: "settings-manual-power-condition")
                            .disabled(settingsControlsDisabled)
                    }
                    SettingRow(title: L("Battery time limit", "배터리 시간 한도"),
                        detail: L("New manual work and the next advanced automatic run",
                                  "새 수동 유지와 고급 자동의 다음 조건 구간에 적용")) {
                        CompactPopUp(title: L("Battery time limit", "배터리 시간 한도"),
                            selection: Binding(get: { model.v3Settings.batteryTimeLimit }, set: { model.setBatteryTimeLimit($0) }),
                            choices: WorkSessionBatteryLimit.allCases.map { PopupChoice($0, model.batteryLimitTitle($0)) },
                            identifier: "settings-battery-manual-limit")
                            .disabled(settingsControlsDisabled)
                    }
                    SettingsDisclosure(title: L("Saving & Battery Time", "저장 범위와 배터리 시간"),
                        isExpanded: manualLimitsDetailsExpansion, groupsSection: false) {
                        Note(L("Apply and Discard above only affect manual defaults. Reconnecting power does not refill the current work's battery time.",
                               "위의 적용·변경 취소는 수동 기본값에만 적용됩니다. 전원을 다시 연결해도 현재 유지의 배터리 시간은 늘지 않습니다."))
                            .accessibilityIdentifier("settings-manual-limits-save-scope")
                    }.accessibilityIdentifier("settings-manual-limits-application-details")
                }.accessibilityIdentifier("settings-manual-battery-details")
            }
        }
        .alert(L("Current manual keep-awake", "현재 수동 유지"), isPresented: $model.reviewingManualDeadline) {
            Button(L("Close", "닫기"), role: .cancel) {}
        } message: {
            Text(currentManualDetail)
        }
    }

    var currentManualDetail: String {
        if model.manualSessionActive, let until = model.manualSessionUntil {
            return L("Ends at \(Texts.time(until)). Extend or end it from the menu.", "\(Texts.time(until)) 종료됩니다. 메뉴에서 연장하거나 종료할 수 있습니다.")
        }
        if model.hasConfirmedUntimedManualSession {
            return L("Until ended. The original power, battery and protection limits still apply.", "종료할 때까지 유지합니다. 시작할 때의 전원·배터리·보호 한도는 계속 적용됩니다.")
        }
        if model.manualSessionActive {
            return L("Checking end time. The original limits still apply; an unavailable end time does not mean unlimited keep-awake.", "종료 시간 확인 중입니다. 기존 한도는 계속 적용되며, 종료 시간이 미확인이라고 무기한 유지를 뜻하지는 않습니다.")
        }
        return L("Manual keep-awake has ended.", "수동 유지를 종료했습니다.")
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
    private var manualLimitsDetailsExpansion: Binding<Bool> { disclosures?.manualLimitsApplication ?? $manualLimitsDetailsExpanded }
    private var manualLimitsSummary: String {
        "\(model.v3Settings.manualPowerCondition.title) · \(model.batteryLimitTitle(model.v3Settings.batteryTimeLimit))"
    }
}

/// Content only: protection stays within the page's one scroll viewport.
struct ProtectionSettingsContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingRow(title: L("Thermal protection", "열 보호"),
                detail: L("Critical thermal pressure always stops work", "위험 단계에서는 항상 중지합니다")) {
                Text(model.observedThermalSummary).foregroundStyle(thermalColor)
            }
            SettingsToggle(title: L("Also stop at serious thermal pressure", "심각한 열 상태에서도 중지"),
                isOn: Binding(get: { model.v3Settings.stopOnSeriousThermal }, set: { model.setStopOnSeriousThermal($0) }))
                .disabled(model.commandPending || !model.acceptingUserCommands)
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
