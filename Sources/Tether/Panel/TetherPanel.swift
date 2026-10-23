import SwiftUI
import TetherCore

/// The shipping menu panel observes the same session controller as Settings.
struct TetherPanel: View {
    @ObservedObject var model: AppModel
    /// Overrides only the viewport in layout tests; live panels follow their own screen.
    var maximumHeight: CGFloat? = nil
    var previewSettingsAction: (() -> Void)? = nil
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var screenHeightLimit = WorkSessionMetrics.panelMaximumHeight
    @State private var chromeHeight: CGFloat = 104
    // Both ViewThatFits candidates share disclosure state when the body starts scrolling.
    @State private var workDetailsExpanded = false
    @State private var problemDetailsExpanded = false

    init(model: AppModel, maximumHeight: CGFloat? = nil, previewSettingsAction: (() -> Void)? = nil,
         expandedDetails: Bool = false) {
        self.model = model
        self.maximumHeight = maximumHeight
        self.previewSettingsAction = previewSettingsAction
        _workDetailsExpanded = State(initialValue: expandedDetails)
        _problemDetailsExpanded = State(initialValue: expandedDetails)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, WorkSessionMetrics.panelInset)
                .padding(.vertical, 12)
                .background { chromeMeasurement }
            Divider()
            // Reserve the measured chrome, including wrapped footer text.
            MenuPanelBody(maximumHeight: max(1, (maximumHeight ?? screenHeightLimit) - chromeHeight)) {
                panelContent.padding(.horizontal, WorkSessionMetrics.panelInset).padding(.top, 6).padding(.bottom, 12)
            }
            Divider()
            footer.padding(.horizontal, WorkSessionMetrics.panelInset).padding(.vertical, 8)
                .background { chromeMeasurement }
        }
        .frame(width: WorkSessionMetrics.panelWidth)
        // Constrain the stack as well as its measured body budget. Native controls
        // can round their intrinsic height between passes; the body must absorb it.
        .frame(maxHeight: maximumHeight ?? screenHeightLimit)
        .font(TetherTypography.body)
        .foregroundStyle(Color.tetherPrimary)
        .tint(.tetherAccent)
        // A single menu surface; native controls do not add nested custom glass.
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
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            StateIcon(icon: model.presentation.icon, size: 17)
                .foregroundStyle(model.presentation.color)
                .frame(width: 24, height: 24).padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle).font(TetherTypography.status)
                    .fixedSize(horizontal: false, vertical: true)
                Text([statusDetail, powerLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.v4ACDrainWarning {
                Text(L("Battery charge continues to decrease while connected to power.",
                       "전원 연결 중 배터리 잔량이 계속 줄고 있습니다."))
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("panel-ac-battery-decrease-note")
            }
            if let problem = model.problem {
                attention(title: problem.title, detail: problem.message, color: problem.color,
                    destination: .system, actionTitle: problem.reviewLabel)
            } else if needsLidReview {
                attention(title: model.helperSetupConfirmed
                    ? L("Closed-lid request needs review", "덮개 기능 적용 확인 필요")
                    : L("Closed-lid setup needs review", "덮개 기능 준비 필요"),
                    detail: model.helperSetupConfirmed
                        ? L("Review the current helper response and closed-lid request.", "현재 도우미 응답과 덮개 유지 요청 상태를 확인하세요.")
                        : L("Review required MacBook helper setup.", "MacBook 필수 도우미 준비를 확인하세요."),
                    color: .tetherWarning, destination: .system)
            }
            if model.userSessionStatus?.ownReleasePending == true {
                attention(title: L("Confirming release", "잠자기 방지 해제 확인 중"),
                    detail: model.presentation.subtitle, color: .tetherWarning, destination: .system)
            } else if model.lidReleasePending {
                attention(title: L("Closed-lid release needs confirmation", "덮개 설정 되돌리기 확인 필요"),
                    detail: L("General work and closed-lid recovery have separate results.",
                              "일반 잠자기 방지와 덮개 설정 복구 결과는 별도로 확인합니다."),
                    color: .tetherWarning, destination: .system)
            }
            if showsDisplayRecoveryWarning { displayRecoveryAttention }
            if actionVisibility.showsCurrentWork {
                currentWork
                Divider()
            }
            if actionVisibility.showsNewManual {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle(L("Start a timer", "직접 시작"))
                    ManualSessionControls(model: model, clock: model.clock, compact: true,
                        showBatteryScopeHint: false, presentation: .start,
                        prominentStart: !model.workSessionHolding)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("panel-new-manual-section")
                Divider()
            }
            if actionVisibility.showsStartBlockedReason {
                Note(model.manualStartBlockedDetail)
            }
            if actionVisibility.showsAutomaticToggle || actionVisibility.showsQuickOptions {
                VStack(alignment: .leading, spacing: 6) {
                    if actionVisibility.showsAutomaticToggle { automaticControls }
                    if actionVisibility.showsQuickOptions {
                        MenuKeepAwakeControls(model: model, openHelperSetup: { showSettings(page: .system) })
                    }
                }
            }
            if actionVisibility.showsWorkDetails { workDetails }
            if let summary = model.otherAppKeepAwakeSummary {
                Button(summary) { model.showOtherAppKeepAwakeDetails() }
                    .buttonStyle(.link).font(TetherTypography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("panel-other-app-requests")
            }
        }
    }

    var actionVisibility: MenuActionVisibility { MenuActionVisibility(model: model) }
    var showsCurrentWork: Bool { actionVisibility.showsCurrentWork }

    var showsDisplayRecoveryWarning: Bool { model.closedLidDisplayRecoveryPending }
    var canRetryDisplayRecovery: Bool { model.hasCoordinatorAuthority && !model.commandPending }

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
        model.showsLidOptions && model.v3Settings.allowClosedLid
            && (!model.helperSetupConfirmed || (model.workSessionHolding && !model.lidSupportConfirmed))
    }

    private var currentWork: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("Current work", "현재 작업"))
            if model.automaticWorkReasonActive {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(L("Automatic keep-awake", "자동 잠자기 방지")).font(TetherTypography.body.weight(.medium))
                        Spacer(minLength: 4)
                        Text(model.v4RuleSummary).font(TetherTypography.secondary)
                            .foregroundStyle(Color.tetherSecondary).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Automatic keep-awake", "자동 잠자기 방지")).font(TetherTypography.body.weight(.medium))
                        Text(model.v4RuleSummary).font(TetherTypography.secondary)
                            .foregroundStyle(Color.tetherSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                AutomaticSessionCountdown(model: model, clock: model.clock)
            }
            if model.manualSessionActive {
                if model.automaticWorkReasonActive { Divider() }
                ManualSessionControls(model: model, clock: model.clock, compact: true,
                    showBatteryScopeHint: false, presentation: .current)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel-current-work-section")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(TetherTypography.secondary.weight(.medium))
            .foregroundStyle(Color.tetherSecondary).accessibilityAddTraits(.isHeader)
    }

    private var automaticControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Automatic start", "자동 시작"))
                Spacer(minLength: 8)
                Toggle(L("Allow automatic starts", "자동 시작 허용"), isOn: Binding(
                    get: { model.v3Settings.automaticEnabled }, set: { model.setAutomaticEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch).tint(.tetherAction)
                    .controlSize(.small)
                    .accessibilityLabel(L("Allow automatic starts", "자동 시작 허용"))
                    .accessibilityIdentifier("panel-automatic")
                    .accessibilityHint(model.v3Settings.condition.title + ". " + L("Turning this off ends automatic work only.", "끄면 자동 유지만 종료합니다."))
                    .disabled(!model.acceptingUserCommands || model.commandPending)
            }
            if actionVisibility.showsAutomaticRest {
                AutomaticPauseControls(model: model, compact: true)
            }
            if let waitingDetail = automaticStartWaitingDetail {
                Text(waitingDetail).font(TetherTypography.secondary)
                    .foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("panel-automatic-waiting")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var automaticStartWaitingDetail: String? {
        guard model.automaticEnabled, !model.workPaused, !model.automaticPauseActive, !model.automaticWorkReasonActive,
              model.problem == nil else { return nil }
        if model.snapshot.power == .unknown {
            return L("Checking power before evaluating automatic starts", "전원 상태를 확인한 뒤 자동 시작 조건을 확인합니다")
        }
        let condition = model.v3Settings.condition
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
        if model.workProtectionReason != nil || model.workPaused
            || model.userSessionStatus?.ownReleasePending == true
            || model.userSessionStatus?.observationLimited == true
            || model.userSessionStatus?.error != nil {
            return model.presentation.title
        }
        if model.manualSessionActive && model.automaticWorkReasonActive {
            return L("Automatic + timer active", "자동 + 타이머 실행 중")
        }
        if model.manualSessionActive { return L("Timer active", "타이머 실행 중") }
        if model.automaticWorkReasonActive { return L("Automatic keep-awake active", "자동 잠자기 방지 중") }
        if model.automaticPauseActive { return L("Automatic starts resting", "자동만 쉬는 중") }
        if model.automaticEnabled { return L("Waiting to start automatically", "자동 시작 대기 중") }
        return L("Keep-awake off", "잠자기 방지 꺼짐")
    }

    private var statusDetail: String? {
        if model.problem != nil { return nil }
        if model.workProtectionReason != nil { return model.presentation.subtitle }
        if model.userSessionStatus?.observationLimited == true {
            return L("New starts and extensions are unavailable", "새 시작과 시간 추가를 기다려 주세요")
        }
        if model.workPaused { return model.presentation.subtitle }
        return nil
    }

    private var powerScopeDetail: String {
        switch model.snapshot.power {
        case .ac:
            return disconnectPolicySummary
        case .battery:
            return L("Battery work ends at its time or protection limit", "배터리 유지 시간이나 보호 한도에 도달하면 끝남")
        case .unknown:
            return L("Checking power before applying work", "전원 상태를 확인한 뒤 유지 여부를 적용합니다")
        }
    }

    var disconnectPolicySummary: String {
        switch model.v3Settings.disconnectPolicy {
        case .endAll: return L("Unplug: end all sessions", "전원 분리 시 모두 종료")
        case .endAutomatic: return L("Unplug: end automatic sessions", "전원 분리 시 자동 유지 종료")
        case .continueEligible: return L("Unplug: continue eligible sessions", "전원 분리 시 허용된 유지 계속")
        }
    }

    private var workDetails: some View {
        DisclosureGroup(isExpanded: $workDetailsExpanded) {
            VStack(spacing: 0) {
                workRow(title: L("Automatic power", "자동 시작 전원"),
                        detail: model.v3Settings.condition.title, badge: "")
                if model.showsLidOptions {
                    Divider()
                    workRow(title: closedLidPolicySummary, detail: closedLidDisconnectDetail, badge: "")
                }
            }
            .padding(.top, 5)
        } label: {
            HStack(spacing: 8) {
                Text(model.showsLidOptions || model.capabilities.internalBattery == true
                     ? powerScopeDetail : L("Details", "상세"))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(model.disconnectPolicyDetail)
                    .accessibilityIdentifier("panel-closed-lid-policy")
            }
            .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
        }
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
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var closedLidPolicySummary: String {
        let lid = model.v3Settings.allowClosedLid
            ? L("Closed-lid work allowed", "덮개를 닫아도 계속 사용") : L("Closed lid follows macOS", "덮개 닫힘은 macOS에 맡김")
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
                           actionTitle: String = L("View in settings…", "설정에서 확인…")) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(title, isExpanded: $problemDetailsExpanded) {
                Text(detail).font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(color)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("panel-problem-details")
            Button(actionTitle) { showSettings(page: destination) }
                .buttonStyle(.link)
                .accessibilityIdentifier("panel-review-settings")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if actionVisibility.showsStopAll || actionVisibility.showsResume { stopAllControl }
            Spacer(minLength: 6)
            if model.userCommandsArePreview { PreviewIndicator() }
            Button(L("Settings…", "설정…"), action: showSettings)
                .font(TetherTypography.secondary)
                .buttonStyle(.borderless).controlSize(.small).foregroundStyle(Color.tetherPrimary)
                .accessibilityLabel(L("Settings", "설정"))
                .accessibilityIdentifier("panel-open-settings")
                .keyboardShortcut(",", modifiers: .command)
            moreActions
        }
    }

    private var stopAllControl: some View {
        Button(model.workPaused ? L("Resume", "다시 허용") : L("Stop all", "모두 중지")) {
            model.setEnabled(model.workPaused)
        }
        .font(TetherTypography.body)
        .actionButton(prominent: model.workPaused).controlSize(.small)
        .accessibilityIdentifier("panel-pause-all")
        .accessibilityHint(model.workPaused
            ? model.automaticPauseActive
                ? L("Allow work again. Automatic-only rest still applies; ended timers do not restart.", "유지를 다시 허용합니다. 자동만 쉬는 기한은 유지하며 끝난 타이머는 복원하지 않습니다.")
                : L("Enabled automatic conditions may resume. Ended timers do not restart.", "켜 둔 자동 조건은 다시 적용하지만 끝난 타이머는 다시 시작하지 않습니다.")
            : L("End manual timers and pause automatic starts until you resume.", "타이머를 끝내고 다시 허용할 때까지 자동 시작도 멈춥니다."))
        .disabled(!model.sessionAvailable || model.commandPending || (model.workPaused && !model.canResumeWork))
    }

    private var powerLabel: String {
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
        Menu {
            if model.showsLidOptions {
                Text(L("Closed lid · \(model.lidSupportSummary)", "덮개 유지 · \(model.lidSupportSummary)"))
                Divider()
            }
            Button(L("Sleep…", "잠자기…")) { model.sleepNow() }
                .disabled(!model.sessionAvailable || model.commandPending)
                .accessibilityHint(L("Release Tether's own keep-awake requests, then request sleep", "Tether의 자체 유지 요청을 해제한 뒤 잠자기를 요청합니다"))
            Divider()
            Button(L("Quit Tether", "Tether 종료")) { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis").frame(width: 18, height: 18)
        }
        .menuStyle(.button).menuIndicator(.hidden).fixedSize()
        .buttonStyle(.borderless).controlSize(.small)
        .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
        .accessibilityLabel(L("More actions", "다른 동작"))
        .accessibilityIdentifier("panel-more-actions")
    }

    private func showSettings() {
        showSettings(page: model.settingsPage)
    }

    private func showSettings(page: SettingsPage) {
        model.settingsPage = page
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
