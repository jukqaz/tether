import SwiftUI
import TetherCore

/// These controls edit a local draft. Only the explicit Apply action saves it;
/// opening or dismissing the sheet never changes the active request or globals.
struct ManualDefaultsOptionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: V4Settings
    @State private var feedback: String?

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.v4Settings)
    }

    var body: some View {
        V4FeatureSheet(title: L("Next manual work defaults", "다음 수동 작업 기본값")) {
            Note(L("For the next manual start only. Current work and its end time stay unchanged.",
                   "다음에 직접 시작할 작업에만 적용합니다. 현재 작업과 종료 시각은 그대로입니다."))
                .accessibilityIdentifier("manual-defaults-scope")
            SettingsToggle(title: L("Request the display to stay awake", "화면 켜두기 요청"),
                isOn: $draft.nextManualOptions.display)
                .disabled(controlsDisabled)
                .accessibilityIdentifier("manual-defaults-display")
            Note(displayApplicationDetail(for: draft.nextManualOptions))
                .accessibilityIdentifier("manual-defaults-display-global-note")
            SettingRow(title: L("Allow display sleep after inactivity", "입력이 없으면 화면 절전 허용")) {
                Picker(L("Display inactivity delay", "화면 유휴 시간"), selection: $draft.nextManualOptions.releaseDisplayAfterIdle) {
                    Text(L("Off", "끔")).tag(Optional<Double>.none)
                    ForEach([300.0, 600, 900, 1800], id: \.self) { seconds in
                        Text(Texts.duration(seconds)).tag(Optional(seconds))
                    }
                    if let saved = draft.nextManualOptions.releaseDisplayAfterIdle,
                       ![300.0, 600, 900, 1800].contains(saved) {
                        Text(L("Saved value · review needed", "기존 값 · 확인 필요")).tag(Optional(saved))
                    }
                }.labelsHidden().pickerStyle(.menu)
                    .disabled(controlsDisabled || !draft.nextManualOptions.display)
                    .accessibilityIdentifier("manual-defaults-display-idle")
            }
            Note(L("After no keyboard or mouse input, only this request's display keeping ends. Work and the timer continue; other display requests still apply.",
                   "키보드·마우스 입력이 없으면 이 요청의 화면 유지에만 절전을 허용합니다. 작업·타이머와 다른 화면 요청은 계속됩니다."))
            Divider()
            SettingsToggle(title: L("Request closed-lid work", "덮개 유지 요청"),
                isOn: $draft.nextManualOptions.closedLid)
                .disabled(controlsDisabled || !model.capabilities.lidControlAvailable)
                .accessibilityIdentifier("manual-defaults-closed-lid")
            Note(lidApplicationDetail(for: draft.nextManualOptions))
                .accessibilityIdentifier(model.capabilities.lidControlAvailable
                    ? "manual-defaults-lid-global-note" : "manual-defaults-lid-unavailable")
            Note(L("Saving does not start work. At the next start, power range, battery limits and protection are checked again.",
                   "저장만으로 시작되지 않습니다. 다음 시작 때 전원 범위·배터리 한도·보호 상태를 다시 확인합니다."))
                .accessibilityIdentifier("manual-defaults-start-conditions")
            if let feedback { Note(feedback, color: .tetherWarning).accessibilityIdentifier("manual-defaults-feedback") }
        } actions: {
            Button(L("Cancel", "취소")) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("manual-defaults-cancel")
            Spacer()
            Button(L("Apply to next work", "다음 작업에 적용")) {
                if model.saveManualDefaultsOptions(draft.nextManualOptions, expectedGeneration: draft.generation) {
                    dismiss()
                } else {
                    feedback = model.errorText ?? L("Could not apply these defaults. Review the current settings.",
                                                    "기본값을 적용하지 못했습니다. 현재 설정을 확인하세요.")
                }
            }.actionButton(prominent: true).keyboardShortcut(.defaultAction)
                .disabled(controlsDisabled)
                .accessibilityHint(L("Changes only the defaults captured by a future manual request", "다음 수동 요청이 시작할 때 읽을 기본값만 바꿉니다"))
                .accessibilityIdentifier("manual-defaults-apply")
        }
        .accessibilityIdentifier("settings-manual-defaults-sheet")
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
            return L("Also turn on ‘Allow display keep-awake’ in Keep awake.", "유지 탭의 ‘화면 켜두기 허용’도 켜야 합니다.")
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
            return L("Also turn on ‘Allow closed-lid work’ in Keep awake.", "유지 탭의 ‘덮개 유지 허용’도 켜야 합니다.")
        }
        guard model.helperSetupConfirmed else {
            return L("Prepare the closed-lid helper in App settings before starting.", "시작하기 전에 앱 탭에서 덮개 유지 도우미를 준비하세요.")
        }
        return L("Closed-lid permission and helper are ready; conditions will be rechecked at start.",
                 "덮개 허용·도우미가 준비되어 있습니다. 시작할 때 조건을 다시 확인합니다.")
    }
}
