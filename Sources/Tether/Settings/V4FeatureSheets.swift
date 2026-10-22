import SwiftUI
import TetherCore

/// All feature sheets keep their title and action outside the scrolling reading area.
struct V4FeatureSheet<Content: View, Actions: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(TetherTypography.page)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 14).background(.bar)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.frame(maxHeight: .infinity)
                .scrollEdgeEffectHidden(true, for: .top).clipped()
            Divider()
            HStack(spacing: 8) { actions }
                .frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }.frame(width: 560, height: 448)
            .font(TetherTypography.body).controlSize(.small).tint(.tetherAccent)
            .foregroundStyle(Color.tetherPrimary).background(Color.tetherBackground)
            .accessibilityElement(children: .contain)
    }
}

struct V4RehearsalView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var power = PowerSource.ac
    @State private var lidClosed = false
    @State private var protectionActive = false
    @State private var restoreConfirmed = true
    @State private var event = "unplug"
    @State private var result: [String] = []

    var body: some View {
        V4FeatureSheet(title: L("Rule rehearsal", "규칙 예행연습")) {
            PolicyNote(L("Virtual conditions only. This does not start work, change settings or request sleep.",
                         "가상 조건만 사용합니다. 유지 시작·설정 변경·잠자기 요청을 실행하지 않습니다."))
            SettingRow(title: L("Event", "확인할 상황")) {
                Picker(L("Event", "확인할 상황"), selection: $event) {
                    Text(L("Unplug", "전원 분리")).tag("unplug")
                    Text(L("Start a new session", "새 유지 요청")).tag("newRequest")
                    Text(L("AC condition ends", "AC 조건 해제")).tag("conditionEnded")
                    Text(L("Linked work finishes", "연결 작업 완료")).tag("taskCompleted")
                }.labelsHidden().frame(width: 190)
            }
            SettingRow(title: L("Virtual power", "가상 전원")) {
                Picker(L("Virtual power", "가상 전원"), selection: $power) {
                    Text("AC").tag(PowerSource.ac)
                    if model.hasInternalBattery { Text(L("Battery", "배터리")).tag(PowerSource.battery) }
                    Text(L("Unknown", "확인 불가")).tag(PowerSource.unknown)
                }.labelsHidden().frame(width: 136)
            }
            if model.showsLidOptions { SettingsToggle(title: L("Lid closed", "덮개 닫힘"), isOn: $lidClosed) }
            SettingsToggle(title: L("Protection stop", "보호로 중지됨"), isOn: $protectionActive)
            SettingsToggle(title: L("Tether's previous changes restored", "Tether의 이전 변경 원복 확인됨"), isOn: $restoreConfirmed)
            Divider()
            Text(L("Execution plan", "실행 계획")).font(TetherTypography.section)
            if result.isEmpty {
                Note(L("Choose virtual conditions, then rehearse.", "가상 조건을 고른 뒤 예행연습을 누르세요."))
            } else {
                ForEach(Array(result.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(Color.tetherSecondary)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Note(L("A sleep request does not guarantee that macOS will sleep. Other apps may hold their own requests.",
                   "잠자기 요청은 실제 Sleep을 보장하지 않습니다. 다른 앱의 요청이 남을 수 있습니다."))
        } actions: {
            Button(L("Close", "닫기")) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
            Spacer()
            Button(L("Rehearse", "예행연습")) {
                result = model.rehearseV4(power: power, lidClosed: lidClosed, protected: protectionActive,
                                         event: event, restoreConfirmed: restoreConfirmed)
            }.actionButton(prominent: true).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("rehearsal-run")
        }.accessibilityIdentifier("settings-rehearsal-sheet")
    }
}

struct V4SettingsHistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var preview: V4HistoryRestorePreview?
    @State private var selectedGroups = Set<String>()
    @State private var feedback: String?
    @State private var confirmRestore = false
    @State private var confirmClear = false

    var body: some View {
        V4FeatureSheet(title: L("Settings history", "설정 이력")) {
            Note(L("Restores selected settings only. Active work, protection stops, permissions and recovery records are not restored.",
                   "선택한 설정만 복원합니다. 현재 수동 유지·보호 중지·권한·원복 기록은 복원하지 않습니다."))
            if model.v4History.missingHistory {
                Note(L("Some settings history was not saved. Available entries may not include every change.",
                       "설정 이력 일부를 저장하지 못했습니다. 아래 목록에 모든 변경이 포함되지는 않을 수 있습니다."))
                    .accessibilityIdentifier("history-missing-entries-note")
            }
            if model.v4HistoryItems.isEmpty {
                PolicyNote(L("No saved settings history", "저장된 설정 이력이 없습니다"))
            }
            ForEach(model.v4HistoryItems) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title).font(TetherTypography.body.weight(.medium))
                        Spacer(minLength: 8)
                        Button(L("Compare…", "차이 확인…")) { loadPreview(item.id) }.actionButton()
                        Button(L("Delete", "삭제")) { model.deleteV4History(id: item.id); clearPreview() }.buttonStyle(.borderless)
                    }
                    Text(Texts.dateTime(item.date)).font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    Note(item.detail)
                }
                Divider()
            }
            if let preview {
                Text(L("Current value → Restore value", "현재값 → 복원값")).font(TetherTypography.section)
                PolicyNote(preview.summary)
                ForEach(preview.groups, id: \.self) { group in
                    Toggle(groupTitle(group), isOn: Binding(get: { selectedGroups.contains(group) }, set: { checked in
                        if checked { selectedGroups.insert(group) } else { selectedGroups.remove(group) }
                    })).toggleStyle(.checkbox)
                }
                if let reason = preview.blockedReason { PolicyNote(reason) }
                Note(L("Changes affecting current manual work cannot be applied. Deselect those items or review again after that session ends. Nothing is scheduled for later.",
                       "현재 수동에 영향을 주는 변경은 적용할 수 없습니다. 해당 항목을 빼거나 수동 종료 뒤 다시 확인하세요. 나중에 자동 적용하지 않습니다."))
            }
            if let feedback { PolicyNote(feedback) }
        } actions: {
            Button(L("Close", "닫기")) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
            Button(L("Clear history…", "이력 비우기…")) { confirmClear = true }.buttonStyle(.borderless)
                .disabled(model.v4HistoryItems.isEmpty)
            Spacer()
            Button(L("Restore selected…", "선택 되돌리기…")) { confirmRestore = true }
                .actionButton(prominent: true).disabled(preview == nil || selectedGroups.isEmpty || model.commandPending)
                .accessibilityIdentifier("history-restore-selected")
        }
        .confirmationDialog(L("Apply these settings?", "선택한 설정을 적용할까요?"), isPresented: $confirmRestore) {
            Button(L("Confirm and apply", "확인 적용")) { restore() }
        } message: {
            Text(L("Restoring automatic on may change current AC work after a fresh check. Missing preparation still blocks execution.",
                   "자동 켬을 복원하면 현재 AC 조건을 새로 확인해 실행이 바뀔 수 있습니다. 준비가 부족하면 실행하지 않습니다."))
        }
        .confirmationDialog(L("Clear settings history?", "설정 이력을 비울까요?"), isPresented: $confirmClear) {
            Button(L("Clear history", "이력 비우기"), role: .destructive) { model.clearV4History(); clearPreview() }
        }
        .accessibilityIdentifier("settings-history-sheet")
    }
    private func groupTitle(_ name: String) -> String {
        V4SettingsPart(rawValue: name).map(model.partTitle) ?? L("Unsupported settings group", "지원하지 않는 설정 항목")
    }
    private func loadPreview(_ id: UUID) {
        preview = model.historyRestorePreview(id: id)
        selectedGroups = Set(preview?.groups ?? [])
        feedback = preview == nil ? L("This entry is unavailable. Review the current history.", "이 이력을 사용할 수 없습니다. 현재 목록을 다시 확인하세요.") : nil
    }
    private func clearPreview() { preview = nil; selectedGroups = []; feedback = nil }
    private func restore() {
        guard let preview else { return }
        if model.applyHistoryRestore(id: preview.id, generation: preview.generation, groups: selectedGroups) {
            self.preview = nil; selectedGroups = []
            feedback = L("Selected settings saved. Current conditions determine whether automatic work can run.",
                         "선택한 설정을 저장했습니다. 실제 자동 유지는 현재 조건에 따라 적용합니다.")
        } else {
            self.preview = nil; selectedGroups = []
            feedback = L("Could not apply. Settings may have changed or current work may block the selection. Compare the entry again before applying.",
                         "적용하지 못했습니다. 다른 창의 설정 변경이나 현재 작업을 확인하고 차이를 다시 확인한 뒤 선택하세요.")
        }
    }
}
