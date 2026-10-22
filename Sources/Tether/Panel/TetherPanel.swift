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
    // Both ViewThatFits candidates must observe the same disclosure state.
    @State private var manualDetailsExpanded = false
    @State private var problemDetailsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, WorkSessionMetrics.panelInset)
                .padding(.top, 12).padding(.bottom, 10)
                .background { chromeMeasurement }
            Divider()
            // Reserve the measured chrome, including wrapped footer text.
            MenuPanelBody(maximumHeight: max(1, (maximumHeight ?? screenHeightLimit) - chromeHeight)) {
                panelContent.padding(.horizontal, WorkSessionMetrics.panelInset).padding(.vertical, 8)
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
            if !active { manualDetailsExpanded = false }
        }
        .onChange(of: model.problem?.message) { _, _ in problemDetailsExpanded = false }
        .background { if maximumHeight == nil { MenuPanelScreenBridge(heightLimit: $screenHeightLimit) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Tether").font(TetherTypography.body.weight(.medium)).accessibilityAddTraits(.isHeader)
                if model.userCommandsArePreview { PreviewIndicator() }
                Spacer(minLength: 6)
                Label(powerLabel, systemImage: model.snapshot.power == .battery ? "battery.75percent" : "powerplug")
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                WorkSessionStatus(model: model, clock: model.clock, compact: true)
                if model.showsLidOptions {
                    Text(closedLidPolicySummary)
                        .font(TetherTypography.body).foregroundStyle(Color.tetherSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 15)
                        .help(closedLidDisconnectDetail)
                        .accessibilityLabel(closedLidDisconnectDetail)
                        .accessibilityIdentifier("panel-closed-lid-policy")
                }
            }
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
            } else if model.showsLidOptions && model.v3Settings.allowClosedLid && !model.lidSupportConfirmed {
                attention(title: L("Closed-lid setup needs review", "덮개 유지 준비 확인 필요"),
                    detail: L("Review required MacBook helper setup.", "MacBook 필수 도우미 준비를 확인하세요."),
                    color: .tetherWarning, destination: .system)
            }
            if model.workProtectionReason != nil {
                Button(L("Resume automatic rules", "자동 조건 재개")) { model.setEnabled(true) }
                    .actionButton().frame(minHeight: 28)
                    .disabled(!model.canResumeWork || model.commandPending)
            } else if model.workPaused {
                WorkSessionStopButton(model: model, fullWidth: true, compact: true).frame(minHeight: 28)
            }
            ManualSessionControls(model: model, clock: model.clock, compact: true,
                showBatteryScopeHint: false, nextSessionExpansion: $manualDetailsExpanded)
            if !model.workPaused && model.workProtectionReason == nil,
               model.automaticEnabled || model.manualSessionActive || model.workSessionHolding {
                WorkSessionStopButton(model: model, fullWidth: true, compact: true)
                    .frame(minHeight: 28)
            }
            Divider()
            automaticControls
        }
    }

    private var automaticControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("AC automatic", "AC 자동"))
                Spacer(minLength: 8)
                Toggle(L("AC automatic", "AC 자동"), isOn: Binding(
                    get: { model.v3Settings.automaticEnabled }, set: { model.setAutomaticEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch).tint(.tetherAction)
                    .controlSize(.small)
                    .accessibilityLabel(L("AC automatic", "AC 자동"))
                    .accessibilityIdentifier("panel-automatic")
                    .accessibilityHint(L("Only applies on AC. Turning this off ends automatic work only.", "AC에서만 적용합니다. 끄면 자동 유지만 종료합니다."))
                    .disabled(!model.acceptingUserCommands || model.commandPending)
            }
            if model.automaticEnabled && model.snapshot.power != .ac {
                Text(L("Waiting for AC", "AC 연결 대기")).font(TetherTypography.secondary)
                    .foregroundStyle(Color.tetherSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var closedLidPolicySummary: String {
        let lid = model.v3Settings.allowClosedLid
            ? L("Closed-lid work allowed", "덮개 유지 허용") : L("Closed lid follows macOS", "덮개 닫힘은 macOS에 맡김")
        return lid + " · " + L("Unplug ends all work", "분리 시 모두 종료")
    }

    private var closedLidDisconnectSummary: String {
        model.v3Settings.allowClosedLid && model.v3Settings.disconnectAction == .sleepIfClosed
            ? L("Closed-lid unplug: request sleep", "닫힌 채 분리: 잠자기 요청")
            : L("Closed-lid unplug: follow macOS", "닫힌 채 분리: macOS에 맡김")
    }

    private var closedLidDisconnectDetail: String {
        closedLidDisconnectSummary + ". " + L("Tether ends its requests first. Actual sleep is not guaranteed.",
            "Tether의 요청을 먼저 종료합니다. 실제 Sleep을 보장하지 않습니다.")
    }

    /// Keep the review action aligned with the warning it explains.
    private func attention(title: String, detail: String, color: Color, destination: SettingsPage,
                           actionTitle: String = L("View in settings…", "설정에서 확인…")) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(title, isExpanded: $problemDetailsExpanded) {
                Text(detail).font(.callout).foregroundStyle(Color.tetherSecondary)
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
            Spacer(minLength: 6)
            Button(L("Settings…", "설정…"), action: showSettings)
                .font(TetherTypography.secondary)
                .buttonStyle(.borderless).controlSize(.small).foregroundStyle(Color.tetherPrimary)
                .accessibilityLabel(L("Settings", "설정"))
                .accessibilityIdentifier("panel-open-settings")
                .keyboardShortcut(",", modifiers: .command)
            moreActions
        }
    }

    private var powerLabel: String {
        switch model.snapshot.power {
        case .ac: return L("On power", "전원 연결")
        case .battery: return L("Battery \(model.percentText)", "배터리 \(model.percentText)")
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
            Text(L("Automatic: AC only", "자동: AC에서만"))
            if model.manualSessionActive {
                Menu(L("Next manual duration", "다음 수동 유지 시간")) {
                    ManualDurationPicker(model: model)
                    Text(L("Applies to the next start", "다음 시작에 적용"))
                }.accessibilityIdentifier("panel-next-manual-duration")
            }
            if model.showsLidOptions {
                Text(L("Closed lid · \(model.lidSupportSummary)", "덮개 유지 · \(model.lidSupportSummary)"))
                Text(closedLidDisconnectSummary)
                    .help(closedLidDisconnectDetail)
                    .accessibilityLabel(closedLidDisconnectDetail)
                    .accessibilityIdentifier("panel-disconnect-summary")
            }
            Divider()
            Button(L("Sleep…", "잠자기…")) { model.sleepNow() }
                .disabled(!model.sessionAvailable || model.commandPending)
                .accessibilityHint(L("Release Tether's own keep-awake requests, then request sleep", "Tether의 자체 유지 요청을 해제한 뒤 잠자기를 요청합니다"))
            Divider()
            Button(L("Quit Tether", "Tether 종료")) { NSApplication.shared.terminate(nil) }
        } label: { Text(L("Other…", "기타…")) }
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
