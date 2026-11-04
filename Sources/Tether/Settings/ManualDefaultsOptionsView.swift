import SwiftUI
import TetherCore

/// These controls edit a local draft. Only the explicit Apply action saves it;
/// opening or dismissing the sheet never changes the active request or globals.
struct ManualDefaultsOptionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: V4Settings
    @State private var feedback: String?

    let embedded: Bool

    init(model: AppModel, embedded: Bool = false) {
        self.model = model
        self.embedded = embedded
        _draft = State(initialValue: model.v4Settings)
    }

    @ViewBuilder var body: some View {
        if embedded {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                editorContent
                editorActions
            }
        } else {
            V4FeatureSheet(title: L("Next manual work defaults", "다음 수동 작업 기본값")) {
                editorContent
            } actions: { editorActions }
            .accessibilityIdentifier("settings-manual-defaults-sheet")
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsToggle(title: L("Keep the display on", "화면 켜두기"),
                isOn: $draft.nextManualOptions.display, identifier: "manual-defaults-display")
                .disabled(controlsDisabled)
            if model.showsLidOptions {
                SettingsToggle(title: L("Continue with the lid closed", "덮개를 닫아도 계속 사용"),
                    isOn: $draft.nextManualOptions.closedLid, identifier: "manual-defaults-closed-lid")
                    .disabled(controlsDisabled || !model.capabilities.lidControlAvailable)
            }
            SettingRow(title: L("Release display after inactivity", "입력이 없으면 화면 유지 해제")) {
                CompactPopUp(title: L("Display inactivity delay", "화면 유휴 시간"),
                    selection: $draft.nextManualOptions.releaseDisplayAfterIdle,
                    choices: idleChoices, identifier: "manual-defaults-display-idle")
                    .disabled(controlsDisabled || !draft.nextManualOptions.display)
            }
            if draft.nextManualOptions.display && draft.nextManualOptions.releaseDisplayAfterIdle != nil {
                Note(L("Only display keeping ends after no keyboard or mouse input. Work and its timer continue.",
                       "키보드·마우스 입력이 없으면 화면 유지만 해제합니다. 작업과 타이머는 계속됩니다."))
            }
            if !model.capabilities.generalIdleAvailable || draft.nextManualOptions.display && !model.v3Settings.keepDisplayAwake {
                Note(displayApplicationDetail(for: draft.nextManualOptions))
                    .accessibilityIdentifier("manual-defaults-display-global-note")
            }
            if model.showsLidOptions && draft.nextManualOptions.closedLid
                && (!model.v3Settings.allowClosedLid || !model.helperSetupConfirmed) {
                Note(lidApplicationDetail(for: draft.nextManualOptions))
                    .accessibilityIdentifier("manual-defaults-lid-global-note")
            }
            Note(L("Saved only when applied. Current work and its end time are unchanged.",
                   "적용해야 저장됩니다. 현재 작업과 종료 시각은 바뀌지 않습니다."))
                .accessibilityIdentifier("manual-defaults-scope")
            if let feedback { Note(feedback, color: .tetherWarning).accessibilityIdentifier("manual-defaults-feedback") }
        }
    }

    private var editorActions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            CompactPushButton(embedded ? L("Discard Changes", "변경 취소") : L("Cancel", "취소"),
                identifier: "manual-defaults-cancel") {
                if embedded { draft = model.v4Settings; feedback = nil }
                else { dismiss() }
            }.disabled(embedded && !hasChanges)
            CompactPushButton(L("Apply to Next Start", "다음 시작에 적용"), prominent: true,
                identifier: "manual-defaults-apply") {
                if model.saveManualDefaultsOptions(draft.nextManualOptions, expectedGeneration: draft.generation) {
                    if embedded { draft = model.v4Settings; feedback = nil }
                    else { dismiss() }
                } else {
                    feedback = draft.generation != model.v4Settings.generation
                        ? L("Settings changed. Discard changes to reload the current defaults before applying.",
                            "설정이 바뀌었습니다. 변경 취소로 현재 기본값을 다시 불러온 뒤 적용하세요.")
                        : model.errorText ?? L("Could not apply these defaults. Review the current settings.",
                                                "기본값을 적용하지 못했습니다. 현재 설정을 확인하세요.")
                }
            }.disabled(controlsDisabled || embedded && !hasChanges)
                .accessibilityHint(L("Changes defaults for a future manual start only", "다음 수동 시작의 기본값만 바꿉니다"))
        }
    }

    private var hasChanges: Bool { draft.nextManualOptions != model.v4Settings.nextManualOptions }
    private var idleChoices: [PopupChoice<Double?>] {
        var choices = [PopupChoice<Double?>(nil, L("Off", "끔"))]
        choices += [300.0, 600, 900, 1800].map { PopupChoice(Optional($0), Texts.duration($0)) }
        if let saved = draft.nextManualOptions.releaseDisplayAfterIdle, ![300.0, 600, 900, 1800].contains(saved) {
            choices.append(PopupChoice(Optional(saved), L("Saved value · review needed", "기존 값 · 확인 필요")))
        }
        return choices
    }

    private var controlsDisabled: Bool {
        !model.acceptingUserCommands || model.commandPending || !model.capabilities.generalIdleAvailable
    }

    // Presentation only: these summaries explain prerequisites, never grant
    // execution or predict that a future request will pass its safety checks.
    func displayApplicationDetail(for options: V4RequestOptions) -> String {
        guard model.capabilities.generalIdleAvailable else {
            return L("Work-session controls are unavailable on this Mac.", "이 Mac에서는 작업 유지 제어를 지원하지 않습니다.")
        }
        guard options.display else {
            return L("The next manual start will not request display keeping.", "다음 수동 시작에서는 화면 유지를 요청하지 않습니다.")
        }
        guard model.v3Settings.keepDisplayAwake else {
            return L("Also turn on ‘Allow display keep-awake’ in Power & Lid.", "전원·덮개의 ‘화면 켜두기 허용’도 켜야 합니다.")
        }
        return L("Display keeping is allowed; it will be rechecked at start.", "화면 유지가 허용되어 있습니다. 시작할 때 다시 확인합니다.")
    }

    func lidApplicationDetail(for options: V4RequestOptions) -> String {
        guard model.capabilities.lidControlAvailable else {
            return L("Closed-lid work is unavailable on this Mac. The saved choice is preserved.",
                     "이 Mac에서는 덮개 유지를 지원하지 않습니다. 저장된 선택은 보존합니다.")
        }
        guard options.closedLid else {
            return L("The next manual start will not request closed-lid work.", "다음 수동 시작에서는 덮개 유지를 요청하지 않습니다.")
        }
        guard model.v3Settings.allowClosedLid else {
            return L("Also turn on ‘Allow closed-lid work’ in Power & Lid.", "전원·덮개의 ‘덮개 유지 허용’도 켜야 합니다.")
        }
        guard model.helperSetupConfirmed else {
            return L("Prepare the closed-lid helper in Power & Lid before starting.", "시작하기 전에 전원·덮개에서 덮개 유지 도우미를 준비하세요.")
        }
        return L("Closed-lid permission and helper are ready; conditions will be rechecked at start.",
                 "덮개 허용·도우미가 준비되어 있습니다. 시작할 때 조건을 다시 확인합니다.")
    }
}
