import SwiftUI
import TetherCore

struct SystemPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var updateOptionsExpanded = false
    @State private var showNotifications = false
    @State private var showSettingsTransfer = false
    @State private var showAdditionalOptions = false
    @State private var showMenuPreview = false

    var body: some View {
        SettingsForm {
            if updateRequiresAttention {
                updateAttentionSection
            }
            SettingsContentGroup(L("General", "일반")) {
                SettingsToggle(title: L("Launch at login", "로그인 시 시작"), isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .disabled(model.userCommandsArePreview || model.developmentService)
                LoginItemSystemNotice(model: model)
                SettingRow(title: L("Menu bar", "메뉴바"), showsAccessibleTitle: false) {
                    CompactPopUp(title: L("Menu bar display", "메뉴바 표시"), selection: $model.menuBarDetails,
                        choices: [PopupChoice(false, L("Icon only", "아이콘만")),
                            PopupChoice(true, L("Icon + time remaining", "아이콘 + 남은 시간"))],
                        identifier: "settings-menu-bar-display")
                        .disabled(!model.acceptingUserCommands || model.commandPending)
                }
                SettingRow(title: L("Language", "언어"), showsAccessibleTitle: false) {
                    CompactPopUp(title: L("Language", "언어"), selection: $model.language,
                        choices: [PopupChoice(LanguageChoice.system, L("Same as macOS", "macOS와 같게")),
                            PopupChoice(.korean, "한국어"), PopupChoice(.english, "English")],
                        identifier: "settings-language")
                        .disabled(model.userCommandsArePreview || model.developmentService)
                }
                if model.userCommandsArePreview || model.developmentService {
                    Button(L("Preview menu panel…", "메뉴 패널 보기…")) { showMenuPreview = true }
                        .popover(isPresented: $showMenuPreview) { TetherPanel(model: model) }
                }
            }

            SettingsContentGroup(L("Updates", "업데이트")) {
                SettingRow(title: updateSummary) { updateCheckButton }
                SettingsToggle(title: L("Check for updates automatically", "업데이트 자동 확인"), isOn: $model.checkUpdates)
                    .disabled(model.userCommandsArePreview || model.developmentService)
                SettingsDisclosure(title: L("Channel & Installation", "채널과 설치"),
                    isExpanded: updateExpansion, groupsSection: false) { updateDetails }
                    .accessibilityIdentifier("settings-updates-details")
            }

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

            Text("Tether · \(AppModel.appDisplayVersion) (\(AppModel.appBuild))")
                .font(TetherTypography.secondary)
                .foregroundStyle(Color.tetherSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
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

    }

    var activeRecordingStatus: DiagnosticRecordingStatusRow {
        DiagnosticRecordingStatusRow(model: model)
    }

    private var updateExpansion: Binding<Bool> { disclosures?.updates ?? $updateOptionsExpanded }
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
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.updateStatus.checking
                        ? L("Checking for updates…", "업데이트 확인 중…")
                        : L("Update in progress", "업데이트 진행 중"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var updateDetails: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            Text(L("Update channel and installation", "업데이트 채널과 설치"))
                .font(TetherTypography.section).accessibilityAddTraits(.isHeader)
            UpdateInstallationView(model: model)
            UpdateSettingsCard(model: model, includesOverview: false)
                .disabled(model.userCommandsArePreview)
        }
    }

    private var updateCheckButton: some View {
        Button(model.updateStatus.checking ? L("Checking…", "확인 중…")
            : model.availableUpdate == nil ? L("Check for Updates…", "업데이트 확인…") : L("View Update…", "업데이트 보기…")) {
            model.checkForUpdates(force: true)
        }
        .actionButton(prominent: model.availableUpdate != nil)
        .disabled(model.userCommandsArePreview || model.developmentService || model.updateStatus.checking || model.updateStatus.waitingForOpenLid)
    }

}
