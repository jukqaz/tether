import SwiftUI
import TetherCore

/// The shipping menu panel observes the same session controller as Settings.
struct TetherPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var powerBattery: PowerBatteryMonitor
    /// Overrides only the viewport in layout tests; live panels follow their own screen.
    var maximumHeight: CGFloat? = nil
    var previewSettingsAction: (() -> Void)? = nil
    /// An embedded sheet returns through its presenter instead of opening
    /// settings behind an existing modal hierarchy.
    var settingsNavigationAction: ((SettingsPage) -> Void)? = nil
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var screenHeightLimit = WorkSessionMetrics.panelMaximumHeight
    @State private var chromeHeight: CGFloat = 104
    // Both ViewThatFits candidates share disclosure state when the body starts scrolling.
    @State private var workDetailsExpanded = false
    @State private var problemDetailsExpanded = false
    @State private var powerDetailsExpanded = false

    init(model: AppModel, maximumHeight: CGFloat? = nil, previewSettingsAction: (() -> Void)? = nil,
         expandedDetails: Bool = false, settingsNavigationAction: ((SettingsPage) -> Void)? = nil,
         expandedPowerDetails: Bool = false) {
        self.model = model
        _powerBattery = ObservedObject(wrappedValue: model.powerBattery)
        self.maximumHeight = maximumHeight
        self.previewSettingsAction = previewSettingsAction
        self.settingsNavigationAction = settingsNavigationAction
        _workDetailsExpanded = State(initialValue: expandedDetails)
        _problemDetailsExpanded = State(initialValue: expandedDetails)
        _powerDetailsExpanded = State(initialValue: expandedPowerDetails)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, WorkSessionMetrics.panelInset)
                .padding(.vertical, 6)
                .background { chromeMeasurement }
            Divider()
            // Reserve the measured chrome, including wrapped footer text.
            MenuPanelBody(maximumHeight: max(1, (maximumHeight ?? screenHeightLimit) - chromeHeight)) {
                panelContent.padding(.horizontal, WorkSessionMetrics.panelInset).padding(.vertical, 14)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            footer.padding(.horizontal, WorkSessionMetrics.panelInset).padding(.vertical, 10)
                .background { chromeMeasurement }
        }
        .frame(width: WorkSessionMetrics.panelWidth)
        // Constrain the stack as well as its measured body budget. Native controls
        // can round their intrinsic height between passes; the body must absorb it.
        .frame(maxHeight: maximumHeight ?? screenHeightLimit)
        .font(TetherTypography.body)
        .environment(\.tetherSettingsStyle, false)
        .tint(.tetherAccent)
        // The native popup owns its chrome; the content owns only its reading surface.
        .workSessionMenuSurface()
        .fixedSize(horizontal: false, vertical: true)
        .onPreferenceChange(MenuPanelChromeHeight.self) { measured in
            if measured > 0, abs(chromeHeight - measured - 2) > 0.5 { chromeHeight = measured + 2 }
        }
        .onExitCommand { dismiss() }
        .onChange(of: model.manualSessionActive) { _, active in
            if !active && !model.automaticWorkReasonActive { workDetailsExpanded = false }
        }
        .onChange(of: model.problem?.message) { _, _ in problemDetailsExpanded = false }
        .background { if maximumHeight == nil { MenuPanelScreenBridge(heightLimit: $screenHeightLimit) } }
        .background {
            if model.capabilities.internalBattery == true {
                PowerBatteryVisibilityBridge(monitor: powerBattery)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Tether").font(TetherTypography.body.weight(.semibold))
            Spacer(minLength: 8)
            moreActions
        }
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusTitle).font(TetherTypography.status)
                .fixedSize(horizontal: false, vertical: true)
            Text(statusExplanation)
                .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(automaticStartWaitingDetail == nil
                    ? "panel-status-detail" : "panel-automatic-waiting")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("panel-status")
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                statusSummary
                if actionVisibility.showsCurrentWork,
                   model.manualSessionActive || model.batteryHoldUntil != nil { currentWork }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(actionVisibility.showsCurrentWork
                ? "panel-current-work-section" : "panel-state-section")
            if model.workProtectionReason != nil {
                Text(protectionResumeExplanation)
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("panel-protection-resume-detail")
            }
            if model.v4ACDrainWarning {
                Text(L("Battery charge continues to decrease while connected to power.",
                       "전원 연결 중 배터리 잔량이 계속 줄고 있습니다."))
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("panel-ac-battery-decrease-note")
            }
            if let problem = model.problem {
                attention(title: problem.title, detail: problem.message, color: problem.color,
                    destination: problemDestination(problem), actionTitle: problem.reviewLabel,
                    collapsesDetail: problemHasDiagnosticDetails(problem))
            } else if needsLidReview {
                attention(title: model.helperSetupConfirmed
                    ? L("Closed-lid request needs review", "덮개 기능 적용 확인 필요")
                    : L("Closed-lid setup needs review", "덮개 기능 준비 필요"),
                    detail: model.helperSetupConfirmed
                        ? L("Review the current helper response and closed-lid request.", "현재 도우미 응답과 덮개 유지 요청 상태를 확인하세요.")
                        : L("Set up the helper to use your MacBook with the lid closed.", "덮개를 닫고 사용하려면 도우미를 설정하세요."),
                    color: .tetherWarning, destination: .safety)
            }
            if model.userSessionStatus?.ownReleasePending == true {
                attention(title: L("Confirming release", "잠자기 방지 해제 확인 중"),
                    detail: model.presentation.subtitle, color: .tetherWarning, destination: .protection)
            } else if model.lidReleasePending {
                attention(title: L("Closed-lid release needs confirmation", "덮개 설정 되돌리기 확인 필요"),
                    detail: L("General work and closed-lid recovery have separate results.",
                              "일반 잠자기 방지와 덮개 설정 복구 결과는 별도로 확인합니다."),
                    color: .tetherWarning, destination: .safety)
            }
            if showsDisplayRecoveryWarning { displayRecoveryAttention }
            if actionVisibility.showsNewManual {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle(model.automaticWorkReasonActive
                        ? L("Add manual keep-awake", "추가 수동 유지")
                        : L("Manual keep-awake", "수동 유지"))
                    ManualSessionControls(model: model, clock: model.clock, compact: true,
                        showBatteryScopeHint: false, presentation: .start,
                        prominentStart: true)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("panel-new-manual-section")
            }
            if actionVisibility.showsStartBlockedReason {
                Note(model.manualStartBlockedDetail)
            }
            if actionVisibility.showsQuickOptions || model.workPaused || model.workProtectionReason != nil
                || actionVisibility.showsAutomaticRest {
                VStack(alignment: .leading, spacing: 12) {
                    if actionVisibility.showsQuickOptions || model.workPaused || model.workProtectionReason != nil {
                        MenuKeepAwakeControls(model: model, canEdit: actionVisibility.showsQuickOptions,
                            openHelperSetup: { showSettings(page: .safety) })
                    }
                    if actionVisibility.showsAutomaticRest {
                        AutomaticPauseControls(model: model, compact: true)
                    }
                }
            }
            if model.capabilities.internalBattery == true || actionVisibility.showsWorkDetails
                || actionVisibility.showsAutomaticToggle {
                VStack(alignment: .leading, spacing: 10) {
                    if model.capabilities.internalBattery == true {
                        Divider()
                        PowerBatteryDetails(monitor: powerBattery, isExpanded: $powerDetailsExpanded)
                    }
                    if actionVisibility.showsWorkDetails || actionVisibility.showsAutomaticToggle { workDetails }
                }
            }
            if let summary = model.otherAppKeepAwakeSummary {
                Button(summary) {
                    if settingsNavigationAction != nil {
                        model.otherAppDetailsRequested = true
                        showSettings(page: .protection)
                    } else {
                        model.showOtherAppKeepAwakeDetails()
                    }
                }
                    .buttonStyle(.link).font(TetherTypography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("panel-other-app-requests")
            }
        }
    }

    private func problemDestination(_ problem: AppModel.Problem) -> SettingsPage {
        if case .error = problem { return .protection }
        return .safety
    }

    private func problemHasDiagnosticDetails(_ problem: AppModel.Problem) -> Bool {
        switch problem {
        case .error, .lid: true
        case .translocated, .missing, .down, .outdated: false
        }
    }

    var actionVisibility: MenuActionVisibility { MenuActionVisibility(model: model) }
    var showsCurrentWork: Bool { actionVisibility.showsCurrentWork }

    var showsDisplayRecoveryWarning: Bool { model.closedLidDisplayRecoveryPending }
    var canRetryDisplayRecovery: Bool {
        showsDisplayRecoveryWarning && model.hasCoordinatorAuthority && !model.commandPending
    }

    func retryDisplayRecovery() {
        guard canRetryDisplayRecovery else { return }
        model.retryClosedLidDisplayRecovery()
    }

    private var displayRecoveryAttention: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Display brightness still needs recovery", "화면 밝기 복구가 남아 있습니다"))
                .foregroundStyle(Color.tetherWarning)
            Text(L("The previous brightness has not been restored. Retry without starting a keep-awake session.",
                   "이전 밝기를 아직 되돌리지 못했습니다. 유지를 시작하지 않고 복구만 다시 시도합니다."))
                .foregroundStyle(Color.tetherSecondary)
            Button(L("Retry brightness restoration", "밝기 복구 다시 시도"), action: retryDisplayRecovery)
                .buttonStyle(.link)
                .disabled(!canRetryDisplayRecovery)
                .accessibilityIdentifier("panel-retry-brightness-restoration")
        }
        .font(TetherTypography.body)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel-brightness-recovery")
    }

    var needsLidReview: Bool {
        guard model.showsLidOptions, model.v3Settings.allowClosedLid else { return false }
        if model.lidReleasePending || model.closedLidDisplayRecoveryPending { return false }
        // A saved permission is not a demand from every current request. In
        // particular, a manual timer may have captured closedLid=false.
        if model.workSessionHolding, model.userSession?.v4LidRequested == false { return false }
        return !model.helperSetupConfirmed || (model.workSessionHolding && !model.lidSupportConfirmed)
    }

    var currentAutomaticSummary: String {
        guard model.automaticWorkReasonActive,
              let condition = model.v3Settings.runtimeMarkers?.automaticActivation?.condition else {
            return model.v4RuleSummary
        }
        // Power scope belongs to this activation. Editing the next default is
        // not a new activation and must not relabel work that is still running.
        return model.v4Settings.usesAdvancedAutomaticConditions
            ? condition.title + " · " + model.v4RuleSummary : condition.title
    }

    private var currentWork: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.automaticWorkReasonActive {
                AutomaticSessionCountdown(model: model, clock: model.clock)
            }
            if model.manualSessionActive {
                ManualSessionControls(model: model, clock: model.clock, compact: true,
                    showBatteryScopeHint: false, presentation: .current,
                    showsSessionLabel: model.automaticWorkReasonActive)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(TetherTypography.section)
            .foregroundStyle(Color.tetherSecondary).accessibilityAddTraits(.isHeader)
    }

    private var automaticControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { model.v3Settings.automaticEnabled },
                                 set: { model.setAutomaticEnabled($0) })) {
                Text(L("Allow automatic starts", "자동 시작 허용"))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
                .toggleStyle(.checkbox).controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("panel-automatic")
                .accessibilityLabel(L("Allow automatic starts", "자동 시작 허용"))
                .accessibilityHint(model.v3Settings.effectiveAutomaticCondition.title + ". " + L("Turning this off ends automatic work only.", "끄면 자동 유지만 종료합니다."))
                .disabled(!model.acceptingUserCommands || model.commandPending)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var automaticStartWaitingDetail: String? {
        guard model.automaticEnabled, !model.workPaused, !model.automaticPauseActive, !model.automaticWorkReasonActive,
              model.problem == nil else { return nil }
        if model.snapshot.power == .unknown {
            return L("Checking power before evaluating automatic starts", "전원 상태를 확인한 뒤 자동 시작 조건을 확인합니다")
        }
        let condition = model.v3Settings.effectiveAutomaticCondition
        if condition.permits(model.snapshot.power) {
            return model.v4Settings.usesAdvancedAutomaticConditions
                ? L("Waiting for the selected conditions", "선택한 조건을 기다리는 중") : nil
        }
        if model.v4Settings.usesAdvancedAutomaticConditions {
            if condition == .battery {
                return L("Requires battery power and matching conditions", "배터리 사용과 선택한 조건을 모두 만족해야 시작합니다")
            }
            return L("Requires AC power and matching advanced conditions", "전원 연결과 선택한 고급 조건을 모두 만족해야 시작합니다")
        }
        return condition == .battery
            ? L("Starts when using battery power", "배터리 사용 시 시작합니다")
            : L("Starts when power is connected", "전원을 연결하면 시작합니다")
    }

    var statusTitle: String {
        if model.workProtectionReason != nil { return L("Stopped for protection", "보호로 중지됨") }
        if model.lidReleasePending || model.closedLidDisplayRecoveryPending {
            return L("Recovery needs attention", "복구 확인 필요")
        }
        if model.workPaused
            || model.userSessionStatus?.ownReleasePending == true
            || model.userSessionStatus?.observationLimited == true
            || model.userSessionStatus?.error != nil || model.automaticBatteryEnded {
            return model.presentation.title
        }
        if model.manualSessionActive && model.automaticWorkReasonActive {
            return L("Automatic + manual active", "자동·수동 유지 중")
        }
        if model.manualSessionActive { return L("Manual keep-awake active", "수동 유지 중") }
        if model.automaticWorkReasonActive { return L("Automatic keep-awake active", "자동 유지 중") }
        if model.automaticPauseActive { return L("Automatic starts paused", "자동만 일시 중지됨") }
        if model.automaticEnabled { return L("Waiting to start automatically", "자동 시작 대기 중") }
        return L("Keep-awake off", "잠자기 방지 꺼짐")
    }

    var statusDetail: String? {
        if model.workProtectionReason != nil { return model.presentation.subtitle }
        if model.lidReleasePending || model.closedLidDisplayRecoveryPending {
            return L("Review restoration of the previous closed-lid or display settings.",
                     "이전 덮개·화면 설정의 복구 상태를 확인하세요.")
        }
        if model.problem != nil { return nil }
        if model.automaticBatteryEnded { return model.presentation.subtitle }
        if model.userSessionStatus?.observationLimited == true {
            return L("Starting or extending keep-awake is unavailable while checking status", "상태 확인 중에는 시작하거나 시간을 연장할 수 없습니다")
        }
        if model.workPaused {
            return model.automaticPauseActive
                ? L("Resuming still keeps the automatic-only pause in effect. Ended manual sessions do not restart.",
                    "중지를 해제해도 자동 일시 중지는 유지됩니다. 종료된 수동 유지는 다시 시작하지 않습니다.")
                : model.presentation.subtitle
        }
        return nil
    }

    private var statusExplanation: String {
        if let statusDetail { return statusDetail }
        if model.automaticWorkReasonActive { return currentAutomaticSummary }
        if model.automaticPauseActive && !model.manualSessionActive {
            return L("You can start manual keep-awake separately.", "수동 유지는 따로 시작할 수 있습니다.")
        }
        if !model.automaticEnabled, !model.manualSessionActive {
            return L("Automatic start off", "자동 시작 꺼짐")
        }
        return automaticStartWaitingDetail ?? powerLabel
    }

    var disconnectPolicySummary: String {
        switch model.v3Settings.disconnectPolicy {
        case .endAll: return L("End all current work", "현재 유지 모두 종료")
        case .endAutomatic: return L("End automatic · eligible manual work continues", "자동 종료 · 허용된 수동 유지 계속")
        case .continueEligible: return L("Continue battery-eligible work only", "배터리 허용 유지 계속")
        }
    }

    private var workDetails: some View {
        DisclosureGroup(isExpanded: $workDetailsExpanded) {
            VStack(spacing: 0) {
                if actionVisibility.showsAutomaticToggle {
                    automaticControls.padding(.vertical, 8)
                    Divider()
                }
                workRow(title: L("Automatic power", "자동 시작 전원"),
                        detail: model.v3Settings.effectiveAutomaticCondition.title, badge: "")
                if model.hasInternalBattery {
                    Divider()
                    workRow(title: L("When unplugged", "전원 분리 시"),
                            detail: disconnectPolicySummary, badge: "")
                        .accessibilityIdentifier("panel-unplug-policy-summary")
                }
                if model.manualSessionActive && !model.automaticWorkReasonActive && !model.automaticPauseActive {
                    Divider()
                    Text(model.manualEndingDetail).font(TetherTypography.secondary)
                        .foregroundStyle(Color.tetherSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                }
                if model.showsLidOptions {
                    Divider()
                    workRow(title: closedLidPolicySummary, detail: closedLidDisconnectDetail, badge: "")
                }
            }
            .padding(.top, 5)
        } label: {
            HStack(spacing: 8) {
                Text(L("Work details", "유지 상세"))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(model.disconnectPolicyDetail)
                    .accessibilityIdentifier("panel-closed-lid-policy")
            }
            .font(TetherTypography.body).foregroundStyle(Color.tetherPrimary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel-active-work-details")
    }

    private func workRow(title: String, detail: String, badge: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TetherTypography.body).foregroundStyle(Color.tetherPrimary)
                Text(detail).font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if !badge.isEmpty { Text(badge).font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary) }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var closedLidPolicySummary: String {
        let lid = model.v3Settings.allowClosedLid
            ? L("Closed-lid use allowed", "덮개 닫고 사용 허용") : L("Closed lid follows macOS", "덮개 닫힘은 macOS 설정을 따름")
        return lid
    }

    private var closedLidDisconnectSummary: String {
        model.v3Settings.allowClosedLid && model.v3Settings.disconnectAction == .sleepIfClosed
            ? L("When unplugged and closed: request sleep after all sessions end", "닫힌 채 전원 분리: 마지막 유지 종료 후 잠자기 요청")
            : L("Closed-lid unplug: follow macOS", "닫힌 채 분리: macOS에 맡김")
    }

    private var closedLidDisconnectDetail: String {
        closedLidDisconnectSummary + ". " + L("Actual sleep may be affected by macOS and other apps.",
            "실제 잠자기는 macOS와 다른 앱의 영향을 받습니다.")
    }

    /// Keep the review action aligned with the warning it explains.
    private func attention(title: String, detail: String, color: Color, destination: SettingsPage,
                           actionTitle: String = L("View in settings…", "설정에서 확인…"),
                           collapsesDetail: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if collapsesDetail {
                Text(title).foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(L("Details", "상세 정보"), isExpanded: $problemDetailsExpanded) {
                    Text(detail).font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(TetherTypography.secondary)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("panel-problem-details")
            } else {
                Text(title).foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(actionTitle) { showSettings(page: destination) }
                .buttonStyle(.link)
                .accessibilityIdentifier("panel-review-settings")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if actionVisibility.showsStopAll || showsResumeControl { stopAllControl }
            Spacer(minLength: 6)
            if model.userCommandsArePreview { PreviewIndicator() }
            Button(L("Settings…", "설정…"), action: showSettings)
                .buttonStyle(.link).font(TetherTypography.secondary)
                .help(L("Settings", "설정"))
                .accessibilityLabel(L("Settings", "설정"))
                .accessibilityIdentifier("panel-open-settings")
                .keyboardShortcut(",", modifiers: .command)
        }
    }

    private var stopAllControl: some View {
        CompactPushButton(model.workPaused ? L("Resume", "중지 해제") : L("Stop all", "모두 중지"),
                          prominent: model.workPaused, identifier: "panel-pause-all") {
            changeStopState()
        }
        .accessibilityHint(model.workPaused
            ? model.automaticPauseActive
                ? L("Allow keep-awake again. The automatic-only pause still applies; ended manual sessions do not restart.", "잠자기 방지를 다시 허용합니다. 자동 유지의 일시 중지는 유지하며, 종료한 수동 유지는 다시 시작하지 않습니다.")
                : L("Recheck enabled automatic conditions. Ended manual sessions do not restart.", "켜 둔 자동 조건을 다시 확인합니다. 종료한 수동 유지는 다시 시작하지 않습니다.")
            : L("End manual keep-awake and pause automatic starts until you resume.", "수동 유지를 종료하고 중지를 해제할 때까지 자동 시작도 멈춥니다."))
        .disabled(!canChangeStopState)
    }

    /// A protection stop remains visible while its existing safety gate is closed.
    /// Reading or activating this control cannot bypass the model's resume policy.
    var showsResumeControl: Bool {
        actionVisibility.showsResume || (model.workProtectionReason != nil
            && model.userSessionStatus?.ownReleasePending != true)
    }

    var protectionResumeExplanation: String {
        guard model.usesUserSession else { return model.protectionResumeDetail }
        return model.canResumeWork
            ? L("Safe conditions confirmed. Resume rechecks automatic conditions; ended manual sessions do not restart.",
                "안전 상태를 확인했습니다. 중지를 해제하면 자동 조건을 다시 확인하며, 종료된 수동 유지는 다시 시작하지 않습니다.")
            : L("Safe conditions must hold for 60 seconds, with power and the active user confirmed, before resuming.",
                "안전한 상태가 60초 이어지고 전원·로그인 사용자가 확인되어야 중지를 해제할 수 있습니다.")
    }

    var canChangeStopState: Bool {
        model.sessionAvailable && !model.commandPending
            && (!model.workPaused || model.canResumeWork)
    }

    func changeStopState() {
        guard canChangeStopState else { return }
        model.setEnabled(model.workPaused)
    }

    private var powerLabel: String {
        if model.capabilities.internalBattery == true,
           powerBattery.phase == .fresh, let value = powerBattery.reading {
            let percent = value.batteryPercent.map { L("Battery \($0)%", "배터리 \($0)%") }
            let source: String
            switch value.source {
            case .ac: source = L("On power", "전원 연결")
            case .battery: source = L("On battery", "배터리 사용")
            case .unknown: source = L("Power unconfirmed", "전원 미확인")
            }
            return [source, percent].compactMap { $0 }.joined(separator: " · ")
        }
        switch model.snapshot.power {
        case .ac: return L("On power", "전원 연결 중")
        case .battery: return L("Battery \(model.percentText)", "배터리 사용 중 \(model.percentText)")
        case .unknown: return L("Power unconfirmed", "전원 미확인")
        }
    }

    private var chromeMeasurement: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: MenuPanelChromeHeight.self, value: geometry.size.height)
        }
    }

    private var moreActions: some View {
        CompactActionMenu(title: L("More actions", "다른 동작"), actions: [
            CompactMenuAction(L("Diagnostics…", "진단…")) {
                showSettings(page: .protection)
            },
            CompactMenuAction(L("Sleep…", "잠자기…"), separatorBefore: true,
                              enabled: model.sessionAvailable && !model.commandPending) {
                model.sleepNow()
            },
            CompactMenuAction(L("Quit Tether", "Tether 종료"), separatorBefore: true) {
                NSApplication.shared.terminate(nil)
            }
        ], identifier: "panel-more-actions")
    }

    private func showSettings() {
        showSettings(page: model.settingsPage)
    }

    private func showSettings(page: SettingsPage) {
        model.settingsPage = page
        if let settingsNavigationAction { settingsNavigationAction(page); return }
        if model.userCommandsArePreview {
            if let previewSettingsAction { previewSettingsAction() }
            else if NativeUIAutomation.currentBundleIsFixture { NSApp.activate(); openSettings(); dismiss() }
            return
        }
        if !model.userCommandsArePreview && !model.developmentService {
            NSApp.activate(); openSettings(); dismiss()
        }
    }
}

