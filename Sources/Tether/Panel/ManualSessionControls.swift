import SwiftUI
import TetherCore

/// The picker saves the next duration. Starting and extending are explicit commands.
struct ManualSessionControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: HoldClock
    var compact = false
    var showBatteryScopeHint = true
    var nextSessionExpansion: Binding<Bool>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.manualSessionActive {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Manual session", "수동 유지")).font(TetherTypography.secondary)
                            .foregroundStyle(Color.tetherSecondary)
                        Text(remainingDescription)
                            .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Color.tetherPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(L("Manual session remaining", "수동 유지 남은 시간"))
                            .accessibilityValue(remainingDescription)
                            .accessibilityIdentifier("panel-manual-countdown")
                        if let until = model.manualSessionUntil {
                            Text(L("Ends \(Texts.time(until))", "\(Texts.time(until)) 종료"))
                                .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                        }
                    }
                    Spacer(minLength: 2)
                    Button(L("End manual only", "수동만 종료")) { model.endManualSession() }
                        .actionButton().controlSize(.small)
                        .accessibilityIdentifier("panel-end-manual")
                        .accessibilityHint(L("Enabled AC automatic rules continue", "켜 둔 AC 자동 조건은 계속 적용됩니다"))
                        .disabled(model.commandPending)
                }
                if model.manualSessionUntil != nil {
                    HStack(spacing: 8) {
                        extensionButton(15)
                        extensionButton(30)
                        Spacer(minLength: 0)
                    }
                }
                Text(model.manualEndingDetail).font(TetherTypography.secondary)
                    .foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ManualDurationPicker(model: model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("Start manually", "수동 시작")) {
                        if model.selectedManualMinutes == 0 { model.startUntimedSession() }
                        else { model.startManualSession(minutes: model.selectedManualMinutes) }
                    }.actionButton(prominent: true)
                        .accessibilityLabel(L("Start manual session", "수동 유지 시작"))
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

    private var remainingDescription: String {
        guard let remaining = model.manualRemaining(at: clock.now) else {
            return model.snapshot.power == .ac ? L("Unlimited", "무제한") : L("Checking deadline", "마감 확인 중")
        }
        let minutes = max(0, Int(ceil(remaining / 60)))
        return L("\(minutes) min remaining", "\(minutes)분 남음")
    }

    private func extensionButton(_ minutes: Int) -> some View {
        Button(L("+\(minutes) min", "+\(minutes)분")) { model.extendManualSession(by: minutes) }
            .actionButton().controlSize(.small)
            .disabled(!model.canExtendManual(by: minutes) || model.commandPending)
            .accessibilityLabel(L("Extend manual work by \(minutes) minutes", "수동 유지 \(minutes)분 연장"))
            .accessibilityIdentifier("panel-extend-manual-\(minutes)")
    }
}

struct ManualDurationPicker: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Picker(L("Next manual duration", "다음 수동 유지 시간"), selection: Binding(
            get: { model.selectedManualMinutes }, set: { minutes in
                model.selectManualDuration(minutes == 0 ? nil : Double(minutes) * 60)
            })) {
            ForEach(model.manualDurationChoices, id: \.self) { minutes in
                Text(model.durationChoiceTitle(minutes)).tag(minutes)
            }
            if model.snapshot.power == .ac { Text(L("Unlimited · AC", "무제한 · AC")).tag(0) }
        }.labelsHidden().pickerStyle(.menu).fixedSize()
            .foregroundStyle(Color.tetherPrimary)
            .accessibilityIdentifier("manual-duration-picker")
            .accessibilityHint(L("Use Start manually to begin", "수동 시작을 눌러야 유지가 시작됩니다"))
            .disabled(!model.acceptingUserCommands || model.commandPending)
    }
}
