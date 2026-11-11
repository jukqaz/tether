import SwiftUI
import TetherCore

/// A timer owns its deadline. Presets are available only before an explicit start.
struct ManualSessionControls: View {
    enum Presentation { case combined, current, start }
    @ObservedObject var model: AppModel
    @ObservedObject var clock: HoldClock
    var compact = false
    var showBatteryScopeHint = true
    var nextSessionExpansion: Binding<Bool>? = nil
    var presentation: Presentation = .combined
    var prominentStart = true
    var showsSessionLabel = true
    var showsOtherTimeAction = true
    @State private var showOtherTime = false
    @State private var extensionReasonExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.manualSessionActive, presentation != .start {
                if compact {
                    VStack(alignment: .leading, spacing: 6) {
                        if showsTimedExtension {
                            Text(model.automaticWorkReasonActive
                                ? L("Manual time remaining", "수동 유지 남은 시간")
                                : L("Time remaining", "남은 시간"))
                                .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .center, spacing: 12) {
                                countdown.fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 0)
                                currentActions.fixedSize(horizontal: true, vertical: false)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                countdown
                                currentActions
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        countdown
                        currentActions
                    }
                }

                if showsTimedExtension, let reason = model.manualExtensionUnavailableReason(by: 30) {
                    DisclosureGroup(L("Extension unavailable", "지금은 연장할 수 없음"), isExpanded: $extensionReasonExpanded) {
                        Text(reason).fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2).padding(.top, 4)
                    }
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    .help(reason)
                    .accessibilityIdentifier("panel-extend-manual-reason-30")
                }
                if model.automaticWorkReasonActive || model.automaticPauseActive {
                    Text(model.automaticWorkReasonActive
                        ? L("Automatic keep-awake continues.", "자동 유지는 계속됩니다.")
                        : model.manualEndingDetail).font(TetherTypography.secondary)
                        .foregroundStyle(Color.tetherSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                        .help(model.manualEndingDetail)
                }
            } else if !model.manualSessionActive, presentation != .current {
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            ManualDurationPicker(model: model).frame(minWidth: 128)
                            startButton.fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            ManualDurationPicker(model: model)
                            startButton
                        }
                    }
                    if showsOtherTimeAction {
                        Button(L("Other duration or end time…", "다른 시간·종료 시각…")) { showOtherTime = true }
                            .font(TetherTypography.secondary)
                            .buttonStyle(.link).disabled(!model.canStartManualSession)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("panel-other-manual-time")
                    }
                }
                if !model.canStartManualSession && model.problem == nil {
                    Note(model.manualStartBlockedDetail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showOtherTime) { ManualStartOptionsView(model: model) }
    }

    private var countdown: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsSessionLabel && !compact {
                Text(L("Manual keep-awake", "수동 유지"))
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
            }
            Text(remainingDescription)
                .font(TetherTypography.countdown).monospacedDigit()
                .foregroundStyle(Color.tetherPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !compact, let until = model.manualSessionUntil {
                Text(L("Ends at \(Texts.time(until))", "\(Texts.time(until)) 종료"))
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Manual keep-awake remaining", "수동 유지 남은 시간"))
        .accessibilityValue(remainingDescription)
        .accessibilityIdentifier("panel-manual-countdown")
    }

    private var currentActions: some View {
        HStack(spacing: 8) {
            CompactPushButton(endButtonTitle, identifier: "panel-end-manual") {
                model.endManualSession()
            }
            .accessibilityLabel(L("End manual keep-awake", "수동 유지 종료"))
            if showsTimedExtension { extensionButton(30) }
        }
        .accessibilityHint(model.manualEndingDetail)
        .disabled(model.commandPending)
    }

    private var startButton: some View {
        CompactPushButton(compact ? L("Start manual", "수동 유지 시작") : L("Start", "시작"),
                          prominent: prominentStart, identifier: "panel-start-manual") {
            if model.selectedManualMinutes == 0 { model.startUntimedSession() }
            else { model.startManualSession(minutes: model.selectedManualMinutes) }
        }
        .accessibilityLabel(L("Start manually", "직접 시작"))
        .accessibilityIdentifier("panel-start-manual")
        .accessibilityHint(L("Choosing a duration alone does not start work", "시간 선택만으로 시작되지 않습니다"))
        .disabled(!model.canStartManualSession)
    }

    var hasConfirmedUnlimitedDuration: Bool {
        model.hasConfirmedUntimedManualSession
    }

    var remainingDescription: String {
        guard let remaining = model.manualRemaining(at: clock.now) else {
            return hasConfirmedUnlimitedDuration ? L("Until ended", "종료할 때까지") : L("Checking end time", "종료 시간 확인 중")
        }
        return Texts.countdown(remaining)
    }

    var showsTimedExtension: Bool {
        model.manualSessionActive && model.manualSessionUntil != nil
    }

    var endButtonTitle: String {
        compact ? L("End manual", "수동 종료") : L("End manual", "수동 유지 종료")
    }

    func extensionButtonTitle(_ minutes: Int) -> String {
        compact ? L("+\(minutes) min", "+\(minutes)분") : L("Add \(minutes) min", "+\(minutes)분")
    }

    private func extensionButton(_ minutes: Int) -> some View {
        let reason = model.manualExtensionUnavailableReason(by: minutes)
        let hint = reason ?? L("Adds \(minutes) minutes to the current end time without restarting manual keep-awake.",
                               "수동 유지를 다시 시작하지 않고 현재 종료 시각에 \(minutes)분을 더합니다.")
        return CompactPushButton(extensionButtonTitle(minutes), prominent: compact,
                                 identifier: "panel-extend-manual-\(minutes)") {
            model.extendManualSession(by: minutes)
        }
        .disabled(reason != nil)
        .help(hint)
        .accessibilityLabel(L("Extend manual work by \(minutes) minutes", "수동 유지 \(minutes)분 연장"))
        .accessibilityHint(hint)
    }

}

