import SwiftUI
import TetherCore

struct ProtectionPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var workRulesExpanded = false
    @State private var diagnosticsExpanded = false
    @State private var usageStatisticsExpanded = false
    @State private var showSystemOverlap = false

    var body: some View {
        SettingsForm {
            if let problem = model.problem, case .error = problem {
                ProblemBanner(problem: problem, model: model, compact: false, embeddedInForm: true)
                    .accessibilityIdentifier("settings-error-context")
            }
            if let reason = model.workProtectionReason {
                WorkSessionNote(title: L("Stopped for protection", "보호를 위해 중지했어요"),
                    detail: protectionReason(reason), symbol: "exclamationmark.circle", color: .tetherWarning)
                if model.canResumeWork {
                    CompactPushButton(L("Allow again", "다시 허용"), prominent: true,
                        identifier: "settings-protection-resume") { model.setEnabled(true) }
                        .disabled(model.commandPending)
                } else {
                    Note(L("Checking that it is safe to start again. Ended timers stay ended.",
                           "다시 시작해도 되는지 확인 중입니다. 끝난 타이머는 돌아오지 않습니다."))
                }
            }
            SettingsContentGroup(L("Device Protection", "기기 보호")) {
                ProtectionSettingsContent(model: model)
            }.accessibilityIdentifier("settings-protection-rules-details")
            SettingsDisclosure(title: L("After Protection Stops Work", "보호로 멈춘 뒤"),
                summary: model.v3Settings.automaticallyResumeAfterProtection
                    ? L("Automatic rules after recovery", "안전 회복 후 자동 조건 적용")
                    : L("Manual restart", "직접 다시 시작"), isExpanded: workRulesExpansion) {
                SettingsToggle(title: L("Resume automatic rules after protection", "보호 회복 후 자동 조건 다시 적용"),
                    isOn: Binding(get: { model.v3Settings.automaticallyResumeAfterProtection },
                        set: { model.setAutomaticallyResumeAfterProtection($0) }), identifier: "settings-protection-auto-resume")
                    .disabled(!model.acceptingUserCommands || model.commandPending)
                Note(L("Automatic rules are checked again after 60 safe seconds. Ended timers and Stop all are not restored.",
                       "안전한 상태가 60초 이어지면 자동 조건을 다시 확인합니다. 끝난 타이머와 모두 중지는 복원하지 않습니다."))
            }.accessibilityIdentifier("settings-work-rules-details")
            activeRecordingStatus
            SettingsDisclosure(title: L("Usage statistics", "사용 통계"),
                summary: L("Last 7 days", "최근 7일"), isExpanded: usageStatisticsExpansion) {
                UsageStatisticsView(model: model)
            }.accessibilityIdentifier("settings-usage-statistics-details")

            RecentActivityView(model: model)

            SettingsContentGroup(L("Other Apps", "다른 앱")) {
                SettingRow(title: L("Keep-awake requests", "잠자기 방지 요청"),
                    detail: model.otherAppKeepAwakeSummary ?? L("Review current requests when needed", "필요할 때 현재 요청을 확인합니다")) {
                    CompactPushButton(L("Review…", "요청 확인…"), identifier: "settings-review-sleep-influences") {
                        model.presentActivityReview()
                    }.accessibilityLabel(L("Review other app keep-awake requests", "다른 앱의 잠자기 방지 요청 확인"))
                }
                Note(L("Installed or running does not mean conflicting.", "설치·실행 중이라는 이유만으로 충돌로 표시하지 않습니다."))
            }.accessibilityIdentifier("settings-other-app-requests-details")

            SettingsDisclosure(title: L("Logs and reports", "로그와 보고서"),
                summary: L("Advanced", "고급"), isExpanded: diagnosticsExpansion) {
                    VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                        DiagnosticControls(model: model, showActiveRecordingStatus: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        Button(L("Features shared with macOS…", "macOS와 겹치는 기능…")) { showSystemOverlap = true }
                            .buttonStyle(.link).accessibilityIdentifier("settings-open-system-overlap")
                    }
            }.accessibilityIdentifier("settings-records-diagnostics-details")

        }
        .sheet(isPresented: $showSystemOverlap) {
            V4FeatureSheet(title: L("Features shared with macOS", "macOS와 겹치는 기능")) {
                SystemFeatureOverlapView(model: model, monitor: model.systemSettings)
            } actions: {
                Button(L("Back", "뒤로")) { showSystemOverlap = false }
                    .actionButton().keyboardShortcut(.cancelAction)
                Spacer()
            }.accessibilityIdentifier("settings-system-overlap-sheet")
        }
        .onAppear { revealRequestedOtherAppDetails() }
        .onChange(of: model.otherAppDetailsRequested) { _, requested in
            if requested { revealRequestedOtherAppDetails() }
        }
    }

    var activeRecordingStatus: DiagnosticRecordingStatusRow { DiagnosticRecordingStatusRow(model: model) }
    private var workRulesExpansion: Binding<Bool> { disclosures?.workRules ?? $workRulesExpanded }
    func revealRequestedOtherAppDetails() {
        guard model.otherAppDetailsRequested else { return }
        model.otherAppDetailsRequested = false
        model.presentActivityReview()
    }

    private var usageStatisticsExpansion: Binding<Bool> { disclosures?.usageStatistics ?? $usageStatisticsExpanded }
    private var diagnosticsExpansion: Binding<Bool> { disclosures?.diagnostics ?? $diagnosticsExpanded }
}
