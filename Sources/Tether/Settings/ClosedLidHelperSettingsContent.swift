import SwiftUI
import TetherCore

/// Setup remains an explicit action and is shown only on portable Macs.
struct ClosedLidHelperSettingsContent: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var helperExpanded = false

    var body: some View {
        SettingsContentGroup(L("Closed-Lid Helper", "덮개 유지 도우미")) {
            SettingRow(title: L("Helper", "도우미")) {
                HStack(spacing: 8) { helperStatus; helperSetupButton }
            }
            if let issue = model.helperInstallationIssue { Note(issue, color: .tetherWarning) }
            helperCurrentIssue
            helperInstallationProgress
            SettingsDisclosure(title: L("Setup & Recovery", "준비와 복구"),
                isExpanded: helperExpansion, groupsSection: false) { helperRecoveryNotes }
                .accessibilityIdentifier("settings-helper-details")
        }
    }
    private var helperExpansion: Binding<Bool> { disclosures?.helper ?? $helperExpanded }

    private var helperRequiresAttention: Bool {
        !model.helperInstalled || !model.helperResponding || model.helperOutdated || model.helperNeedsRepair
            || model.coordinatedLidError != nil || model.coordinatedLidBlockReason != nil || model.helperInstallInFlight
    }

    @ViewBuilder
    private var helperInstallationProgress: some View {
        if model.helperInstallInFlight {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Waiting for administrator approval…", "관리자 인증을 기다리는 중…"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var helperRecoveryNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Note(L("Required for closed-lid work on MacBooks. The app runs general work sessions; the helper carries out closed-lid requests approved during setup.",
                   "MacBook의 덮개 유지에 필요합니다. 일반 작업은 앱이 유지하고, 도우미는 준비 과정에서 승인한 덮개 유지 요청을 실행합니다."))
        }
    }

    @ViewBuilder
    private var helperCurrentIssue: some View {
        if let problem = model.problem, case .lid = problem {
            WorkSessionNote(title: problem.title, detail: problem.message,
                symbol: "exclamationmark.circle", color: problem.color)
        }
        if let reason = model.coordinatedLidBlockReason { Note(protectionReason(reason)) }
    }

    private var helperStatus: some View {
        Text(model.helperStatus.text)
            .font(TetherTypography.body.weight(.medium)).foregroundStyle(model.helperStatus.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var helperSetupButton: some View {
        Button(model.helperInstallInFlight ? L("Working…", "처리 중…")
            : model.helperNeedsRepair || !model.helperResponding && model.helperInstalled ? L("Repair…", "복구…")
            : model.helperInstalled ? L("Review…", "확인…") : L("Prepare…", "준비…")) {
            if model.helperInstalled && !helperRequiresAttention { model.refresh() }
            else { model.installHelper() }
        }
        .actionButton(prominent: !model.helperInstalled || model.helperNeedsRepair)
        .accessibilityHint(L("macOS requests administrator approval for installation", "설치 시 macOS 관리자 인증이 필요합니다"))
        .disabled(model.userCommandsArePreview || model.developmentService || model.helperInstallInFlight)
    }
}
