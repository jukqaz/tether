import SwiftUI
import TetherCore

struct SystemPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var diagnosticsExpanded = false
    @State private var updateOptionsExpanded = false
    @State private var helperExpanded = false
    @State private var showNotifications = false
    @State private var showSettingsTransfer = false
    @State private var showAdditionalOptions = false
    @State private var showSystemOverlap = false
    @State private var showMenuPreview = false
    @State private var usageStatisticsExpanded = false
    @State private var otherAppRequestsExpanded = false

    var body: some View {
        SettingsForm {
            if let problem = model.problem, case .error = problem {
                ProblemBanner(problem: problem, model: model, compact: false, embeddedInForm: true)
                    .accessibilityIdentifier("settings-error-context")
            }
            if model.showsLidOptions && helperRequiresAttention { helperAttentionSection }
            if updateRequiresAttention {
                updateAttentionSection
            }
            activeRecordingStatus
            SettingsContentGroup(L("General", "일반")) {
                SettingsToggle(title: L("Launch at login", "로그인 시 시작"), isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .disabled(model.userCommandsArePreview || model.developmentService)
                LoginItemSystemNotice(model: model)
                SettingRow(title: L("Menu bar", "메뉴바"), showsAccessibleTitle: false) {
                    Picker(L("Menu bar display", "메뉴바 표시"), selection: $model.menuBarDetails) {
                        Text(L("Icon only", "아이콘만")).tag(false)
                        Text(L("Icon + time remaining", "아이콘 + 남은 시간")).tag(true)
                    }.labelsHidden().pickerStyle(.menu)
                        .frame(width: SettingsMetrics.controlWidth, alignment: .trailing)
                        .disabled(!model.acceptingUserCommands || model.commandPending)
                        .accessibilityIdentifier("settings-menu-bar-display")
                }
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

            SettingsDisclosure(title: L("Updates", "업데이트"),
                summary: updateSummary, isExpanded: updateExpansion) {
                updateDetails
            }.accessibilityIdentifier("settings-updates-details")

            SettingsContentGroup(L("More app settings", "추가 앱 설정")) {
                SettingRow(title: L("Notifications", "알림"), detail: notificationSummary) {
                    Button(L("Details…", "세부 설정…")) { showNotifications = true }
                        .buttonStyle(.link).accessibilityLabel(L("Notification settings", "알림 세부 설정"))
                        .accessibilityIdentifier("settings-open-notifications")
                }
                SettingRow(title: L("Move settings", "설정 이동"),
                    detail: L("Reviewed imports stay inactive", "가져온 설정은 검토 후 비활성 사본으로 저장")) {
                    Button(L("Import / export…", "가져오기·내보내기…")) { showSettingsTransfer = true }
                        .buttonStyle(.link).accessibilityLabel(L("Import and export settings", "설정 가져오기·내보내기"))
                        .accessibilityIdentifier("settings-open-transfer")
                }
                SettingRow(title: L("Additional options", "추가 옵션"),
                    detail: L("Find timer, display and automation settings", "시간·화면·자동화 설정 찾기")) {
                    Button(L("Browse…", "모두 보기…")) { showAdditionalOptions = true }
                        .buttonStyle(.link).accessibilityLabel(L("Browse additional options", "추가 옵션 모두 보기"))
                        .accessibilityIdentifier("settings-open-additional-options")
                }
            }

            Note(L("Quitting ends Tether work and restores its changes. Ended timers do not restart.",
                   "앱을 종료하면 유지를 끝내고 자체 변경을 되돌립니다. 끝난 타이머는 다시 시작하지 않습니다."))

            SettingsDisclosure(title: L("Usage statistics", "사용 통계"),
                summary: L("Last 7 days", "최근 7일"), isExpanded: usageStatisticsExpansion) {
                UsageStatisticsView(model: model)
            }.accessibilityIdentifier("settings-usage-statistics-details")

            RecentActivityView(model: model)

            SettingsDisclosure(title: L("Other app keep-awake requests", "다른 앱의 잠자기 방지 요청"),
                summary: model.otherAppKeepAwakeSummary ?? L("Check when needed", "필요할 때 확인"),
                isExpanded: otherAppRequestsExpansion) {
                VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                    Note(L("Review currently observed requests. Installed or running apps are not automatically conflicts.",
                           "현재 관측한 요청을 확인합니다. 설치되었거나 실행 중이라는 이유만으로 충돌로 표시하지 않습니다."))
                    Button(L("Review requests…", "요청 확인…")) { model.presentActivityReview() }
                        .actionButton()
                        .accessibilityLabel(L("Review other app keep-awake requests", "다른 앱의 잠자기 방지 요청 확인"))
                        .accessibilityIdentifier("settings-review-sleep-influences")
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

            if model.showsLidOptions && !helperRequiresAttention {
                SettingsDisclosure(title: L("Closed-lid helper", "덮개 유지 도우미"),
                    summary: model.helperStatus.text, isExpanded: helperExpansion) {
                    helperDetails
                }.accessibilityIdentifier("settings-helper-details")
            }
            Text("Tether · \(AppModel.appDisplayVersion) (\(AppModel.appBuild))")
                .font(TetherTypography.secondary)
                .foregroundStyle(Color.tetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .toggleStyle(.switch)
        .sheet(isPresented: $showNotifications) {
            V4FeatureSheet(title: L("Notifications", "알림")) {
                Text(L("App-wide choices", "앱 전체에 적용"))
                    .font(TetherTypography.secondary).foregroundStyle(Color.tetherSecondary)
                NotificationSettingsView(model: model, monitor: model.notificationSettings)
            } actions: {
                Button(L("Back", "뒤로")) { showNotifications = false }
                    .actionButton().keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings-notifications-back")
                Spacer()
            }.accessibilityIdentifier("settings-notifications-sheet")
        }
        .sheet(isPresented: $showSettingsTransfer) { SettingsTransferView(model: model) }
        .sheet(isPresented: $showAdditionalOptions) { OptionCatalogView(model: model) }
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

    var activeRecordingStatus: DiagnosticRecordingStatusRow {
        DiagnosticRecordingStatusRow(model: model)
    }

    private func revealRequestedOtherAppDetails() {
        guard model.otherAppDetailsRequested else { return }
        otherAppRequestsExpansion.wrappedValue = true
        model.otherAppDetailsRequested = false
    }

    private var usageStatisticsExpansion: Binding<Bool> { disclosures?.usageStatistics ?? $usageStatisticsExpanded }
    private var otherAppRequestsExpansion: Binding<Bool> { disclosures?.otherAppRequests ?? $otherAppRequestsExpanded }
    private var diagnosticsExpansion: Binding<Bool> { disclosures?.diagnostics ?? $diagnosticsExpanded }
    private var updateExpansion: Binding<Bool> { disclosures?.updates ?? $updateOptionsExpanded }
    private var helperExpansion: Binding<Bool> { disclosures?.helper ?? $helperExpanded }
    private var notificationSummary: String {
        [model.notifySessionEnd ? L("Timer end on", "타이머 종료 켬") : L("Timer end off", "타이머 종료 꺼짐"),
         model.notifyExpiryWarning ? L("Warning on", "미리 알림 켬") : L("Warning off", "미리 알림 꺼짐")].joined(separator: " · ")
    }
    private var updateSummary: String {
        model.availableUpdate.map { L("\($0) available", "\($0) 사용 가능") } ?? updateCheckSummary
    }

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
            UpdateInstallationView(model: model)
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
