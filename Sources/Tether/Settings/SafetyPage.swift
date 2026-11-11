import SwiftUI
import TetherCore

/// Edits app-wide permissions and event policies; automatic conditions have one editor.
struct SafetyPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var showAutomaticConditions = false
    @State private var unplugExpanded = true
    @State private var closedLidDisplayExpanded = false
    @State private var scopeDetailsExpanded = false

    var body: some View {
        SettingsForm {
            if let problem = model.problem, case .translocated = problem {
                ProblemBanner(problem: problem, model: model, compact: false, embeddedInForm: true)
                    .accessibilityIdentifier("settings-translocation-context")
            }
            SettingsContentGroup(L("Automatic keep-awake", "자동 유지"),
                summary: L("Saves immediately", "즉시 저장"), summaryIdentifier: "settings-power-save-scope") {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsToggle(title: L("Allow automatic start", "자동 시작 허용"),
                        detail: automaticStatusSummary,
                        isOn: Binding(get: { model.automaticEnabled }, set: { model.setAutomaticEnabled($0) }),
                        identifier: "automatic-ac-toggle", detailIdentifier: "settings-automatic-start-state")
                        .disabled(settingsControlsDisabled)
                        .help(model.automaticStartStateDetail)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            automaticConditionsSummary
                            automaticConditionsButton
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            automaticConditionsSummary
                            automaticConditionsButton
                        }
                    }
                    .padding(.leading, SettingsMetrics.checkboxTextInset)
                }
            }

            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                if model.hasInternalBattery {
                    PowerEventSettingsSection(title: L("When power disconnects", "전원을 분리하면"),
                        outcome: disconnectEventSummary, outcomeIdentifier: "settings-unplug-policy-summary",
                        isExpanded: unplugExpansion) {
                        SettingRow(title: L("Active work", "진행 중인 유지")) {
                            CompactPopUp(title: L("Unplug policy", "전원 분리 규칙"), selection: Binding(
                                get: { model.v3Settings.disconnectPolicy }, set: { model.setDisconnectPolicy($0) }), choices: [
                                PopupChoice(WorkSessionDisconnectPolicy.endAll, L("End all · Recommended", "모두 끝내기 · 권장")),
                                PopupChoice(.endAutomatic, L("End automatic only", "자동 유지 끝내기")),
                                PopupChoice(.continueEligible, L("Continue eligible work", "허용된 유지 계속"))
                            ], identifier: "settings-unplug-policy-control").disabled(settingsControlsDisabled)
                        }.accessibilityIdentifier("settings-unplug-policy")
                        Note(disconnectSummary)
                        if model.showsLidOptions && model.v3Settings.allowClosedLid {
                            SettingRow(title: L("After the last work ends", "마지막 유지 종료 후"),
                                detail: L("With the lid closed after power disconnects", "전원 분리 후 덮개가 닫혀 있을 때"),
                                showsAccessibleTitle: false) {
                                CompactPopUp(title: L("Unplugged with lid closed", "닫힌 채 전원 분리"), selection: Binding(
                                    get: { model.v3Settings.disconnectAction }, set: { model.setDisconnectAction($0) }), choices: [
                                    PopupChoice(WorkSessionEndAction.sleepIfClosed, L("Request sleep · Recommended", "잠자기 요청 · 권장")),
                                    PopupChoice(.followOS, L("Follow macOS", "macOS에 맡김"))
                                ], identifier: "closed-lid-disconnect-picker").disabled(settingsControlsDisabled)
                            }
                        }
                    } status: { EmptyView() }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-unplug-details")
                }

                if model.showsLidOptions {
                    PowerEventSettingsSection(title: L("When the lid closes", "덮개를 닫으면"),
                        outcome: closedLidEventSummary, outcomeIdentifier: "settings-closed-lid-saved-summary",
                        isExpanded: closedLidDisplayExpansion) {
                        SettingsToggle(title: WorkPermissionText.lidTitle,
                            detail: lidStatusNeedsAttention ? nil : model.lidUsageStatusText,
                            isOn: GeneralPage(model: model).lidBinding, identifier: "closed-lid-allow-toggle",
                            detailIdentifier: "settings-lid-current-status")
                            .disabled(GeneralPage(model: model).lidControlDisabled)
                        if model.v3Settings.allowClosedLid { closedLidDisplayControls }
                    } status: { closedLidStatus }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-closed-lid-display-details")
                } else if showsClosedLidStatus {
                    VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                        Text(L("Closed-lid recovery", "덮개·화면 복구"))
                            .font(TetherTypography.settingsBody.weight(.medium))
                        closedLidStatus
                        if let error = model.coordinatedLidError { Note(error, color: .tetherWarning) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-closed-lid-recovery")
                }
                displayPermission
                SettingsDisclosure(title: L("Display sleep & behavior", "화면 꺼짐과 동작 안내"),
                    isExpanded: scopeDetailsExpansion, groupsSection: false,
                    identifier: "settings-power-scope-details") {
                    lockPolicyNote
                    lockScreenSettingsButton
                    Note(WorkPermissionText.scopeDetail)
                        .accessibilityIdentifier("settings-global-permission-scope")
                    if model.showsLidOptions {
                        Note(closedLidDisplayExplanation)
                        if let reason = model.closedLidDisplayAvailabilityReason {
                            Note(reason).accessibilityIdentifier("settings-closed-lid-display-availability")
                        }
                    }
                    if model.hasInternalBattery, model.showsLidOptions, model.v3Settings.allowClosedLid {
                        Note(disconnectExplanation)
                    }
                    Note(L("Connecting power may not wake a sleeping Mac. Unavailable conditions never authorize a start. Pausing automatic starts does not change a manual deadline.",
                           "전원을 연결해도 잠든 Mac이 깨어나지 않을 수 있습니다. 확인되지 않은 조건으로는 시작하지 않으며, 자동 시작을 쉬어도 수동 유지 기한은 바뀌지 않습니다."))
                }.accessibilityIdentifier("settings-power-scope-details")
            }
            if model.showsLidOptions { ClosedLidHelperSettingsContent(model: model, disclosures: disclosures, summaryOnly: true) }
        }
        .sheet(isPresented: $showAutomaticConditions) {
            V4AutomaticRulesView(model: model)
        }
    }

    private var automaticConditionsSummary: some View {
        Text(automaticConditionSummary)
            .font(TetherTypography.settingsSecondary)
            .foregroundStyle(Color.tetherSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings-automatic-mode-summary")
    }

    private var automaticConditionsButton: some View {
        Button(L("Conditions…", "조건 설정…")) { showAutomaticConditions = true }
            .buttonStyle(.link)
            .disabled(settingsControlsDisabled)
            .accessibilityIdentifier("settings-automatic-rules")
    }

    private var displayPermission: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsToggle(title: WorkPermissionText.displayTitle,
                detail: model.displayUsageStatusText,
                isOn: Binding(get: { model.v3Settings.keepDisplayAwake }, set: { model.setKeepDisplayAwake($0) }),
                identifier: "keep-display-awake-toggle", detailIdentifier: "settings-display-current-status")
                .disabled(settingsControlsDisabled)
            if let error = model.userSessionStatus?.displayError { Note(error, color: .tetherWarning) }
            if model.userSessionStatus?.ownReleasePending == true || model.userSessionStatus?.displayError != nil {
                refreshPowerStatusButton(identifier: "settings-refresh-display-status")
            }
        }
    }

    @ViewBuilder private var closedLidStatus: some View {
        if !model.showsLidOptions || !closedLidDisplayExpansion.wrappedValue || lidStatusNeedsAttention {
            Note(model.lidUsageStatusText, color: lidStatusNeedsAttention ? .tetherWarning : .tetherSecondary)
                .accessibilityIdentifier("settings-lid-current-status")
        }
        if model.showsLidOptions && !model.helperSetupConfirmed
            && (model.v3Settings.allowClosedLid || closedLidDisplayExpansion.wrappedValue) {
            Note(L("Set up the helper below to use the Mac with the lid closed.", "덮개를 닫고 사용하려면 아래에서 도우미를 준비하세요."),
                 color: model.v3Settings.allowClosedLid ? .tetherWarning : .tetherSecondary)
                .accessibilityIdentifier("settings-lid-preparation-required")
        }
        if let status = model.closedLidDisplayStatusText {
            Note(status, color: model.closedLidDisplayRecoveryPending ? .tetherWarning : .tetherSecondary)
                .accessibilityIdentifier("settings-closed-lid-display-status")
        }
        if model.v3Settings.closedLidDisplayMode == .zeroBrightness, !model.canUseZeroBrightness,
           let reason = model.closedLidDisplayAvailabilityReason { Note(reason, color: .tetherWarning) }
        if model.closedLidDisplayRecoveryPending {
            CompactPushButton(L("Retry brightness restoration", "밝기 복구 다시 시도"),
                identifier: "settings-retry-brightness-restoration") { model.retryClosedLidDisplayRecovery() }
                .disabled(!model.hasCoordinatorAuthority || model.commandPending)
        }
        if model.lidReleasePending || (model.snapshot.observedLidClosed == nil
            && (model.v3Settings.allowClosedLid || closedLidDisplayExpansion.wrappedValue)) {
            refreshPowerStatusButton(identifier: "settings-refresh-lid-status")
        }
    }

    private func refreshPowerStatusButton(identifier: String) -> some View {
        Button(L("Check status again", "상태 다시 확인")) { model.refresh() }
            .buttonStyle(.link).disabled(model.commandPending).accessibilityIdentifier(identifier)
    }

    private var lidStatusNeedsAttention: Bool {
        model.lidReleasePending
            || model.userSessionStatus?.ownReleasePending == true
            || (model.v3Settings.allowClosedLid && (model.snapshot.observedLidClosed == nil || !model.helperSetupConfirmed))
    }
    var showsClosedLidStatus: Bool { model.showsLidOptions || model.closedLidDisplayRecoveryPending || model.lidReleasePending }
    var automaticEventTitle: String {
        model.v4Settings.usesAdvancedAutomaticConditions
            ? model.v3Settings.effectiveAutomaticCondition.title : L("Power connected", "전원 연결")
    }
    var automaticConditionSummary: String {
        model.v4Settings.usesAdvancedAutomaticConditions
            ? L("Advanced · ", "고급 · ") + model.v4RuleSummary + " · " + automaticEventTitle : automaticEventTitle
    }
    private var automaticStatusSummary: String {
        if model.userSessionStatus?.ownReleasePending == true || model.lidReleasePending {
            return L("Confirming release", "해제 확인 중")
        }
        if model.workProtectionReason != nil { return L("Stopped for protection", "보호로 중지됨") }
        if model.workPaused { return L("All work stopped", "모두 중지됨") }
        if model.automaticPauseActive { return L("Automatic paused", "자동만 일시 중지됨") }
        if model.automaticWorkReasonActive, model.workSessionHolding {
            return L("Automatic keep-awake active", "자동 유지 중")
        }
        if !model.automaticEnabled {
            return model.manualSessionActive && model.workSessionHolding
                ? L("Automatic off · manual work continues", "자동 꺼짐 · 수동 유지 계속")
                : L("Automatic start off", "자동 시작 꺼짐")
        }
        return L("Waiting for conditions", "조건 대기 중")
    }
    private var disconnectEventSummary: String {
        switch model.v3Settings.disconnectPolicy {
        case .endAll: L("End all current work", "현재 유지 모두 종료")
        case .endAutomatic: L("End automatic · eligible manual work continues", "자동 종료 · 허용된 수동 유지 계속")
        case .continueEligible: L("Continue battery-eligible work only", "배터리 허용 유지 계속")
        }
    }
    private var closedLidEventSummary: String {
        if model.v3Settings.allowClosedLid { return L("Closed-lid use allowed", "닫고 사용 허용") + " · " + closedLidDisplayTitle }
        return L("Closed-lid use off · Saved: ", "닫고 사용 꺼짐 · 저장: ") + closedLidDisplayTitle
    }
    private var lockPolicyNote: some View {
        Note(L("Display sleep and zero brightness do not unlock your Mac. Locking and password requirements follow macOS.",
               "화면 꺼짐과 밝기 0은 잠금 해제가 아닙니다. 잠금·암호 요구는 macOS 설정을 따릅니다."))
            .accessibilityIdentifier("settings-lock-policy-note")
    }
    private var lockScreenSettingsButton: some View {
        Button(L("Lock Screen settings…", "macOS 잠금 화면 설정…")) { model.open(.lockScreen) }
            .buttonStyle(.link).disabled(model.userCommandsArePreview || model.developmentService)
    }
    private var closedLidDisplayControls: some View {
        SettingRow(title: L("Built-in display when closed", "덮개를 닫으면 내장 화면을")) {
            CompactPopUp(title: L("Built-in display with the lid closed", "덮개를 닫으면 내장 화면을"), selection: Binding(
                get: { model.v3Settings.closedLidDisplayMode }, set: { model.setClosedLidDisplayMode($0) }), choices: [
                PopupChoice(ClosedLidDisplayMode.off, L("Turn display off", "화면 끄기")),
                PopupChoice(.zeroBrightness, L("Set brightness to zero", "밝기 0으로 낮추기"), enabled: model.canUseZeroBrightness),
                PopupChoice(.unchanged, L("Do not change", "변경하지 않기"))
            ], identifier: "settings-closed-lid-display-mode").disabled(settingsControlsDisabled)
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
    var unplugExpansion: Binding<Bool> { disclosures?.powerDisconnect ?? $unplugExpanded }
    private var scopeDetailsExpansion: Binding<Bool> { disclosures?.powerScope ?? $scopeDetailsExpanded }
    private var disconnectSummary: String {
        switch model.v3Settings.disconnectPolicy {
        case .endAll: L("Start new manual work separately to use the battery.", "배터리에서 사용하려면 새 수동 유지를 시작하세요.")
        case .endAutomatic: L("Only battery-eligible manual work continues within its original deadline and limit.", "배터리 사용이 허용된 수동 유지만 원래 기한·한도 안에서 계속합니다.")
        case .continueEligible: L("Only already eligible work continues. Deadlines and battery limits are not reset.", "이미 배터리 사용이 허용된 유지에만 적용됩니다. 기한과 한도는 초기화하지 않습니다.")
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
}
