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
    @State private var showOtherTime = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.manualSessionActive, presentation != .start {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.manualSessionUntil == nil
                             ? L("Manual session", "직접 시작한 타이머") : L("Time remaining", "남은 시간"))
                            .font(TetherTypography.secondary)
                            .foregroundStyle(Color.tetherSecondary)
                        Text(remainingDescription)
                            .font(TetherTypography.countdown).monospacedDigit()
                            .foregroundStyle(Color.tetherPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let until = model.manualSessionUntil {
                            Text(L("Ends at \(Texts.time(until))", "\(Texts.time(until))에 끝나요"))
                                .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                        } else if hasConfirmedUnlimitedDuration {
                            Text(L("Until you end it", "직접 끝낼 때까지"))
                                .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Manual session remaining", "타이머 남은 시간"))
                    .accessibilityValue(remainingDescription)
                    .accessibilityIdentifier("panel-manual-countdown")
                    Spacer(minLength: 2)
                    VStack(alignment: .trailing, spacing: 5) {
                        CompactPushButton(L("End timer", "타이머 끝내기"), identifier: "panel-end-manual") { model.endManualSession() }
                        if showsTimedExtension { extensionButton(30) }
                    }
                        .accessibilityHint(model.manualEndingDetail)
                        .disabled(model.commandPending)
                }

                if showsTimedExtension, let reason = model.manualExtensionUnavailableReason(by: 30) {
                    Text(reason).font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("panel-extend-manual-reason-30")
                }
                Text(model.manualEndingDetail).font(TetherTypography.secondary)
                    .foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.manualSessionActive, presentation != .current {
                // Keep the optional time editor attached to its duration row,
                // rather than spending another full section gap in the menu.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        ManualDurationPicker(model: model)
                        CompactPushButton(L("Start", "시작"), prominent: prominentStart, identifier: "panel-start-manual") {
                            if model.selectedManualMinutes == 0 { model.startUntimedSession() }
                            else { model.startManualSession(minutes: model.selectedManualMinutes) }
                        }
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                            .accessibilityLabel(L("Start manual session", "타이머 직접 시작"))
                            .accessibilityIdentifier("panel-start-manual")
                            .accessibilityHint(L("Choosing a duration alone does not start work", "시간 선택만으로 시작되지 않습니다"))
                            .disabled(!model.canStartManualSession)
                    }
                    Button(L("Other duration or end time…", "다른 시간·끝날 시각…")) { showOtherTime = true }
                        .font(TetherTypography.secondary)
                        .buttonStyle(.link).disabled(!model.canStartManualSession)
                        .accessibilityIdentifier("panel-other-manual-time")
                }
                if !model.canStartManualSession && model.problem == nil {
                    Note(model.manualStartBlockedDetail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showOtherTime) { ManualStartOptionsView(model: model) }
    }

    var hasConfirmedUnlimitedDuration: Bool {
        guard model.manualSessionActive, model.manualSessionUntil == nil else { return false }
        if model.snapshot.power == .ac { return true }
        guard model.snapshot.power == .battery, let request = model.userSession?.v4ManualSnapshot else { return false }
        return request.confirmed && request.batteryTimeLimit == .unlimited
    }

    var remainingDescription: String {
        guard let remaining = model.manualRemaining(at: clock.now) else {
            return hasConfirmedUnlimitedDuration ? L("Until turned off", "끄기 전까지") : L("Checking deadline", "마감 확인 중")
        }
        return Texts.countdown(remaining)
    }

    var showsTimedExtension: Bool {
        model.manualSessionActive && model.manualSessionUntil != nil
    }

    private func extensionButton(_ minutes: Int) -> some View {
        let reason = model.manualExtensionUnavailableReason(by: minutes)
        let hint = reason ?? L("Adds \(minutes) minutes to this timer without restarting it.",
                               "현재 타이머를 다시 시작하지 않고 \(minutes)분을 더합니다.")
        return CompactPushButton(L("Add \(minutes) min", "+\(minutes)분"), identifier: "panel-extend-manual-\(minutes)") {
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
        CompactPopUp(title: L("Next manual duration", "직접 시작 시간"), selection: durationSelection,
                     choices: durationChoices.map { minutes in
                         PopupChoice(minutes, minutes == 0
                             ? L("Until turned off", "끄기 전까지") : model.durationChoiceTitle(minutes))
                     }, identifier: "manual-duration-picker")
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHint(L("Use Start to begin", "직접 시작을 눌러야 유지가 시작됩니다"))
            .disabled(controlsDisabled)
    }
}
