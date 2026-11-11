import SwiftUI
import TetherCore

struct DiagnosticControls: View {
    @ObservedObject var model: AppModel
    let showActiveRecordingStatus: Bool
    @State private var minutes = 15
    @State private var hours: Int
    @State private var includeProcessNames: Bool

    init(model: AppModel, showActiveRecordingStatus: Bool = true) {
        self.model = model
        self.showActiveRecordingStatus = showActiveRecordingStatus
        let saved = model.defaults.integer(forKey: "diagnosticReportHours")
        _hours = State(initialValue: [1, 6, 24, 72].contains(saved) ? saved : 24)
        _includeProcessNames = State(initialValue: model.defaults.bool(forKey: "diagnosticProcessNames"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Reproduce a problem", "문제 재현 기록")).font(.callout.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if model.diagnosticRecordingActive {
                if showActiveRecordingStatus { DiagnosticRecordingStatusRow(model: model) }
            } else {
                SettingRow(title: L("Record from now", "앞으로 기록할 시간"),
                    detail: L("Start before reproducing a problem; recording ends automatically after this duration.",
                              "문제를 재현하기 전에 시작하세요. 선택한 시간 뒤 자동으로 끝납니다.")) {
                    HStack(spacing: 8) {
                        Picker(L("Record from now", "앞으로 기록할 시간"), selection: $minutes) {
                            ForEach(DiagnosticRecording.choices, id: \.self) { Text(Texts.duration(Double($0 * 60))).tag($0) }
                        }.labelsHidden().frame(width: 90, alignment: .trailing)
                            .accessibilityIdentifier("diagnostic-recording-duration")
                            .disabled(!model.diagnosticControlsAccess.ancillary)
                        Button(L("Start recording", "기록 시작")) { model.setDebugLogging(true, minutes: minutes) }
                            .accessibilityIdentifier("diagnostic-recording-start")
                    }
                }.disabled(!model.diagnosticControlsAccess.recording)
            }
            HStack(spacing: 8) {
                Button(L("Mark this moment", "문제 발생 시점 표시")) { model.markDiagnostic() }
                    .disabled(!model.canRecordDiagnostics)
                if !model.usesUserSession { Button(L("Show log files", "로그 파일 보기")) { model.revealLogs() } }
            }
            .disabled(!model.diagnosticControlsAccess.ancillary)
            if let note = model.diagnosticNote { Note(note) }
            DisclosureGroup(L("Recording and retention", "기록·보관 방식")) {
                Note(model.usesUserSession
                     ? L("Basic decisions are recorded in macOS logs. The latest 128 events stay in app memory until quit. Detailed recording ends automatically; no separate log file is created.", "기본 판단은 macOS 로그에 기록하며 최근 128개 동작은 앱을 종료할 때까지 메모리에 보관합니다. 상세 기록은 선택한 시간 뒤 끝나며 별도 로그 파일을 만들지 않습니다.")
                     : L("Basic events are always recorded. Detailed recording ends automatically. Up to three previous 2 MB log files are retained.", "기본 동작은 항상 기록하며 상세 기록은 선택한 시간 뒤 끝납니다. 이전 로그는 파일당 2MB씩 최대 3개 보관합니다."))
                    .padding(.top, 6)
            }.accessibilityIdentifier("diagnostic-retention-details")
            Divider()
            Text(L("Problem report", "문제 보고서")).font(.callout.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            SettingRow(title: L("Past records to include", "과거 기록 범위"), showsAccessibleTitle: false) {
                Picker(L("Past records to include", "과거 기록 범위"), selection: $hours) {
                    ForEach([1, 6, 24, 72], id: \.self) { Text(L("Last \($0) h", "최근 \($0)시간")).tag($0) }
                }.labelsHidden().frame(width: 132, alignment: .trailing)
                    .accessibilityIdentifier("diagnostic-report-range")
            }
            .disabled(!model.diagnosticControlsAccess.ancillary)
            SettingsToggle(title: L("Include app names in power requests", "전원 요청 목록에 앱 이름 포함"), isOn: $includeProcessNames)
                .disabled(!model.diagnosticControlsAccess.ancillary)
            Note(L("Includes available past records. User and Mac names are masked and assertion payloads omitted. Save to a location you choose, or copy locally; nothing is uploaded.",
                   "보관된 과거 기록만 포함합니다. 사용자·Mac 이름은 가리고 요청 설명 원문은 제외합니다. 저장 위치를 직접 고르거나 복사하며 어디에도 전송하지 않습니다."))
            HStack(spacing: 8) {
                Button(L("Save Report…", "보고서 저장…")) { exportReport(copy: false) }
                    .accessibilityIdentifier("diagnostic-report-save")
                Button(L("Copy Report", "보고서 복사")) { exportReport(copy: true) }
                    .accessibilityIdentifier("diagnostic-report-copy")
                if model.diagnosticsBusy {
                    ProgressView().controlSize(.small).accessibilityLabel(L("Preparing the diagnostic report", "진단 보고서 준비 중"))
                }
            }.disabled(model.diagnosticsBusy || !model.diagnosticControlsAccess.ancillary)
            if let note = model.reportNote { Note(note) }
            Note(L("Log retention and the report size limit can leave gaps within the selected range.", "로그 보관 기간·보고서 크기 한도로 선택한 기간의 일부 기록이 없을 수 있습니다."))
        }
        .onChange(of: hours) { _, value in
            guard !model.userCommandsArePreview, !model.developmentService else { return }
            model.defaults.set(value, forKey: "diagnosticReportHours")
        }
        .onChange(of: includeProcessNames) { _, value in
            guard !model.userCommandsArePreview, !model.developmentService else { return }
            model.defaults.set(value, forKey: "diagnosticProcessNames")
        }
    }

    private func exportReport(copy: Bool) {
        guard model.diagnosticControlsAccess.ancillary else { return }
        // A native menu can still be committing its selection when the next action arrives.
        // Collect options in the next normal event-loop turn, after menu tracking ends.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
            let defaults = model.defaults
            let selectedHours = defaults.object(forKey: "diagnosticReportHours") as? Int ?? 24
            let range = [1, 6, 24, 72].contains(selectedHours) ? selectedHours : 24
            model.createDiagnosticReport(copy: copy, hours: Double(range),
                includeProcessNames: defaults.bool(forKey: "diagnosticProcessNames"))
            }
        }
    }

}

/// Active recording is a current operation, so its status and Stop action must
/// remain available independently of the collapsed diagnostics preferences.
struct DiagnosticRecordingStatusRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.diagnosticRecordingActive {
            SettingRow(title: L("Recording status", "기록 상태"), detail: recordingDetail) {
                Button(L("Stop recording", "기록 끝내기"), action: stopRecording)
                    .actionButton()
                    .accessibilityIdentifier("diagnostic-recording-stop")
                    .disabled(!model.diagnosticControlsAccess.recording)
            }
            .accessibilityIdentifier("diagnostic-recording-status")
        }
    }

    var recordingDetail: String {
        guard let until = model.diagnosticRecordingUntil else { return L("Existing recording stays on until you stop it.", "기존 설정에 따라 직접 끝낼 때까지 기록 중입니다.") }
        return L("Recording until \(Texts.time(until))", "\(Texts.time(until))까지 기록 중")
    }

    func stopRecording() { model.setDebugLogging(false) }
}
