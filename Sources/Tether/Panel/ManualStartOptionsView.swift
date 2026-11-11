import SwiftUI
import TetherCore

struct ManualStartOptionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var useEndTime = false
    @State private var minutes = "45"
    @State private var endTime = Date().addingTimeInterval(3600)
    @State private var error: String?

    private var selection: ManualStartSelection? { useEndTime ? .until(endTime) : ManualStartSelection.parseMinutes(minutes) }
    private var canStart: Bool { selection.flatMap { model.manualStartSelectionDuration($0) } != nil }
    var body: some View {
        V4FeatureSheet(title: L("Start with another duration", "다른 시간으로 시작")) {
            Text(L("This new timer only", "새 타이머에만 적용")).font(TetherTypography.secondary).foregroundStyle(.secondary)
            Picker(L("End by", "시간 방식"), selection: $useEndTime) {
                Text(L("Duration", "사용 시간")).tag(false)
                Text(L("End time", "끝날 시각")).tag(true)
            }.pickerStyle(.segmented)
            if useEndTime {
                DatePicker(L("End at", "끝날 시각"), selection: $endTime, displayedComponents: [.date, .hourAndMinute])
                    .accessibilityIdentifier("manual-custom-end-time")
            } else {
                HStack {
                    TextField(L("Minutes", "분"), text: $minutes)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                        .accessibilityIdentifier("manual-custom-minutes")
                    Text(L("minutes", "분"))
                }
            }
            Note(L("Selecting a duration does not start work. Start rechecks current power and protection. The timer continues to elapse during sleep.",
                   "시간을 고르는 것만으로 시작되지 않습니다. 시작할 때 현재 전원·보호를 다시 확인하며, 잠자기 중에도 시간은 흐릅니다."))
            if model.snapshot.power == .battery {
                Note(L("The complete duration must fit the current battery limit.", "선택한 시간 전체가 현재 배터리 한도 안에 있어야 합니다."))
            }
            if let error { Note(error, color: .tetherWarning) }
        } actions: {
            Button(L("Cancel", "취소")) { dismiss() }
                .actionButton().keyboardShortcut(.cancelAction)
            Spacer()
            Button(L("Start this timer", "이 시간으로 시작")) {
                if let selection, model.startManualSelection(selection) { dismiss() }
                else { error = model.errorText ?? L("Check the end time, battery limit and current state.", "끝날 시각·배터리 한도·현재 상태를 확인하세요.") }
            }.actionButton(prominent: true).keyboardShortcut(.defaultAction)
                .disabled(!canStart)
                .accessibilityIdentifier("manual-custom-start")
        }
    }
}
