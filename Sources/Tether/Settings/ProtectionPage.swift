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
            Note(L("Saves immediately · Protection applies to current and future work.",
                   "즉시 저장 · 현재·다음 유지에 보호 기준을 적용합니다."))
                .accessibilityIdentifier("settings-protection-save-scope")
            if let reason = model.workProtectionReason {
                WorkSessionNote(title: L("Stopped for protection", "보호를 위해 중지됨"),
                    detail: protectionReason(reason), symbol: "exclamationmark.circle", color: .tetherWarning)
                if model.canResumeWork {
                    CompactPushButton(L("Resume keep-awake", "중지 해제"), prominent: true,
                        identifier: "settings-protection-resume") { model.setEnabled(true) }
                        .disabled(model.commandPending)
                } else {
                    Note(L("Checking whether it is safe to resume. Ended manual keep-awake will not restart.",
                           "중지를 해제해도 되는지 확인 중입니다. 종료된 수동 유지는 다시 시작하지 않습니다."))
                }
            }
            activeRecordingStatus
            SettingsContentGroup(L("Device Protection", "기기 보호")) {
                ProtectionSettingsContent(model: model)
            }.accessibilityIdentifier("settings-protection-rules-details")
            ProtectionBasisView(model: model, expansion: disclosures?.protectionBasis)
            SettingsDisclosure(title: L("After Protection Stops Work", "보호로 멈춘 뒤"),
                summary: model.v3Settings.automaticallyResumeAfterProtection
                    ? L("Automatic conditions after recovery", "안전 회복 후 자동 조건 적용")
                    : L("Resume manually", "직접 중지 해제"), isExpanded: workRulesExpansion) {
                SettingsToggle(title: L("Recheck automatic conditions after protection", "보호 회복 후 자동 조건 다시 적용"),
                    isOn: Binding(get: { model.v3Settings.automaticallyResumeAfterProtection },
                        set: { model.setAutomaticallyResumeAfterProtection($0) }), identifier: "settings-protection-auto-resume")
                    .disabled(!model.acceptingUserCommands || model.commandPending)
                Note(L("When enabled, recheck automatic conditions after 60 safe seconds. Ended manual keep-awake never restarts; Stop all stays in effect.",
                       "켜면 안전한 상태가 60초 이어진 뒤 자동 조건을 다시 확인합니다. 종료한 수동 유지는 다시 시작하지 않으며 모두 중지는 유지합니다."))
            }.accessibilityIdentifier("settings-work-rules-details")
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
