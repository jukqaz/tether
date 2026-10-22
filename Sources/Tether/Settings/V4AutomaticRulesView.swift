import SwiftUI
import TetherCore
import UniformTypeIdentifiers

/// Edits persistent choices as a local draft; only the model can validate and apply them.
struct V4AutomaticRulesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: V4Settings
    @State private var feedback: String?
    @State private var showExport = false
    @State private var showImport = false
    @State private var importData: Data?
    @State private var importSummary: String?
    @State private var exportDocument = V4SettingsDocument()

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.v4Settings)
    }

    var body: some View {
        V4FeatureSheet(title: L("AC automatic conditions", "AC 자동 조건")) {
            Picker(L("Automatic conditions", "자동 조건"), selection: $draft.automaticMode) {
                Text(L("When AC is connected", "AC 연결 중")).tag(V4AutomaticMode.acConnected)
                Text(L("Advanced conditions", "고급 조건")).tag(V4AutomaticMode.advanced)
            }.pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("automatic-mode-picker")
            PolicyNote(L("Automatic work always requires AC and protection checks. Missing conditions or permissions do not fall back to simple AC work.",
                         "자동 유지는 항상 AC와 보호 확인이 필요합니다. 조건이나 권한을 확인할 수 없으면 단순 AC로 대신 실행하지 않습니다."))
            if draft.automaticMode == .advanced {
                presetSelection
                if let index = selectedPresetIndex {
                    V4PresetEditor(model: model, preset: $draft.presets[index])
                } else {
                    Note(L("Add a preset and its conditions before applying advanced rules.", "고급 조건을 적용하려면 프리셋과 조건을 추가하세요."))
                }
                SettingsToggle(title: L("Allow experimental CPU and network conditions", "실험 CPU·네트워크 조건 허용"),
                    detail: L("Applies only to CPU load and network throughput. Unavailable observations remain unconfirmed.",
                              "CPU 사용량·네트워크 전송량에만 적용합니다. 확인할 수 없는 관측은 미확인으로 남습니다."),
                    isOn: $draft.experimentalProvidersEnabled)
                    .accessibilityIdentifier("automatic-experimental-cpu-network-toggle")
            }
            Divider()
            HStack(spacing: 12) {
                Button(L("Export saved settings…", "저장된 설정 내보내기…")) {
                    guard let data = model.exportV4Settings() else {
                        feedback = L("Could not prepare an export.", "내보낼 설정을 준비하지 못했습니다."); return
                    }
                    exportDocument = V4SettingsDocument(data: data); showExport = true
                }.actionButton()
                Button(L("Review import…", "가져오기 검토…")) { showImport = true }.actionButton()
            }
            Note(L("Imports are reviewed and saved as inactive copies. Permissions, active work and recovery records are excluded.",
                   "가져온 설정은 검토한 뒤 비활성 복사본으로 저장합니다. 권한·현재 유지·원복 기록은 포함하지 않습니다."))
            if let feedback { PolicyNote(feedback) }
        } actions: {
            Button(L("Cancel", "취소")) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
            Spacer()
            Button(L("Confirm and apply", "확인 적용")) {
                if model.saveV4AutomaticRules(draft) { dismiss() }
                else { feedback = L("Could not apply. Review the conditions and current settings, then try again.", "적용하지 못했습니다. 조건과 현재 설정을 다시 확인하세요.") }
            }.actionButton(prominent: true).keyboardShortcut(.defaultAction)
                .disabled(model.commandPending || !model.acceptingUserCommands)
                .accessibilityIdentifier("automatic-rules-apply")
        }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .json,
                      defaultFilename: "Tether-settings") { result in
            if case .failure(let error) = result { feedback = error.localizedDescription }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard let summary = model.previewV4Import(data) else {
                    feedback = L("This settings file cannot be imported.", "이 설정 파일은 가져올 수 없습니다."); return
                }
                importData = data; importSummary = summary
            } catch { feedback = error.localizedDescription }
        }
        .alert(L("Review imported settings", "가져올 설정 검토"), isPresented: Binding(
            get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button(L("Save inactive copy", "비활성 복사본 저장")) {
                if let importData, model.applyV4Import(importData) {
                    draft = model.v4Settings
                    feedback = L("Imported copy saved. Select and confirm it separately to enable it.", "가져온 복사본을 저장했습니다. 사용하려면 별도로 선택해 확인 적용하세요.")
                } else { feedback = L("Import failed. Nothing was applied.", "가져오지 못했습니다. 적용한 설정은 없습니다.") }
                importData = nil; importSummary = nil
            }
            Button(L("Cancel", "취소"), role: .cancel) { importData = nil; importSummary = nil }
        } message: { Text(importSummary ?? "") }
        .accessibilityIdentifier("settings-automatic-rules-sheet")
    }

    private var selectedPresetIndex: Int? { draft.presets.firstIndex { $0.id == draft.activePresetID } }
    private var presetSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !draft.presets.isEmpty {
                SettingRow(title: L("Preset", "프리셋")) {
                    Picker(L("Preset", "프리셋"), selection: $draft.activePresetID) {
                        Text(L("Choose…", "선택…")).tag(Optional<UUID>.none)
                        ForEach(draft.presets) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden().frame(width: 200)
                }
            }
            HStack {
                Button(L("Add preset", "프리셋 추가")) {
                    let preset = V4Preset(id: UUID(), name: L("New preset", "새 프리셋"), groups: [])
                    draft.presets.append(preset); draft.activePresetID = preset.id
                }.actionButton()
                if let index = selectedPresetIndex {
                    Button(L("Delete preset", "프리셋 삭제")) {
                        draft.presets.remove(at: index); draft.activePresetID = nil
                    }.buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct V4PresetEditor: View {
    @ObservedObject var model: AppModel
    @Binding var preset: V4Preset

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(L("Preset name", "프리셋 이름"), text: $preset.name).textFieldStyle(.roundedBorder)
            SettingsToggle(title: L("Preset enabled", "프리셋 사용"), isOn: $preset.enabled)
            Note(L("All conditions in a group must match (AND). Any matching group is enough (OR).", "그룹 안의 조건은 모두 충족(AND), 그룹 사이는 하나만 충족(OR)하면 됩니다."))
            ForEach($preset.groups) { $group in
                V4RuleGroupEditor(model: model, group: $group) { preset.groups.removeAll { $0.id == group.id } }
                Divider()
            }
            Button(L("Add OR group", "OR 그룹 추가")) {
                preset.groups.append(V4RuleGroup(id: UUID(), conditions: [V4Condition(id: UUID(), kind: .appRunning)]))
            }.actionButton()
            SettingRow(title: L("Next manual duration", "다음 수동 유지 시간")) {
                Picker(L("Next manual duration", "다음 수동 유지 시간"), selection: $preset.nextManualMinutes) {
                    ForEach([5, 10, 15, 30, 60, 120], id: \.self) { minutes in
                        Text(L("\(minutes) min", "\(minutes)분")).tag(Optional(minutes))
                    }
                    Text(L("Unlimited · AC", "무제한 · AC")).tag(Optional<Int>.none)
                }.labelsHidden().frame(width: 136)
            }
            SettingsToggle(title: L("Request display keep-awake", "화면 유지 요청"), isOn: $preset.options.display)
            SettingRow(title: L("Release display after idle", "유휴 후 화면 유지 해제")) {
                Picker(L("Release display after idle", "유휴 후 화면 유지 해제"), selection: $preset.options.releaseDisplayAfterIdle) {
                    Text(L("Off", "끔")).tag(Optional<Double>.none)
                    ForEach([5, 10, 15, 30], id: \.self) { minutes in
                        Text(L("\(minutes) min", "\(minutes)분")).tag(Optional(Double(minutes) * 60))
                    }
                }.labelsHidden().frame(width: 136)
            }
            Note(L("Releases only the display request. Unknown idle observations do not turn the display request off.",
                   "화면 요청만 해제합니다. 유휴 상태를 확인할 수 없으면 임의로 화면 요청을 끄지 않습니다."))
            if model.showsLidOptions {
                SettingsToggle(title: L("Request closed-lid work", "덮개 유지 요청"), isOn: $preset.options.closedLid)
            }
            Note(L("Requests also require the corresponding global permission. This preset cannot bypass protection or preparation.",
                   "요청에는 해당 전역 허용도 필요합니다. 프리셋으로 보호나 필수 준비를 우회할 수 없습니다."))
        }
    }
}

private struct V4RuleGroupEditor: View {
    @ObservedObject var model: AppModel
    @Binding var group: V4RuleGroup
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("All of these conditions", "아래 조건 모두 충족")).font(TetherTypography.section)
                Spacer()
                Button(L("Remove group", "그룹 삭제"), action: remove).buttonStyle(.borderless)
            }
            ForEach($group.conditions) { $condition in
                V4ConditionEditor(model: model, condition: $condition) {
                    group.conditions.removeAll { $0.id == condition.id }
                }
            }
            Button(L("Add AND condition", "AND 조건 추가")) {
                group.conditions.append(V4Condition(id: UUID(), kind: .appRunning))
            }.actionButton()
        }
    }
}

