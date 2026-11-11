import SwiftUI
import TetherCore

/// Retains the saved raw page identity while grouping power and automation.
struct SafetyPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var showAdvancedRules = false
    @State private var connectionsExpanded = false
    @State private var closedLidDisplayExpanded = false

    var body: some View {
        SettingsForm {
            if let problem = model.problem, case .translocated = problem {
                ProblemBanner(problem: problem, model: model, compact: false, embeddedInForm: true)
                    .accessibilityIdentifier("settings-translocation-context")
            }
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

            if model.hasInternalBattery {
                SettingsContentGroup(L("When Power Is Unplugged", "전원을 빼면")) {
                    SettingRow(title: L("Existing work", "기존 작업 유지")) {
                        CompactPopUp(title: L("Unplug policy", "전원 분리 규칙"), selection: Binding(
                            get: { model.v3Settings.disconnectPolicy }, set: { model.setDisconnectPolicy($0) }), choices: [
                            PopupChoice(WorkSessionDisconnectPolicy.endAll, L("End all · Recommended", "모두 끝내기 · 권장")),
                            PopupChoice(.endAutomatic, L("End automatic only", "자동 유지 끝내기")),
                            PopupChoice(.continueEligible, L("Continue eligible work", "허용된 유지 계속"))
                        ], identifier: "settings-unplug-policy-control").disabled(settingsControlsDisabled)
                    }.accessibilityIdentifier("settings-unplug-policy")
                    Note(model.disconnectPolicyDetail)
                    if model.showsLidOptions && model.v3Settings.allowClosedLid {
                        SettingRow(title: L("If the lid is closed", "덮개가 닫혀 있다면"), showsAccessibleTitle: false) {
                            CompactPopUp(title: L("Unplugged with lid closed", "닫힌 채 전원 분리"), selection: Binding(
                                get: { model.v3Settings.disconnectAction }, set: { model.setDisconnectAction($0) }), choices: [
                                PopupChoice(WorkSessionEndAction.sleepIfClosed, L("Request sleep · Recommended", "잠자기 요청 · 권장")),
                                PopupChoice(.followOS, L("Follow macOS", "macOS에 맡김"))
                            ], identifier: "closed-lid-disconnect-picker").disabled(settingsControlsDisabled)
                        }
                        Note(disconnectExplanation)
                    }
                }

            }

            displayAndLidPermissions
            if model.showsLidOptions { ClosedLidHelperSettingsContent(model: model, disclosures: disclosures) }

            SettingsDisclosure(title: L("Additional Conditions & Presets", "추가 조건과 프리셋"),
                summary: model.v4Settings.automaticMode == .advanced ? L("Advanced", "고급") : L("Saved", "보존됨"),
                isExpanded: connectionsExpansion) {
                VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                    Text(model.v4Settings.automaticMode == .advanced ? model.v4RuleSummary
                        : L("Saved advanced rules are inactive", "저장한 고급 규칙은 사용하지 않는 중"))
                        .font(TetherTypography.body).foregroundStyle(Color.tetherSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-automatic-condition-summary")
                    Note(L("Changes made in the advanced editor are saved only after you confirm them there.",
                           "고급 편집창에서 바꾼 내용은 그 창에서 확인해야 저장됩니다."))
                    Button(L("Edit advanced rules and presets…", "고급 규칙·프리셋 편집…")) { showAdvancedRules = true }
                        .actionButton().disabled(settingsControlsDisabled)
                        .accessibilityIdentifier("settings-automatic-rules")
                    Note(L("Connecting power cannot be guaranteed to wake a sleeping Mac. Unavailable conditions cannot authorize a start.",
                           "잠든 Mac을 전원 연결만으로 깨우지는 못할 수 있습니다. 확인하지 못한 조건으로는 시작하지 않습니다."))
                    if model.v4Settings.automaticMode == .advanced {
                        Note(L("The mode button below saves and applies immediately, separately from the advanced editor.",
                               "아래 시작 방식 버튼은 누르면 바로 저장·적용됩니다. 고급 편집창의 확인과는 별개입니다."))
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
                        Note(L("Power range changes save immediately. Active automatic work keeps the power range captured when it started.",
                               "전원 범위 변경은 즉시 저장됩니다. 진행 중인 자동 작업은 시작 당시의 전원 범위를 유지합니다."))
                    }
                    Note(L("Unplug, Stop all and protection rules still apply.",
                           "전원 분리·모두 중지·보호 규칙은 그대로 적용됩니다."))
                }
            }.accessibilityIdentifier("settings-automatic-behavior-details")
        }
        .sheet(isPresented: $showAdvancedRules) {
            V4AutomaticRulesView(model: model, startInAdvancedMode: true)
        }
    }

    private var displayAndLidPermissions: some View {
        SettingsContentGroup(L("Work Feature Permissions", "작업 기능 허용")) {
            SettingsToggle(title: WorkPermissionText.displayTitle,
                isOn: Binding(get: { model.v3Settings.keepDisplayAwake }, set: { model.setKeepDisplayAwake($0) }),
                identifier: "keep-display-awake-toggle")
                .disabled(settingsControlsDisabled)
            if model.showsLidOptions {
                SettingsToggle(title: WorkPermissionText.lidTitle,
                    isOn: GeneralPage(model: model).lidBinding, identifier: "closed-lid-allow-toggle")
                    .disabled(GeneralPage(model: model).lidControlDisabled)
                if model.v3Settings.allowClosedLid { closedLidDisplayControls }
                else {
                    SettingsDisclosure(title: L("Saved built-in display choice", "저장된 내장 화면 선택"),
                        summary: closedLidDisplayTitle, isExpanded: closedLidDisplayExpansion, groupsSection: false) {
                        closedLidDisplayControls
                    }.accessibilityIdentifier("settings-closed-lid-display-details")
                }
                if let status = model.closedLidDisplayStatusText {
                    Note(status).accessibilityIdentifier("settings-closed-lid-display-status")
                }
                if model.closedLidDisplayRecoveryPending {
                    CompactPushButton(L("Retry brightness restoration", "밝기 복구 다시 시도"),
                        identifier: "settings-retry-brightness-restoration") { model.retryClosedLidDisplayRecovery() }
                }
            }
            Note(WorkPermissionText.scopeDetail)
                .accessibilityIdentifier("settings-global-permission-scope")
            Note(L("Locking and password requirements follow macOS. Tether does not unlock the Mac.",
                   "잠금·암호 요구는 macOS 설정을 따릅니다. Tether가 잠금을 해제하지는 않습니다."))
                .accessibilityIdentifier("settings-lock-policy-note")
            Button(L("Lock Screen settings…", "macOS 잠금 화면 설정…")) { model.open(.lockScreen) }
                .buttonStyle(.link).disabled(model.userCommandsArePreview || model.developmentService)
            if let error = model.userSessionStatus?.displayError { Note(error, color: .tetherWarning) }
        }
    }

    private var closedLidDisplayControls: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingRow(title: L("Built-in display when closed", "닫혔을 때 내장 화면")) {
                CompactPopUp(title: L("Built-in display with the lid closed", "덮개를 닫으면 내장 화면을"), selection: Binding(
                    get: { model.v3Settings.closedLidDisplayMode }, set: { model.setClosedLidDisplayMode($0) }), choices: [
                    PopupChoice(ClosedLidDisplayMode.off, L("Turn display off", "화면 끄기")),
                    PopupChoice(.zeroBrightness, L("Set brightness to zero", "밝기 0으로 낮추기"), enabled: model.canUseZeroBrightness),
                    PopupChoice(.unchanged, L("Do not change", "변경하지 않기"))
                ], identifier: "settings-closed-lid-display-mode").disabled(settingsControlsDisabled)
            }
            Note(closedLidDisplayExplanation)
            if let reason = model.closedLidDisplayAvailabilityReason {
                Note(reason).accessibilityIdentifier("settings-closed-lid-display-availability")
            }
        }
    }
    private var closedLidDisplayTitle: String {
        switch model.v3Settings.closedLidDisplayMode {
        case .off: L("Turn display off", "화면 끄기")
        case .zeroBrightness: L("Brightness zero", "밝기 0")
        case .unchanged: L("Do not change", "변경하지 않기")
        }
    }
    private var closedLidDisplayExplanation: String {
        switch model.v3Settings.closedLidDisplayMode {
        case .off: L("Requests built-in display sleep; panel power is not measured.", "내장 화면 절전을 요청합니다. 패널 전력 측정값은 아닙니다.")
        case .zeroBrightness: L("Lowers brightness only. Display sleep, unlocking and remote connectivity are not confirmed.", "밝기만 낮춥니다. 화면 꺼짐·잠금 해제·원격 연결 성공을 뜻하지 않습니다.")
        case .unchanged: L("Tether leaves built-in display settings unchanged. macOS and other apps still apply.", "내장 화면 설정을 바꾸지 않습니다. macOS와 다른 앱의 설정은 계속 적용됩니다.")
        }
    }
    private var closedLidDisplayExpansion: Binding<Bool> { disclosures?.closedLidDisplay ?? $closedLidDisplayExpanded }

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
