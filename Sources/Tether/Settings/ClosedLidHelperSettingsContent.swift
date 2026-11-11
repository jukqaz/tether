import SwiftUI
import TetherCore

/// Summary and management use the same model; setup remains an explicit action.
struct ClosedLidHelperSettingsContent: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    var summaryOnly = false
    @State private var helperExpanded = false
    @State private var showManagement = false

    var body: some View {
        SettingsContentGroup(L("Helper", "도우미")) {
            SettingRow(title: L("Closed-lid helper", "덮개 사용 도우미")) {
                HStack(spacing: 8) {
                    Text(model.helperStatus.text)
                        .font(TetherTypography.settingsBody.weight(.medium))
                        .foregroundStyle(model.helperStatus.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(summaryOnly ? "settings-helper-current-status" : "settings-helper-management-status")
                    if summaryOnly {
                        Button(L("Manage…", "관리…")) { showManagement = true }
                            .actionButton().accessibilityIdentifier("settings-helper-manage")
                    } else { helperSetupButton }
                }
            }
            if let issue = model.helperInstallationIssue { Note(issue, color: .tetherWarning) }
            helperCurrentIssue
            helperInstallationProgress
            if !summaryOnly {
                SettingsToggle(title: WorkPermissionText.lidTitle, detail: model.lidUsageStatusText,
                    isOn: GeneralPage(model: model).lidBinding, identifier: "settings-helper-allow-lid")
                    .disabled(GeneralPage(model: model).lidControlDisabled)
                brightnessRecovery
                SettingsDisclosure(title: L("Why this helper is needed", "도우미가 필요한 이유"),
                    isExpanded: helperExpansion, groupsSection: false) {
                    Note(L("The app handles general keep-awake; the helper handles authorized closed-lid requests.",
                           "일반 잠자기 방지는 앱이, 승인한 덮개 닫고 사용 요청은 도우미가 처리합니다."))
                    Note(L("Missing device observations do not hide outstanding recovery or authorize new closed-lid use.",
                           "기기 관측이 없어도 남은 복구는 표시하며, 새 덮개 기능은 확인 전까지 허용하지 않습니다."))
                }.accessibilityIdentifier("settings-helper-details")
            }
        }
        .sheet(isPresented: $showManagement) {
            V4FeatureSheet(title: L("Closed-lid helper", "덮개 닫고 사용 도우미")) {
                ClosedLidHelperSettingsContent(model: model, disclosures: disclosures)
            } actions: {
                Button(L("Back", "뒤로")) { showManagement = false }
                    .actionButton().keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings-helper-back")
                Spacer()
            }.accessibilityIdentifier("settings-helper-sheet")
        }
    }

    private var helperExpansion: Binding<Bool> { disclosures?.helper ?? $helperExpanded }
    private var helperRequiresAttention: Bool {
        !model.helperInstalled || !model.helperResponding || model.helperOutdated || model.helperNeedsRepair
            || model.coordinatedLidError != nil || model.coordinatedLidBlockReason != nil || model.helperInstallInFlight
    }
    var setupButtonTitle: String {
        if model.helperInstallInFlight { return L("Working…", "처리 중…") }
        if !model.helperInstalled { return L("Prepare…", "준비…") }
        return helperRequiresAttention ? L("Repair…", "복구…") : L("Review…", "확인…")
    }
    @ViewBuilder private var helperInstallationProgress: some View {
        if model.helperInstallInFlight {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Waiting for administrator approval…", "관리자 인증을 기다리는 중…"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private var helperCurrentIssue: some View {
        if let problem = model.problem, case .lid = problem {
            WorkSessionNote(title: problem.title, detail: problem.message,
                symbol: "exclamationmark.circle", color: problem.color)
        }
        if let reason = model.coordinatedLidBlockReason { Note(protectionReason(reason)) }
        if model.lidReleasePending {
            Button(L("Check status again", "상태 다시 확인")) { model.refresh() }
                .buttonStyle(.link).disabled(model.commandPending)
                .accessibilityIdentifier("settings-helper-refresh-release")
        }
    }
    @ViewBuilder private var brightnessRecovery: some View {
        if model.closedLidDisplayRecoveryPending {
            Note(model.closedLidDisplayStatusText ?? L("Brightness restoration is pending.", "밝기 복구가 남아 있습니다."), color: .tetherWarning)
            CompactPushButton(L("Retry brightness restoration", "밝기 복구 다시 시도"),
                identifier: "settings-helper-retry-brightness") { model.retryClosedLidDisplayRecovery() }
                .disabled(!model.hasCoordinatorAuthority || model.commandPending)
        }
    }
    private var helperSetupButton: some View {
        Button(setupButtonTitle) {
            if model.helperInstalled && !helperRequiresAttention { model.refresh() }
            else { model.installHelper() }
        }
        .actionButton(prominent: !model.helperInstalled || model.helperNeedsRepair)
        .accessibilityHint(L("macOS requests administrator approval for installation", "설치 시 macOS 관리자 인증이 필요합니다"))
        .disabled(!model.acceptingUserCommands || model.userCommandsArePreview || model.developmentService || model.helperInstallInFlight)
        .accessibilityIdentifier("settings-helper-prepare-or-review")
    }
}
