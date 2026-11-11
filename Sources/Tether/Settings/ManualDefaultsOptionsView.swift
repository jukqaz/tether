import SwiftUI
import TetherCore

/// These controls edit a local draft. Only the explicit Apply action saves it;
/// opening or dismissing the sheet never changes the active request or globals.
struct ManualDefaultsOptionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: V4Settings
    @State private var feedback: String?
    @State private var applicationDetailsExpanded = false

    let embedded: Bool
    let applicationDetails: Binding<Bool>?

    init(model: AppModel, embedded: Bool = false, applicationDetails: Binding<Bool>? = nil) {
        self.model = model
        self.embedded = embedded
        self.applicationDetails = applicationDetails
        _draft = State(initialValue: model.v4Settings)
    }

    @ViewBuilder var body: some View {
        if embedded {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                editorContent
                editorActions
            }
        } else {
            V4FeatureSheet(title: L("Manual Features · Apply to Save", "수동 유지 기능 · 적용 버튼으로 저장")) {
                editorContent
            } actions: { editorActions }
            .accessibilityIdentifier("settings-manual-defaults-sheet")
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            if !embedded {
                Note(L("Applies at the next manual start. Current work stays unchanged.",
                       "다음 수동 시작부터 적용됩니다. 현재 유지는 바뀌지 않습니다."))
                    .accessibilityIdentifier("manual-defaults-save-summary")
            }
            displayOptions
            if model.showsLidOptions {
                SettingsToggle(title: L("Continue with the lid closed", "덮개를 닫아도 계속 사용"),
                    isOn: $draft.nextManualOptions.closedLid, identifier: "manual-defaults-closed-lid")
                    .disabled(controlsDisabled || !model.capabilities.lidControlAvailable)
            }
            if model.showsLidOptions && draft.nextManualOptions.closedLid
                && (!model.v3Settings.allowClosedLid || !model.helperSetupConfirmed) {
                Note(lidApplicationDetail(for: draft.nextManualOptions))
                    .accessibilityIdentifier("manual-defaults-lid-global-note")
            }
            SettingsDisclosure(title: L("Application Details", "적용 범위 자세히"),
                isExpanded: applicationDetailsExpansion, groupsSection: false,
                identifier: "manual-defaults-application-details") {
                Note(manualOptionsSaveScope)
                    .accessibilityIdentifier("manual-defaults-scope")
                Note(L("App-wide permission is set separately in Power & Lid. Features are checked again when work starts.",
                       "앱 전체 허용은 전원·덮개에서 따로 정하며, 시작할 때 조건을 다시 확인합니다."))
                if draft.nextManualOptions.display && draft.nextManualOptions.releaseDisplayAfterIdle != nil {
                    Note(L("Only display keep-awake ends after no keyboard or mouse input. Keep-awake and any time limit continue.",
                           "키보드·마우스 입력이 없으면 화면 켜두기만 해제합니다. 작업 유지와 시간 한도는 계속됩니다."))
                }
            }.accessibilityIdentifier("manual-defaults-application-details")
            if let feedback { Note(feedback, color: .tetherWarning).accessibilityIdentifier("manual-defaults-feedback") }
        }
    }

    private var displayOptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsToggle(title: L("Keep the display on", "화면 켜두기"),
                isOn: $draft.nextManualOptions.display, identifier: "manual-defaults-display")
                .disabled(controlsDisabled)
            SettingRow(title: L("Release when inactive", "입력 없을 때 켜두기 해제")) {
                CompactPopUp(title: L("Display inactivity timeout", "입력 없이 대기할 시간"),
                    selection: $draft.nextManualOptions.releaseDisplayAfterIdle,
                    choices: idleChoices, identifier: "manual-defaults-display-idle")
                    .disabled(controlsDisabled || !draft.nextManualOptions.display)
            }
            if !model.capabilities.generalIdleAvailable || draft.nextManualOptions.display && !model.v3Settings.keepDisplayAwake {
                Note(displayApplicationDetail(for: draft.nextManualOptions))
                    .accessibilityIdentifier("manual-defaults-display-global-note")
            }
        }
    }

    private var applicationDetailsExpansion: Binding<Bool> { applicationDetails ?? $applicationDetailsExpanded }

    @ViewBuilder
    private var editorActions: some View {
        if embedded {
            if hasChanges {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SettingsMetrics.rowSpacing) {
                        draftStatus.fixedSize(horizontal: true, vertical: true)
                        Spacer(minLength: 0)
                        editorButtons
                    }
                    VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                        draftStatus
                        editorButtons.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                draftStatus
            }
        } else {
            editorButtons.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var draftStatus: some View {
        Note(hasChanges ? L("Unsaved changes", "저장하지 않은 변경")
            : L("Saved · applies at the next manual start", "저장됨 · 다음 수동 시작에 적용"))
            .accessibilityIdentifier("manual-defaults-save-summary")
    }

    private var editorButtons: some View {
        HStack(spacing: 8) {
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
                .accessibilityHint(L("Saves only this section's feature choices for the next manual start", "이 구역의 기능 선택만 다음 시작의 기본값으로 저장합니다"))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var manualOptionsSaveScope: String {
        if !embedded {
            return L("Apply saves only these feature choices for the next manual start. Cancel leaves them unchanged. Current work, its end time and app-wide permissions stay unchanged.",
                     "적용하면 이 기능 선택만 다음 시작의 기본값으로 저장합니다. 취소하면 저장하지 않습니다. 현재 작업·종료 시각과 앱 전체 허용은 바뀌지 않습니다.")
        }
        return model.showsLidOptions
            ? L("Apply and Discard affect only the display, lid and inactivity choices above. Current work, its end time and app-wide permissions stay unchanged.",
                "적용·변경 취소는 위의 화면·덮개·입력 없음 설정에만 적용됩니다. 현재 작업·종료 시각과 앱 전체 허용은 바뀌지 않습니다.")
            : L("Apply and Discard affect only the display and inactivity choices above. Current work, its end time and app-wide permissions stay unchanged.",
                "적용·변경 취소는 위의 화면·입력 없음 설정에만 적용됩니다. 현재 작업·종료 시각과 앱 전체 허용은 바뀌지 않습니다.")
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
            return L("The display will not be kept on at the next manual start.", "다음에 직접 시작할 때는 화면 켜두기를 사용하지 않습니다.")
        }
        guard model.v3Settings.keepDisplayAwake else {
            return L("Also turn on ‘Allow display keep-awake’ in Power & Lid.", "전원·덮개의 ‘화면 켜두기 허용’도 켜야 합니다.")
        }
        return L("Display keep-awake is allowed and will be checked again at start.", "화면 켜두기가 허용되어 있습니다. 시작할 때 다시 확인합니다.")
    }

    func lidApplicationDetail(for options: V4RequestOptions) -> String {
        guard model.capabilities.lidControlAvailable else {
            return L("Closed-lid work is unavailable on this Mac. The saved choice is preserved.",
                     "이 Mac에서는 덮개 닫고 사용 기능을 지원하지 않습니다. 저장된 선택은 보존합니다.")
        }
        guard options.closedLid else {
            return L("Closed-lid use will be off at the next manual start.", "다음에 직접 시작할 때는 덮개 닫고 사용을 끕니다.")
        }
        guard model.v3Settings.allowClosedLid else {
            return L("Also turn on ‘Allow closed-lid use’ in Power & Lid.", "전원·덮개의 ‘덮개 닫고 사용 허용’도 켜야 합니다.")
        }
        guard model.helperSetupConfirmed else {
            return L("Prepare the closed-lid helper in Power & Lid before starting.", "시작하기 전에 전원·덮개에서 덮개 닫고 사용 도우미를 준비하세요.")
        }
        return L("Closed-lid permission and helper are ready; conditions will be rechecked at start.",
                 "덮개 허용·도우미가 준비되어 있습니다. 시작할 때 조건을 다시 확인합니다.")
    }
}
