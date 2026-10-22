import TetherCore
import Carbon
import SwiftUI

struct V4ShortcutSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: V4ShortcutController
    init(model: AppModel) {
        self.model = model
        self.controller = model.v4ShortcutController
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Note(L("Unassigned by default. Choose a key and apply explicitly. Registration conflicts keep the previous valid shortcut.",
                   "기본은 미지정입니다. 키를 고른 뒤 직접 적용하세요. 등록 충돌이 있으면 기존 유효 단축키를 보존합니다."))
            ForEach(V4AutomationAction.allCases.filter { $0 != .status }) { action in
                V4ShortcutRow(controller: controller, action: action)
            }
            if let error = controller.lastError { PolicyNote(error) }
            Divider()
            Note(L("Shortcuts actions use the same current-session checks. They cannot bypass protection, resume ended manual work or automatically request new permissions.",
                   "Shortcuts 조작도 같은 현재 사용자·보호 확인을 거칩니다. 보호를 우회하거나 끝난 수동을 되살리거나 새 권한을 자동 요청하지 않습니다."))
        }.disabled(model.userCommandsArePreview || model.developmentService || !model.acceptingUserCommands)
    }
}

private struct V4ShortcutRow: View {
    @ObservedObject var controller: V4ShortcutController
    let action: V4AutomationAction
    @State private var keyCode: UInt32
    @State private var modifiers: UInt32

    init(controller: V4ShortcutController, action: V4AutomationAction) {
        self.controller = controller; self.action = action
        _keyCode = State(initialValue: controller.assignments[action]?.keyCode ?? 255)
        _modifiers = State(initialValue: controller.assignments[action]?.modifiers ?? UInt32(controlKey | optionKey))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(action.title).frame(maxWidth: .infinity, alignment: .leading)
                Picker(L("Modifiers", "보조키"), selection: $modifiers) {
                    Text("⌃⌥").tag(UInt32(controlKey | optionKey))
                    Text("⌃⌥⇧").tag(UInt32(controlKey | optionKey | shiftKey))
                    Text("⌘⌥").tag(UInt32(cmdKey | optionKey))
                    Text("⌘⌃⌥").tag(UInt32(cmdKey | controlKey | optionKey))
                }.labelsHidden().frame(width: 86).disabled(keyCode == 255)
                Picker(L("Key", "키"), selection: $keyCode) {
                    Text(L("Unassigned", "미지정")).tag(UInt32(255))
                    ForEach(V4ShortcutChord.keys, id: \.code) { key in Text(key.label).tag(key.code) }
                }.labelsHidden().frame(width: 86)
                Button(L("Apply", "적용")) {
                    _ = controller.assign(keyCode == 255 ? nil : V4ShortcutChord(keyCode: keyCode, modifiers: modifiers), to: action)
                }.actionButton().accessibilityIdentifier("shortcut-apply-\(action.rawValue)")
            }.frame(minHeight: 30)
            if let chord = controller.assignments[action] {
                Text((controller.activeActions.contains(action) ? L("Active: ", "사용 중: ") : L("Saved; registration unavailable: ", "저장됨 · 등록 확인 필요: ")) + chord.title)
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
            }
        }
    }
}