private struct V4ConditionEditor: View {
    @ObservedObject var model: AppModel
    @Binding var condition: V4Condition
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(L("Condition", "조건"), selection: $condition.kind) {
                    ForEach(V4ConditionKind.allCases.filter { !$0.isCurrentlyUnsupported || $0 == condition.kind }, id: \.self) {
                        Text($0.uiTitle).tag($0)
                    }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("automatic-condition-kind-\(condition.id.uuidString)")
                Button(L("Remove", "삭제"), action: remove).buttonStyle(.borderless)
            }
            if let limitation = model.v4ConditionLimitation(id: condition.id) {
                Note(limitation)
                    .accessibilityIdentifier("automatic-condition-limitation-\(condition.id.uuidString)")
            } else if condition.kind.isCurrentlyUnsupported {
                Note(L("This condition is currently unsupported. Its saved settings are retained, but it cannot authorize automatic work.",
                       "현재 미지원 조건입니다. 저장된 설정은 보존되며 자동 유지 조건으로 사용할 수 없습니다."))
                    .accessibilityIdentifier("automatic-condition-limitation-\(condition.id.uuidString)")
            }
            if condition.kind == .timeWindow {
                timeWindowEditor
            } else {
                TextField(L("Selected target identity", "대상 식별값"), text: $condition.target).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(condition.kind.uiTitle + L(" target", " 대상"))
                TextField(L("Display name (optional)", "표시 이름 (선택)"), text: $condition.label).textFieldStyle(.roundedBorder)
            }
            if condition.kind == .cpuLoad || condition.kind == .networkThroughput {
                TextField(condition.kind == .cpuLoad ? L("Threshold (%)", "기준값 (%)") : L("Threshold (bytes/sec)", "기준값 (바이트/초)"),
                          value: Binding(get: { condition.threshold ?? 0 }, set: { condition.threshold = $0 }), format: .number)
                    .textFieldStyle(.roundedBorder)
            }
            if condition.kind == .calendar {
                Button(L("Allow Calendar access…", "캘린더 접근 허용…")) { Task { await model.requestV4CalendarAccess() } }
                    .actionButton()
                Note(L("Reading event conditions requires full Calendar access. Access is requested only with this button.",
                       "일정 조건을 읽으려면 캘린더 전체 접근이 필요합니다. 이 버튼을 눌렀을 때만 요청합니다."))
            }
        }
        .onChange(of: condition.kind) { _, kind in
            if kind == .timeWindow && condition.timeWindow == nil {
                condition.timeWindow = V4TimeWindow(startMinute: 540, endMinute: 1020)
            }
        }
    }

    private var timeWindowEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                DatePicker(L("From", "시작"), selection: timeBinding(start: true), displayedComponents: .hourAndMinute)
                DatePicker(L("Until", "종료"), selection: timeBinding(start: false), displayedComponents: .hourAndMinute)
            }
            HStack(spacing: 8) {
                ForEach(1...7, id: \.self) { weekday in
                    Toggle(Calendar.current.shortWeekdaySymbols[weekday - 1], isOn: Binding(
                        get: { condition.timeWindow?.weekdays.contains(weekday) == true }, set: { selected in
                            var window = condition.timeWindow ?? V4TimeWindow(startMinute: 540, endMinute: 1020)
                            if selected { window.weekdays.insert(weekday) } else { window.weekdays.remove(weekday) }
                            condition.timeWindow = window
                        })).toggleStyle(.checkbox)
                }
            }
            Note(L("No weekdays selected means every day. Overnight windows belong to their start day.",
                   "요일을 고르지 않으면 매일 적용합니다. 자정을 넘는 시간대는 시작한 요일에 속합니다."))
        }
    }

    private func timeBinding(start: Bool) -> Binding<Date> {
        Binding(get: {
            let minutes = start ? condition.timeWindow?.startMinute ?? 540 : condition.timeWindow?.endMinute ?? 1020
            return Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minutes) * 60)
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            var window = condition.timeWindow ?? V4TimeWindow(startMinute: 540, endMinute: 1020)
            if start { window.startMinute = minute } else { window.endMinute = minute }
            condition.timeWindow = window
        })
    }

}