/// Automatic and manual work can coexist. Keep their clocks in separately named
/// rows; ending manual work must not make the automatic deadline disappear.
struct AutomaticSessionCountdown: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: HoldClock

    var body: some View {
        if model.workSessionHolding, model.automaticWorkReasonActive,
           model.workProtectionReason == nil, model.problem == nil,
           let until = model.batteryHoldUntil {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    Spacer(minLength: 4)
                    remaining(until: until)
                }
                VStack(alignment: .leading, spacing: 4) {
                    title
                    remaining(until: until)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Automatic session remaining", "자동 유지 남은 시간"))
            .accessibilityValue(Texts.countdown(max(0, until.timeIntervalSince(clock.now))))
            .accessibilityIdentifier("panel-automatic-countdown")
        }
    }

    private var title: some View {
        Text(L("Automatic remaining", "자동 유지 남은 시간"))
            .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
    }

    private func remaining(until: Date) -> some View {
        Text(Texts.countdown(max(0, until.timeIntervalSince(clock.now))))
            .font(TetherTypography.countdown).monospacedDigit()
            .foregroundStyle(Color.tetherAccent)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MenuPanelChromeHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

/// Short content keeps its natural height. Long content scrolls between persistent actions.
struct MenuPanelBody<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content().fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) { content().fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxHeight: maximumHeight)
    }
}

