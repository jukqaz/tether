import SwiftUI
import TetherCore

struct SystemPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var diagnosticsExpanded = false
    @State private var updateOptionsExpanded = false
    @State private var helperExpanded = false
    @State private var showMenuPreview = false
    @State private var showSettingsHistory = false

    var body: some View {
        SettingsForm {
            if let problem = model.problem, case .error = problem {
                ProblemBanner(problem: problem, model: model, compact: false, embeddedInForm: true)
                    .accessibilityIdentifier("settings-error-context")
            }
            if model.showsLidOptions { helperAttentionSection }
            if updateRequiresAttention {
                updateAttentionSection
            }
            activeRecordingStatus
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                SettingsToggle(title: L("Launch at login", "로그인 시 시작"), isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .disabled(model.userCommandsArePreview || model.developmentService)
                LoginItemSystemNotice(model: model)
                SettingRow(title: L("Language", "언어"), showsAccessibleTitle: false) {
                    Picker(L("Language", "언어"), selection: $model.language) {
                        Text(L("Same as macOS", "macOS와 같게")).tag(LanguageChoice.system)
                        Text("한국어").tag(LanguageChoice.korean)
                        Text("English").tag(LanguageChoice.english)
                    }.labelsHidden().pickerStyle(.menu)
                        .frame(width: SettingsMetrics.controlWidth, alignment: .trailing)
                        .disabled(model.userCommandsArePreview || model.developmentService)
                }
                if model.userCommandsArePreview || model.developmentService {
                    Button(L("Preview menu panel…", "메뉴 패널 보기…")) { showMenuPreview = true }
                        .popover(isPresented: $showMenuPreview) { TetherPanel(model: model) }
                }
            }
            Divider().overlay(Color.tetherDivider)
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                DisclosureGroup(isExpanded: updateExpansion) {
                    updateDetails.padding(.top, 6)
                } label: {
                    HStack {
                        Text(L("Updates", "업데이트"))
                        Spacer(minLength: 8)
                        if let version = model.availableUpdate { updateAvailability(version) }
                        else if !updateRequiresAttention {
                            Text(updateCheckSummary)
                                .font(TetherTypography.secondary)
                                .foregroundStyle(Color.tetherSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-updates-details")
                Divider().overlay(Color.tetherDivider)
                DisclosureGroup(L("Global shortcuts and Shortcuts", "전역 단축키·Shortcuts")) {
                    V4ShortcutSettingsView(model: model).padding(.top, 6)
                }.accessibilityIdentifier("settings-shortcuts-details")
                SettingRow(title: L("Settings history", "설정 이력"), detail: L("Review differences before restoring settings.", "설정의 차이를 확인한 뒤 선택해 되돌립니다.")) {
                    Button(L("Review…", "확인…")) { showSettingsHistory = true }.actionButton()
                        .accessibilityIdentifier("settings-open-history")
                }
                SettingRow(title: L("Other sleep influences", "다른 앱의 절전 영향")) {
                    Button(L("Review…", "확인…")) { model.presentActivityReview() }
                        .actionButton()
                        .accessibilityLabel(L("Review sleep influences", "앱·시스템 절전 영향 확인"))
                        .accessibilityIdentifier("settings-review-sleep-influences")
                }
                DisclosureGroup(isExpanded: diagnosticsExpansion) {
                    VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                        RecentActivityView(model: model)
                        DiagnosticControls(model: model, showActiveRecordingStatus: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        DisclosureGroup(L("Features shared with macOS", "macOS와 겹치는 기능")) {
                            SystemFeatureOverlapView(model: model, monitor: model.systemSettings)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.top, 6)
                }
                label: {
                    HStack {
                        Text(L("Problem records and reports", "문제 재현 기록·보고서"))
                        Spacer(minLength: 8)
                        Text(L("Advanced", "고급")).font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-records-diagnostics-details")
                Text("Tether · \(AppModel.appDisplayVersion) (\(AppModel.appBuild))")
                    .font(TetherTypography.secondary)
                    .foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .toggleStyle(.switch)
        .sheet(isPresented: $showSettingsHistory) { V4SettingsHistoryView(model: model) }
    }

    var activeRecordingStatus: DiagnosticRecordingStatusRow {
        DiagnosticRecordingStatusRow(model: model)
    }

    private var diagnosticsExpansion: Binding<Bool> { disclosures?.diagnostics ?? $diagnosticsExpanded }
    private var updateExpansion: Binding<Bool> { disclosures?.updates ?? $updateOptionsExpanded }
    private var helperExpansion: Binding<Bool> { disclosures?.helper ?? $helperExpanded }

    private var updateRequiresAttention: Bool {
        model.updateStatus.waitingForOpenLid || model.updateStatus.error != nil
            || model.updateStatus.checking || model.updateStatus.sessionInProgress
    }

    private var updateCheckSummary: String {
        model.updateStatus.lastChecked.map { L("Checked \(Texts.dateTime($0))", "확인 \(Texts.dateTime($0))") }
            ?? L("Not checked", "확인 전")
    }

    private var helperRequiresAttention: Bool {
        !model.helperInstalled || !model.helperResponding || model.helperOutdated || model.helperNeedsRepair
            || model.coordinatedLidError != nil || model.coordinatedLidBlockReason != nil || model.helperInstallInFlight
    }

    private var helperAttentionSection: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("Closed-lid helper", "덮개 유지 도우미"))
                Spacer(minLength: 6)
                helperStatus
                helperSetupButton
            }.frame(minHeight: 30)
            if let issue = model.helperInstallationIssue { Note(issue, color: .tetherWarning) }
            helperCurrentIssue
            DisclosureGroup(L("Setup and recovery", "준비와 복구"), isExpanded: helperExpansion) {
                helperRecoveryNotes.padding(.top, 6)
            }.accessibilityIdentifier("settings-helper-details")
        }
    }

    private var helperDetails: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            helperSetupButton
            helperInstallationProgress
            helperRecoveryNotes
        }
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

    private var updateAttentionSection: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            if model.updateStatus.waitingForOpenLid {
                WorkSessionNote(title: L("Installation paused", "설치 대기 중"),
                    detail: L("Open your MacBook and finish your current work before continuing.",
                              "MacBook을 열고 진행 중인 작업을 마친 뒤 계속해 주세요."),
                    symbol: "laptopcomputer", color: .tetherWarning)
                Button(L("Continue Installation", "설치 계속")) { model.resumeUpdateInstallation() }
                    .actionButton(prominent: true)
                    .disabled(model.userCommandsArePreview || model.developmentService)
            } else if let error = model.updateStatus.error {
                Note(error, color: .tetherError)
                updateCheckButton
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.updateStatus.checking
                        ? L("Checking for updates…", "업데이트 확인 중…")
                        : L("Update in progress", "업데이트 진행 중"))
                        .fixedSize(horizontal: false, vertical: true)
                    if model.updateStatus.sessionInProgress && !model.updateStatus.checking { updateCheckButton }
                }
            }
        }
    }

    private var updateDetails: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            if !updateRequiresAttention {
                updateCheckButton
            }
            SettingsToggle(title: L("Check for updates automatically", "업데이트 자동 확인"), isOn: $model.checkUpdates)
                .disabled(model.userCommandsArePreview || model.developmentService)
            Text(L("Update channel and installation", "업데이트 채널과 설치"))
                .font(TetherTypography.section).accessibilityAddTraits(.isHeader)
            V4UpdateAfterWorkView(model: model)
            UpdateSettingsCard(model: model, includesOverview: false)
                .disabled(model.userCommandsArePreview)
        }
    }

    private var helperStatus: some View {
        Text(model.helperStatus.text)
            .font(TetherTypography.body.weight(.medium)).foregroundStyle(model.helperStatus.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var updateCheckButton: some View {
        Button(model.updateStatus.checking ? L("Checking…", "확인 중…")
            : model.availableUpdate == nil ? L("Check for Updates…", "업데이트 확인…") : L("View Update…", "업데이트 보기…")) {
            model.checkForUpdates(force: true)
        }
        .actionButton(prominent: model.availableUpdate != nil)
        .disabled(model.userCommandsArePreview || model.developmentService || model.updateStatus.checking || model.updateStatus.waitingForOpenLid)
    }

    private func updateAvailability(_ version: String) -> some View {
        Label(L("\(version) available", "\(version) 사용 가능"), systemImage: "arrow.down.circle")
            .font(TetherTypography.secondary).foregroundStyle(Color.tetherAccent)
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