struct ManualDurationPicker: View {
    @ObservedObject var model: AppModel
    /// Keep a previously saved choice visible without advertising six redundant presets.
    /// Zero belongs to the same list as every finite tag so the current selection
    /// remains representable when battery work explicitly allows unlimited time.
    var durationChoices: [Int] {
        let finite = model.manualDurationChoices.filter {
            [30, 60, 120].contains($0) || $0 == model.selectedManualMinutes
        }
        let permitsUnlimited = model.snapshot.power == .ac
            || (model.snapshot.power == .battery && model.v3Settings.batteryTimeLimit == .unlimited)
        // Unknown power cannot accept a new choice, but a saved unlimited
        // selection still needs its own tag while the disabled picker waits.
        return finite + (permitsUnlimited || model.selectedManualMinutes == 0 ? [0] : [])
    }
    var controlsDisabled: Bool {
        !model.acceptingUserCommands || model.commandPending || model.manualSessionActive
            || model.snapshot.power == .unknown
    }
    var durationSelection: Binding<Int> {
        Binding(get: { model.selectedManualMinutes }, set: { minutes in
            // Recheck after an open menu's power state changes; a stale unlimited
            // item must not save an unavailable battery choice.
            guard !controlsDisabled, durationChoices.contains(minutes) else { return }
            model.selectManualDuration(minutes == 0 ? nil : Double(minutes) * 60)
        })
    }
    var body: some View {
        CompactPopUp(title: L("Manual duration", "수동 유지 시간"), selection: durationSelection,
                     choices: durationChoices.map { minutes in
                         PopupChoice(minutes, minutes == 0
                             ? L("Until ended", "종료할 때까지") : model.durationChoiceTitle(minutes))
                     }, identifier: "manual-duration-picker")
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHint(L("Use Start to begin", "직접 시작을 눌러야 유지가 시작됩니다"))
            .disabled(controlsDisabled)
    }
}
