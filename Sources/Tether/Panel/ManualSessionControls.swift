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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    Button(L("End timer", "타이머 끝내기")) { model.endManualSession() }
                        .actionButton().controlSize(.small)
                        .accessibilityIdentifier("panel-end-manual")
                        .accessibilityHint(model.manualEndingDetail)
                        .disabled(model.commandPending)
                }
                if model.manualSessionUntil != nil {
                    extensionButton(30)
                }
                Text(model.manualEndingDetail).font(TetherTypography.secondary)
                    .foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.manualSessionActive, presentation != .current {
                HStack(spacing: 8) {
                    ManualDurationPicker(model: model)
                    Button(L("Start", "직접 시작")) {
                        if model.selectedManualMinutes == 0 { model.startUntimedSession() }
                        else { model.startManualSession(minutes: model.selectedManualMinutes) }
                    }.actionButton(prominent: prominentStart)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                        .accessibilityLabel(L("Start manual session", "타이머 직접 시작"))
                        .accessibilityIdentifier("panel-start-manual")
                        .accessibilityHint(L("Choosing a duration alone does not start work", "시간 선택만으로 시작되지 않습니다"))
                        .disabled(!model.canStartManualSession)
                }
                if !model.canStartManualSession && model.problem == nil {
                    Note(model.manualStartBlockedDetail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func extensionButton(_ minutes: Int) -> some View {
        Button { model.extendManualSession(by: minutes) } label: {
            Text(L("Add \(minutes) min", "\(minutes)분 추가"))
                .frame(maxWidth: .infinity)
        }
            .actionButton().controlSize(.small)
            .disabled(!model.canExtendManual(by: minutes) || model.commandPending)
            .accessibilityLabel(L("Extend manual work by \(minutes) minutes", "수동 유지 \(minutes)분 연장"))
            .accessibilityIdentifier("panel-extend-manual-\(minutes)")
    }
}

struct ManualDurationPicker: View {
    @ObservedObject var model: AppModel
    /// Keep a previously saved choice visible without advertising six redundant presets.
    private var durationChoices: [Int] {
        model.manualDurationChoices.filter { [30, 60, 120].contains($0) || $0 == model.selectedManualMinutes }
    }
    var body: some View {
        Picker(L("Next manual duration", "직접 시작 시간"), selection: Binding(
            get: { model.selectedManualMinutes }, set: { minutes in
                model.selectManualDuration(minutes == 0 ? nil : Double(minutes) * 60)
            })) {
            ForEach(durationChoices, id: \.self) { minutes in
                Text(model.durationChoiceTitle(minutes)).tag(minutes)
            }
            if model.snapshot.power == .ac { Text(L("Until turned off", "끄기 전까지")).tag(0) }
        }.labelsHidden().pickerStyle(.menu).controlSize(.small)
            .buttonSizing(.flexible)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.tetherPrimary)
            .accessibilityIdentifier("manual-duration-picker")
            .accessibilityHint(L("Use Start to begin", "직접 시작을 눌러야 유지가 시작됩니다"))
            .disabled(!model.acceptingUserCommands || model.commandPending || model.manualSessionActive)
    }
}
