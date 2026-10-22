import SwiftUI
import TetherCore

/// Retains the saved raw page identity while presenting Automatic start.
struct SafetyPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var showAdvancedRules = false
    @State private var connectionsExpanded = false

    var body: some View {
        SettingsForm {
            SettingsContentGroup(L("Start automatically when", "자동으로 시작할 조건")) {
                SettingsToggle(title: L("Allow automatic start", "자동 시작 허용"),
                    isOn: Binding(get: { model.automaticEnabled }, set: { model.setAutomaticEnabled($0) }))
                    .disabled(settingsControlsDisabled)
                    .accessibilityIdentifier("automatic-ac-toggle")
                PowerConditionPicker(selection: Binding(get: { model.v3Settings.condition },
                    set: { model.setPowerCondition($0) }), choices: model.hasInternalBattery ? PowerCondition.allCases : [.ac])
                    .disabled(settingsControlsDisabled)
                    .accessibilityIdentifier("settings-automatic-power-condition")
                Note(model.automaticPauseActive
                    ? L("Saved rules stay enabled. Manual timers continue with their original deadlines.",
                        "저장한 자동 조건은 유지됩니다. 수동 타이머는 원래 기한까지 계속됩니다.")
                    : model.automaticEnabled
                    ? L("Automatic work starts only when power and protection conditions allow it.", "전원과 보호 조건을 충족할 때 자동으로 시작합니다.")
                    : L("Automatic start is off. You can still edit conditions in advance.", "자동 시작은 꺼져 있습니다. 조건은 미리 편집할 수 있습니다."))
                AutomaticPauseControls(model: model)
                if model.hasInternalBattery && model.v3Settings.condition.includesBattery {
                    SettingsToggle(title: L("Allow new automatic work immediately after unplugging", "전원 분리 직후 새 배터리 자동 유지 허용"),
                        isOn: Binding(get: { model.v3Settings.startAutomaticOnBatteryDisconnect },
                                      set: { model.setStartAutomaticOnBatteryDisconnect($0) }))
                        .disabled(settingsControlsDisabled || model.v3Settings.disconnectPolicy != .continueEligible)
                    Note(L("Requires Continue eligible work as the unplug policy. Off by default, so ending work on unplug cannot immediately restart it.",
                           "‘허용된 유지 계속’ 분리 규칙에서만 적용합니다. 기본은 꺼짐으로, 전원 분리로 끝난 유지가 즉시 다시 시작하지 않습니다."))
                }
            }

            automaticCondition

            HStack(spacing: 8) {
                Button(L("Edit conditions…", "조건 편집…")) { showAdvancedRules = true }
                    .actionButton()
                    .disabled(settingsControlsDisabled)
                    .accessibilityIdentifier("settings-automatic-rules")
            }

            SettingsDisclosure(title: L("How automatic work runs", "자동 시작 동작 방식"),
                summary: model.v3Settings.condition.title, isExpanded: connectionsExpansion) {
                VStack(alignment: .leading, spacing: 8) {
                    Note(L("Automatic work requires the selected power range and protection checks. Missing observations or permissions never fall back to an unconditional rule.",
                           "자동 유지는 선택한 전원 범위와 보호 확인이 필요합니다. 조건이나 권한을 확인하지 못하면 무조건 시작하는 규칙으로 대신 실행하지 않습니다."))
                    Note(L("Closing the lid does not start work. Allow closed-lid work separately in Keep awake.",
                           "덮개를 닫는 것만으로 유지를 시작하지 않습니다. 덮개 유지는 잠자기 방지에서 따로 허용하세요."))
                    Note(L("The condition editor also provides inactive import/export copies and optional experimental conditions. Saving a choice does not grant permissions.",
                           "조건 편집에서 설정 가져오기·내보내기와 실험 조건을 관리합니다. 선택을 저장해도 권한은 자동 허용되지 않습니다."))
                    Button(L("Display and closed-lid settings…", "화면·덮개 설정…")) { model.settingsPage = .general }
                        .buttonStyle(.link)
                }
            }.accessibilityIdentifier("settings-automatic-behavior-details")
        }
        .sheet(isPresented: $showAdvancedRules) { V4AutomaticRulesView(model: model) }
    }

    private var automaticCondition: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.v4Settings.automaticMode == .acConnected ? model.v3Settings.condition.title : model.v4RuleSummary)
                    .font(TetherTypography.section)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(model.automaticPauseActive ? L("Resting", "잠깐 쉬는 중")
                    : model.automaticEnabled ? L("Automatic start on", "자동 시작 켬") : L("Automatic start off", "자동 시작 꺼짐"))
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.v4Settings.automaticMode == .acConnected
                ? model.disconnectPolicyDetail
                : L("Keep awake when the selected conditions and power range match. Unplugging follows your selected end policy.", "선택한 조건과 전원 범위를 충족하면 잠자기를 방지합니다. 전원 분리는 선택한 종료 규칙을 따릅니다."))
                .font(TetherTypography.body).foregroundStyle(Color.tetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.v4Settings.automaticMode == .advanced {
                Button(L("Use power connection only", "전원 연결 조건만 사용")) { model.setV4BasicAutomaticMode() }
                    .buttonStyle(.link).disabled(settingsControlsDisabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workSessionCardSurface()
        .accessibilityIdentifier("settings-automatic-condition-summary")
    }

    private var settingsControlsDisabled: Bool { !model.acceptingUserCommands || model.commandPending }
    private var connectionsExpansion: Binding<Bool> { disclosures?.automaticConnections ?? $connectionsExpanded }
}
