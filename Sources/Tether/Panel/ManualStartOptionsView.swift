import SwiftUI
import TetherCore

/// Presentation follows the observed Sleep consumption contract, not a paused timer.
enum ManualStartText {
    static var selectionDetail: String {
        L("Selecting a duration does not start work. Start rechecks current power and protection.",
          "시간 선택만으로 시작되지 않습니다. 시작할 때 전원·보호 상태를 다시 확인합니다.")
    }
    static var sleepDetail: String {
        L("Entering sleep ends this manual session. Waking the Mac does not restart it.",
          "잠자기에 들어가면 수동 유지가 끝나며, 깨어나도 다시 시작하지 않습니다.")
    }
}

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
            Text(L("This manual start only", "이번 수동 유지에만 적용")).font(TetherTypography.secondary).foregroundStyle(.secondary)
            Picker(L("Time setting", "시간 지정 방식"), selection: $useEndTime) {
                Text(L("Duration", "유지 시간")).tag(false)
                Text(L("End time", "종료 시각")).tag(true)
            }.pickerStyle(.segmented)
            if useEndTime {
                DatePicker(L("End at", "종료 시각"), selection: $endTime, displayedComponents: [.date, .hourAndMinute])
                    .accessibilityIdentifier("manual-custom-end-time")
            } else {
                HStack {
                    TextField(L("Minutes", "분"), text: $minutes)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                        .accessibilityIdentifier("manual-custom-minutes")
                    Text(L("minutes", "분"))
                }
            }
            Note(ManualStartText.selectionDetail)
            Note(ManualStartText.sleepDetail)
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
                else { error = model.errorText ?? L("Check the end time, battery limit and current state.", "종료 시각·배터리 한도·현재 상태를 확인하세요.") }
            }.actionButton(prominent: true).keyboardShortcut(.defaultAction)
                .disabled(!canStart)
                .accessibilityIdentifier("manual-custom-start")
        }
    }
}