private extension V4ConditionKind {
    var isCurrentlyUnsupported: Bool {
        switch self {
        case .download, .microphoneInput, .cameraUsage, .audioPlayback, .unsupported: true
        default: false
        }
    }

    var uiTitle: String {
        switch self {
        case .appRunning: L("App running", "앱 실행 중")
        case .appFrontmost: L("Frontmost app", "앞에서 사용하는 앱")
        case .process: L("Process", "프로세스")
        case .timeWindow: L("Time window", "시간대")
        case .wifiSSID: L("Wi-Fi SSID", "Wi-Fi 이름")
        case .vpn: "VPN"
        case .ipAddress: L("IP address", "IP 주소")
        case .dns: "DNS"
        case .usb: "USB"
        case .bluetooth: "Bluetooth"
        case .volume: L("Mounted volume", "연결된 볼륨")
        case .audioOutput: L("Audio output", "오디오 출력")
        case .externalDisplay: L("External display", "외부 화면")
        case .cpuLoad: L("CPU load · experimental", "CPU 사용량 · 실험")
        case .networkThroughput: L("Network throughput · experimental", "네트워크 전송량 · 실험")
        case .calendar: L("Calendar event", "캘린더 일정")
        case .microphoneInput: L("Microphone · currently unsupported", "마이크 · 현재 미지원")
        case .cameraUsage: L("Camera · currently unsupported", "카메라 · 현재 미지원")
        case .audioPlayback: L("Audio playback · currently unsupported", "오디오 재생 · 현재 미지원")
        case .download: L("Download · currently unsupported", "다운로드 · 현재 미지원")
        case .taskEvent: L("Linked work event", "연결 작업 이벤트")
        case .unsupported: L("Currently unsupported", "현재 미지원")
        }
    }
}

private struct V4SettingsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
