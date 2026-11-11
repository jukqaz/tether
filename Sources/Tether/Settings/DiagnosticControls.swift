import SwiftUI
import TetherCore

struct DiagnosticControls: View {
    @ObservedObject var model: AppModel
    let showActiveRecordingStatus: Bool
    @State private var minutes = 15
    @State private var hours: Int
    @State private var includeProcessNames: Bool
    @State private var retentionDetailsExpanded = false

    init(model: AppModel, showActiveRecordingStatus: Bool = true) {
        self.model = model
        self.showActiveRecordingStatus = showActiveRecordingStatus
        let saved = model.defaults.integer(forKey: "diagnosticReportHours")
        _hours = State(initialValue: [1, 6, 24, 72].contains(saved) ? saved : 24)
        _includeProcessNames = State(initialValue: model.defaults.bool(forKey: "diagnosticProcessNames"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            Text(L("Reproduce a problem", "문제 재현 기록")).font(TetherTypography.settingsSection)
                .accessibilityAddTraits(.isHeader)
            if model.diagnosticRecordingActive {
                if showActiveRecordingStatus { DiagnosticRecordingStatusRow(model: model) }
            } else {
                SettingRow(title: L("Record from now", "앞으로 기록할 시간"),
                    detail: L("Start before reproducing the problem; stops after the selected duration.",
                              "재현 전에 시작하면 선택한 시간 뒤 자동 종료합니다.")) {
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
            SettingsDisclosure(title: L("Recording and retention", "기록·보관 방식"),
                isExpanded: $retentionDetailsExpanded, groupsSection: false) {
                Note(model.usesUserSession
                     ? L("Basic decisions go to macOS logs; the latest 128 events stay in memory until quit. Timed detailed recording creates no separate file.", "기본 판단은 macOS 로그에, 최근 128개 동작은 종료 전까지 메모리에 남깁니다. 시간제 상세 기록은 별도 파일을 만들지 않습니다.")
                     : L("Basic events are always recorded. Detailed recording stops automatically; up to three previous 2 MB log files are retained.", "기본 동작은 항상 기록하며 상세 기록은 자동 종료합니다. 이전 로그는 2MB씩 최대 3개 보관합니다."))
            }.accessibilityIdentifier("diagnostic-retention-details")
            Divider()
            Text(L("Problem report", "문제 보고서")).font(TetherTypography.settingsSection)
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
            Note(L("Includes retained records; retention and size limits can leave gaps. User and Mac names are masked; assertion payloads are omitted. Save or copy locally; nothing is uploaded.",
                   "보관된 기록만 포함하며 기간·크기 한도로 일부가 빠질 수 있습니다. 사용자·Mac 이름은 가리고 요청 설명 원문은 제외합니다. 지정한 위치에 저장하거나 복사하며 전송하지 않습니다."))
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
