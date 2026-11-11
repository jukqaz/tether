import SwiftUI
import TetherCore

struct LifecycleOptionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if let runtime = model.lifecycleOptions {
            LifecycleWebhookEditor(runtime: runtime, mayEdit: model.acceptingUserCommands && !model.commandPending)
        } else {
            V4FeatureSheet(title: L("Event actions", "이 일이 생기면 실행")) {
                Note(L("Connect to the current Tether session before editing event actions.", "현재 Tether 실행에 연결된 뒤 사건별 실행을 편집할 수 있습니다."))
            } actions: {
                Spacer()
                Button(L("Done", "완료")) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
            }
        }
    }
}

private struct LifecycleWebhookEditor: View {
    @ObservedObject var runtime: LifecycleOptionsRuntime
    var mayEdit: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LifecycleHooksSettings
    @State private var revision: UInt64
    @State private var event = LifecycleHookKind.sessionEnded
    @State private var endpoint = ""
    @State private var feedback: String?
    init(runtime: LifecycleOptionsRuntime, mayEdit: Bool) {
        self.runtime = runtime; self.mayEdit = mayEdit
        _draft = State(initialValue: runtime.settings); _revision = State(initialValue: runtime.revision)
    }
    private var newAction: LifecycleHookAction? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let action = LifecycleHookAction.webhook(url: url)
        return action.isValid ? action : nil
    }
    var body: some View {
        V4FeatureSheet(title: L("Event actions", "이 일이 생기면 실행")) {
            Text(L("Applies to future confirmed events", "앞으로 확인한 사건에 적용")).font(TetherTypography.secondary).foregroundStyle(.secondary)
            SettingsToggle(title: L("Allow configured webhooks", "설정한 Webhook 실행 허용"), isOn: $draft.enabled)
            Note(L("Send a configured HTTPS request when the selected event is confirmed. Off by default.",
                   "선택한 시작·종료가 확인되면 설정한 HTTPS 주소로 요청을 보냅니다. 기본은 꺼짐입니다."))
            ForEach($draft.rules) { $rule in
                VStack(alignment: .leading, spacing: 6) {
                    SettingsToggle(title: rule.events.map(LifecycleOptionsRuntime.eventTitle).sorted().joined(separator: ", "), isOn: $rule.enabled)
                    if case .webhook(let url) = rule.action {
                        Text(url.host ?? "").font(TetherTypography.secondary).foregroundStyle(.secondary)
                    }
                    Button(L("Remove action", "실행 항목 제거")) { draft.rules.removeAll { $0.id == rule.id } }.buttonStyle(.link)
                }
                Divider()
            }
            Picker(L("When", "이 일이 생기면"), selection: $event) {
                ForEach(LifecycleOptionsRuntime.supportedEvents, id: \.self) { kind in
                    Text(LifecycleOptionsRuntime.eventTitle(kind)).tag(kind)
                }
            }
            TextField(L("HTTPS webhook URL", "HTTPS Webhook 주소"), text: $endpoint)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("lifecycle-webhook-url")
            Button(L("Add disabled action", "꺼진 상태로 추가")) {
                guard let action = newAction else { return }
                draft.rules.append(.init(events: [event], action: action)); endpoint = ""
            }.disabled(newAction == nil || draft.rules.count >= 16 || !mayEdit || runtime.readOnly)
            Note(L("No test request is sent. Saving does not replay old events. Each event expires after five seconds; actions time out and are not retried.",
                   "시험 요청을 보내지 않습니다. 저장해도 지난 사건을 재생하지 않습니다. 사건은 5초 뒤 만료되며 실행에 시간 제한이 있고 자동 재시도하지 않습니다."))
            if let outcome = runtime.outcome { Note(outcome) }
            if let feedback { Note(feedback, color: .tetherWarning) }
        } actions: {
            Button(L("Cancel", "취소")) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
            Spacer()
            Button(L("Apply", "적용")) {
                guard runtime.save(draft, expectedRevision: revision) else {
                    feedback = L("Settings changed or this action is unavailable. Review the current options.", "설정이 바뀌었거나 사용할 수 없는 실행입니다. 현재 옵션을 다시 확인하세요."); return
                }
                dismiss()
            }.actionButton(prominent: true).keyboardShortcut(.defaultAction)
                .disabled(!mayEdit || runtime.readOnly || !LifecycleOptionsRuntime.supports(draft))
        }
    }
}
