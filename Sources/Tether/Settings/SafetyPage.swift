import SwiftUI
import TetherCore

/// Retains the saved raw page identity while grouping power and automation.
struct SafetyPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var showAdvancedRules = false
    @State private var connectionsExpanded = false

    var body: some View {
        SettingsForm {
            SettingsContentGroup(L("Automatic start", "자동 시작")) {
                SettingsToggle(title: model.v4Settings.usesAdvancedAutomaticConditions
                    ? L("Start with selected conditions", "선택한 조건으로 자동 시작")
                    : L("Start automatically on power", "전원 연결 시 자동 시작"),
                    isOn: Binding(get: { model.automaticEnabled }, set: { model.setAutomaticEnabled($0) }),
                    identifier: "automatic-ac-toggle")
                    .disabled(settingsControlsDisabled)
                SettingRow(title: L("Automatic mode", "자동 시작 방식")) {
                    Text(model.v4Settings.automaticMode == .advanced
                        ? L("Additional conditions", "추가 조건") : L("Power connection only", "전원 연결만"))
                        .foregroundStyle(Color.tetherSecondary)
                }.accessibilityIdentifier("settings-automatic-mode-summary")
                if model.automaticPauseActive {
                    Note(L("Automatic starts are paused. Resume from the menu; manual timer deadlines stay unchanged.",
                           "자동 시작만 쉬는 중입니다. 메뉴에서 재개할 수 있으며 수동 타이머 기한은 바뀌지 않습니다."))
                        .accessibilityIdentifier("settings-automatic-pause-summary")
                } else {
                    Note(model.automaticEnabled
                        ? model.v4Settings.usesAdvancedAutomaticConditions
                            ? L("Starts when the selected power range and conditions match, after protection checks.",
                                "선택한 전원 범위·추가 조건을 만족하고 보호 확인을 마치면 시작합니다.")
                            : L("Starts on an awake Mac after AC power and protection checks.",
                                "깨어 있는 Mac에서 전원 연결·보호 상태를 확인한 뒤 시작합니다.")
                        : L("Automatic start is off. Manual work and saved rules remain available.",
                            "자동 시작은 꺼져 있습니다. 수동 유지와 저장한 규칙은 그대로 사용할 수 있습니다."))
                }
            }

            SettingsContentGroup(L("When power is unplugged", "전원을 빼면")) {
                SettingRow(title: L("Existing work", "기존 작업 유지")) {
                    Picker(L("Unplug policy", "전원 분리 규칙"), selection: Binding(
                        get: { model.v3Settings.disconnectPolicy }, set: { model.setDisconnectPolicy($0) })) {
                        Text(L("End all · Recommended", "모두 끝내기 · 권장")).tag(WorkSessionDisconnectPolicy.endAll)
                        Text(L("End automatic only", "자동 유지 끝내기")).tag(WorkSessionDisconnectPolicy.endAutomatic)
                        Text(L("Continue eligible work", "허용된 유지 계속")).tag(WorkSessionDisconnectPolicy.continueEligible)
                    }.labelsHidden().pickerStyle(.menu).disabled(settingsControlsDisabled)
                }.accessibilityIdentifier("settings-unplug-policy")
                Note(model.disconnectPolicyDetail)
                if model.showsLidOptions && model.v3Settings.allowClosedLid {
                    SettingRow(title: L("If the lid is closed", "덮개가 닫혀 있다면"), showsAccessibleTitle: false) {
                        Picker(L("Unplugged with lid closed", "닫힌 채 전원 분리"), selection: Binding(
                            get: { model.v3Settings.disconnectAction }, set: { model.setDisconnectAction($0) })) {
                            Text(L("Request sleep · Recommended", "잠자기 요청 · 권장")).tag(WorkSessionEndAction.sleepIfClosed)
                            Text(L("Follow macOS", "macOS에 맡김")).tag(WorkSessionEndAction.followOS)
                        }.labelsHidden().pickerStyle(.menu).disabled(settingsControlsDisabled)
                            .accessibilityIdentifier("closed-lid-disconnect-picker")
                    }
                    Note(disconnectExplanation)
                }
            }

            SettingsContentGroup(L("Additional conditions and presets", "추가 조건과 프리셋")) {
                VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                    Text(model.v4Settings.automaticMode == .advanced ? model.v4RuleSummary
                        : L("Saved advanced rules are inactive", "저장한 고급 규칙은 사용하지 않는 중"))
                        .font(TetherTypography.body).foregroundStyle(Color.tetherSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-automatic-condition-summary")
                    Button(L("Edit advanced rules and presets…", "고급 규칙·프리셋 편집…")) { showAdvancedRules = true }
                        .actionButton().disabled(settingsControlsDisabled)
                        .accessibilityIdentifier("settings-automatic-rules")
                    Note(L("Changes take effect only after confirmation. Unplug, Stop all and protection still apply.",
                           "검토 후 적용해야 바뀝니다. 전원 분리·모두 중지·보호 규칙은 그대로 적용됩니다."))
                    if model.v4Settings.automaticMode == .advanced {
                        Button(L("Use AC power only", "AC 전원 연결 조건만 사용")) { model.setV4BasicAutomaticMode() }
                            .buttonStyle(.link).disabled(settingsControlsDisabled)
                            .accessibilityIdentifier("settings-use-basic-ac-mode")
                        SettingRow(title: L("Saved advanced power range", "고급 규칙의 저장된 전원 범위")) {
                            PowerConditionPicker(selection: Binding(get: { model.v3Settings.condition },
                                set: { model.setPowerCondition($0) }),
                                choices: model.hasInternalBattery ? PowerCondition.allCases : [.ac])
                                .disabled(settingsControlsDisabled)
                                .accessibilityIdentifier("settings-automatic-power-condition")
                        }
                    }
                }
            }

            SettingsDisclosure(title: L("How power and conditions work", "전원·자동 조건 안내"),
                summary: model.v4Settings.automaticMode == .advanced ? L("Advanced rules", "고급 규칙") : L("AC only", "AC 전용"),
                isExpanded: connectionsExpansion) {
                VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                    Note(L("Power-only mode keeps advanced presets saved without observing their app, device, network or calendar conditions.",
                           "전원 연결만 사용하면 고급 프리셋은 보존하며 앱·장비·네트워크·일정 조건을 관측하지 않습니다."))
                    Note(L("Unavailable conditions cannot authorize a start. Permissions require your explicit preparation action.",
                           "확인하지 못한 조건으로 시작하지 않습니다. 권한은 직접 준비할 때만 요청합니다."))
                    Note(L("Connecting power is not guaranteed to wake a sleeping Mac.",
                           "잠든 Mac을 전원 연결만으로 깨우는 동작은 보장하지 않습니다."))
                    Button(L("Display and closed-lid settings…", "화면·덮개 설정…")) { model.settingsPage = .general }
                        .buttonStyle(.link).accessibilityIdentifier("settings-go-to-keep-awake")
                }
            }.accessibilityIdentifier("settings-automatic-behavior-details")
        }
        .sheet(isPresented: $showAdvancedRules) {
            V4AutomaticRulesView(model: model, startInAdvancedMode: true)
        }
    }

    var disconnectExplanation: String {
        switch model.v3Settings.disconnectAction {
        case .sleepIfClosed:
            L("After the last eligible work ends, Tether releases its support, then requests sleep. macOS or other apps may delay sleep.",
              "마지막 유지가 끝나면 자체 지원을 해제한 뒤 잠자기를 요청합니다. macOS·다른 앱의 요청으로 잠자기가 지연될 수 있습니다.")
        case .followOS:
            L("After the last eligible work ends, Tether releases its support and lets macOS decide when to sleep. Other requests may keep the Mac awake.",
              "마지막 유지가 끝나면 자체 지원을 해제하고 잠자기는 macOS에 맡깁니다. 다른 요청으로 Mac이 계속 깨어 있을 수 있습니다.")
        }
    }

    private var settingsControlsDisabled: Bool { !model.acceptingUserCommands || model.commandPending }
    private var connectionsExpansion: Binding<Bool> { disclosures?.automaticConnections ?? $connectionsExpanded }
}