/// Reads the panel's screen and clears only its initial automatic keyboard focus.
/// No display or power settings are changed here.
private struct MenuPanelScreenBridge: NSViewRepresentable {
    @Binding var heightLimit: CGFloat
    func makeNSView(context: Context) -> ScreenReader { ScreenReader(heightLimit: $heightLimit) }
    func updateNSView(_ view: ScreenReader, context: Context) { view.heightLimit = $heightLimit }

    final class ScreenReader: NSView {
        var heightLimit: Binding<CGFloat>
        private var observers: [NSObjectProtocol] = []
        private weak var initialFocusWindow: NSWindow?
        init(heightLimit: Binding<CGFloat>) { self.heightLimit = heightLimit; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            for (name, object) in [(NSWindow.didChangeScreenNotification, window as AnyObject?),
                                   (NSApplication.didChangeScreenParametersNotification, nil)] {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.readScreen() }
                })
            }
            readScreen()
            if initialFocusWindow !== window {
                initialFocusWindow = window
                if NSApp.currentEvent?.type != .keyDown {
                    DispatchQueue.main.async { [weak window] in
                        if NSApp.currentEvent?.type != .keyDown { window?.makeFirstResponder(nil) }
                    }
                }
            }
        }

        private func readScreen() {
            guard let screen = window?.screen else { return }
            let limit = WorkSessionMetrics.panelHeightLimit(visibleHeight: screen.visibleFrame.height)
            guard heightLimit.wrappedValue != limit else { return }
            // Attaching a view may happen during SwiftUI layout; publish after that pass.
            DispatchQueue.main.async { [weak self] in self?.heightLimit.wrappedValue = limit }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
