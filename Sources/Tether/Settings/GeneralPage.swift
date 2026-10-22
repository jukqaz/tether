import SwiftUI
import TetherCore

struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var workRulesExpanded = false
    @State private var showRehearsal = false
    @State private var showAdvancedRules = false

    var body: some View {
        SettingsForm {
            if let problem = model.problem {
                ProblemBanner(problem: problem, model: model, compact: false, embeddedInForm: true)
            }
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                SettingsToggle(title: L("Automatic on AC", "AC 자동 유지"),
                    detail: L("When to keep working while power is connected. Manual sessions remain available when off.",
                              "전원이 연결됐을 때 언제 유지할지 정합니다. 꺼도 수동 유지는 시작할 수 있습니다."),
                    isOn: Binding(get: { model.automaticEnabled }, set: { model.setAutomaticEnabled($0) }))
                    .disabled(settingsControlsDisabled)
                    .accessibilityIdentifier("automatic-ac-toggle")
                SettingRow(title: L("Automatic condition", "자동 조건")) {
                    Button { showAdvancedRules = true } label: {
                        Text(model.v4RuleSummary).multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }.actionButton()
                        .disabled(settingsControlsDisabled)
                        .accessibilityIdentifier("settings-automatic-rules")
                }
                if model.showsLidOptions { closedLidControls }
            }
            Divider().overlay(Color.tetherDivider)
            SettingsToggle(title: L("Keep the display awake during work", "작업 중 화면 유지"),
                detail: L("Automatic locking and password requirements follow macOS settings.",
                          "자동 잠금·암호 요구는 macOS 설정을 따릅니다."),
                isOn: Binding(get: { model.v3Settings.keepDisplayAwake }, set: { model.setKeepDisplayAwake($0) }))
                .disabled(settingsControlsDisabled)
                .accessibilityIdentifier("keep-display-awake-toggle")
            if let error = model.userSessionStatus?.displayError { Note(error, color: .tetherWarning) }
            Divider().overlay(Color.tetherDivider)
            SettingRow(title: L("Rule rehearsal", "규칙 예행연습"),
                       detail: L("Check an execution plan without changing this Mac.", "Mac을 바꾸지 않고 실행 계획을 확인합니다.")) {
                Button(L("Rehearse…", "예행연습…")) { showRehearsal = true }.actionButton()
                    .accessibilityIdentifier("settings-open-rehearsal")
            }
            DisclosureGroup(L("Ending and resuming rules", "종료·재개 규칙"), isExpanded: workRulesExpansion) {
                VStack(alignment: .leading, spacing: 8) {
                    PolicyNote(L("Unplugging ends every Tether session. Battery work must be started again manually.",
                                 "전원을 분리하면 Tether의 모든 유지가 끝납니다. 배터리 유지는 직접 새로 시작하세요."))
                    Note(L("Ending manual work leaves enabled AC automatic rules active. Turning automatic rules off only ends automatic work.",
                           "수동만 종료해도 켜 둔 AC 자동 조건은 계속 적용됩니다. 자동을 끄면 자동 유지만 끝납니다."))
                    Note(L("Pause all ends manual work. Resume only evaluates enabled AC automatic rules; ended manual work is not restored.",
                           "모두 일시중지는 수동 유지를 끝냅니다. 재개는 켜 둔 AC 자동 조건만 다시 평가하며, 끝난 수동 유지는 복원하지 않습니다."))
                    if model.hasInternalBattery {
                        Note(L("Connecting AC during battery manual work does not extend its original deadline.",
                               "배터리 수동 중 AC를 연결해도 최초 마감은 늘어나지 않습니다."))
                    }
                    Note(L("Sleep is a request, not a guarantee. Other apps and macOS may keep the Mac awake. Tether does not unlock an already locked screen.",
                           "잠자기는 요청이며 실제 Sleep을 보장하지 않습니다. 다른 앱과 macOS가 Mac을 유지할 수 있으며 이미 잠긴 화면은 해제하지 않습니다."))
                }.padding(.top, 6)
            }.accessibilityIdentifier("settings-work-rules-details")
        }
        .sheet(isPresented: $showRehearsal) { V4RehearsalView(model: model) }
        .sheet(isPresented: $showAdvancedRules) { V4AutomaticRulesView(model: model) }
    }

    private var settingsControlsDisabled: Bool { !model.acceptingUserCommands || model.commandPending }
    private var workRulesExpansion: Binding<Bool> { disclosures?.workRules ?? $workRulesExpanded }

    private var closedLidControls: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsToggle(title: L("Allow closed-lid work", "덮개 유지 허용"),
                detail: L("Whether to continue when the lid closes during an active session. This does not start work by itself.",
                          "유지 중일 때 덮개를 닫아도 계속할지 정합니다. 이 옵션만으로 새 작업을 시작하지 않습니다."),
                isOn: Binding(get: { model.v3Settings.allowClosedLid }, set: { model.setAllowClosedLid($0) }))
                .disabled(settingsControlsDisabled || !model.helperSetupConfirmed)
                .accessibilityIdentifier("closed-lid-allow-toggle")
            if !model.helperSetupConfirmed {
                Button(L("Prepare closed-lid helper…", "덮개 유지 도우미 준비…")) { model.settingsPage = .system }
                    .buttonStyle(.link)
            }
            PolicyNote(L("Unplugging ends all sessions", "전원 분리 시 모든 유지 종료"))
            if model.v3Settings.allowClosedLid {
                SettingRow(title: L("Unplugged with lid closed", "닫힌 채 전원 분리"), showsAccessibleTitle: false) {
                    Picker(L("Unplugged with lid closed", "닫힌 채 전원 분리"), selection: Binding(
                        get: { model.v3Settings.disconnectAction }, set: { model.setDisconnectAction($0) })) {
                        Text(L("Request sleep · Recommended", "잠자기 요청 · 권장")).tag(WorkSessionEndAction.sleepIfClosed)
                        Text(L("Follow macOS", "macOS에 맡김")).tag(WorkSessionEndAction.followOS)
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                        .foregroundStyle(Color.tetherPrimary)
                        .disabled(settingsControlsDisabled)
                        .accessibilityIdentifier("closed-lid-disconnect-picker")
                }
            }
        }
    }
}
