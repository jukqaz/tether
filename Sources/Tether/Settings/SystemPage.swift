import AppKit
import SwiftUI
import TetherCore

struct SystemPage: View {
    @ObservedObject var model: AppModel
    var disclosures: Binding<SettingsDisclosureState>? = nil
    @State private var updateOptionsExpanded = false
    @State private var notificationsExpanded = false
    @State private var advancedExpanded = false
    @State private var showSettingsTransfer = false
    @State private var showCommandLineGuide = false
    @State private var showEventActions = false
    @State private var showMenuPreview = false
    @State private var appDetailsExpanded = false

    var body: some View {
        SettingsForm {
            if updateRequiresAttention {
                updateAttentionSection
            }
            SettingsContentGroup(L("Startup & Appearance", "시작과 표시")) {
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

            SettingsDisclosure(title: L("Notifications", "알림"),
                summary: notificationSummary, isExpanded: notificationExpansion) {
                NotificationSettingsView(model: model, monitor: model.notificationSettings)
            }.accessibilityIdentifier("settings-notifications-details")

            SettingsContentGroup(L("Updates", "업데이트")) {
                SettingRow(title: updateSummary) { updateCheckButton }
                SettingsToggle(title: L("Check for updates automatically", "업데이트 자동 확인"), isOn: $model.checkUpdates)
                    .disabled(model.userCommandsArePreview || model.developmentService)
                SettingsDisclosure(title: L("Installation Details", "설치 안내"),
                    isExpanded: updateExpansion, groupsSection: false,
                    identifier: "settings-updates-details") { updateDetails }
                    .accessibilityIdentifier("settings-updates-details")
            }

            SettingsDisclosure(title: L("Advanced Integrations", "고급 연동"), isExpanded: advancedExpansion,
                identifier: "settings-app-advanced-details") {
                SettingRow(title: L("Command-line control", "명령으로 제어"),
                    detail: L("Start, extend or end manual keep-awake with the supported CLI and URLs", "지원되는 CLI·URL로 수동 유지를 시작·연장·종료합니다")) {
                    Button(L("Usage…", "사용 방법…")) { showCommandLineGuide = true }
                        .buttonStyle(.link).accessibilityIdentifier("settings-open-command-guide")
                }
                SettingRow(title: L("Work event actions", "작업 이벤트 연동"),
                    detail: L("Send configured HTTPS webhooks on confirmed work events", "확인된 작업 이벤트에 설정한 HTTPS Webhook을 보냅니다")) {
                    Button(L("Configure…", "설정…")) { showEventActions = true }
                        .buttonStyle(.link).accessibilityIdentifier("settings-open-event-actions")
                }
                SettingRow(title: L("Import and export settings", "설정 가져오기·내보내기"),
                    detail: L("Imports are saved as inactive copies after review", "검토 후 자동 실행하지 않는 사본으로 저장")) {
                    Button(L("Import / export…", "가져오기·내보내기…")) { showSettingsTransfer = true }
                        .buttonStyle(.link).accessibilityLabel(L("Import and export settings", "설정 가져오기·내보내기"))
                        .accessibilityIdentifier("settings-open-transfer")
                }
            }.accessibilityIdentifier("settings-app-advanced-details")

            SettingsDisclosure(title: L("About Tether", "앱 정보"),
                summary: AppModel.appDisplayVersion, isExpanded: appDetailsExpansion) {
                Note(L("Quitting ends Tether keep-awake and restores its power and display changes. Saved preferences are retained. Ended manual keep-awake will not restart.",
                       "앱을 종료하면 Tether 유지를 끝내고 변경한 전원·화면 상태를 복원합니다. 저장한 환경설정은 유지하며, 종료된 수동 유지는 다시 시작하지 않습니다."))
                Text("Tether · \(AppModel.appDisplayVersion) (\(AppModel.appBuild))")
                    .font(TetherTypography.secondary)
                    .foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.accessibilityIdentifier("settings-app-behavior-details")
        }
        .sheet(isPresented: $showSettingsTransfer) { SettingsTransferView(model: model) }
        .sheet(isPresented: $showCommandLineGuide) { CommandLineControlGuideView() }
        .sheet(isPresented: $showEventActions) { LifecycleOptionsView(model: model) }

    }

    var activeRecordingStatus: DiagnosticRecordingStatusRow {
        DiagnosticRecordingStatusRow(model: model)
    }

    private var updateExpansion: Binding<Bool> { disclosures?.updates ?? $updateOptionsExpanded }
    private var notificationExpansion: Binding<Bool> { disclosures?.notifications ?? $notificationsExpanded }
    private var advancedExpansion: Binding<Bool> { disclosures?.appAdvanced ?? $advancedExpanded }
    private var appDetailsExpansion: Binding<Bool> { disclosures?.appBehavior ?? $appDetailsExpanded }
    private var notificationSummary: String {
        [model.notifySessionEnd ? L("Time-expiry notice on", "시간 만료 알림 켬") : L("Time-expiry notice off", "시간 만료 알림 꺼짐"),
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

/// Displayed examples are parsed by the same side-effect-free command parser
/// as the CLI and URL entry points. This guide only copies text.
struct CommandLineGuideExample: Identifiable {
    let id: String
    let title: String
    let detail: String
    let words: [String]

    var urlString: String { "tether://" + words.joined(separator: "/") }

    func commandLine(executable: URL) -> String {
        let quotedPath = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ([quotedPath] + words).joined(separator: " ")
    }
}

enum CommandLineControlGuide {
    static func executable(in appBundle: URL) -> URL {
        appBundle.appendingPathComponent("Contents/Helpers/tether")
    }

    static var examples: [CommandLineGuideExample] {
        [
            .init(id: "status", title: L("Read current state", "현재 상태 확인"),
                  detail: L("Reads state without changing settings or keep-awake.", "상태만 읽으며 설정이나 유지를 바꾸지 않습니다."), words: ["status"]),
            .init(id: "manual-start", title: L("Start for 30 minutes", "30분 시작"),
                  detail: L("Current power, battery and protection limits still apply.", "현재 전원·배터리·보호 한도를 따릅니다."), words: ["manual", "30m"]),
            .init(id: "manual-extend", title: L("Extend by 15 minutes", "15분 연장"),
                  detail: L("The whole extension must be allowed for the active manual session.", "진행 중인 수동 유지에 15분 전체 연장이 허용되어야 합니다."), words: ["manual", "+15m"]),
            .init(id: "manual-end", title: L("End manual keep-awake", "수동 유지 종료"),
                  detail: L("Ends manual work only. Automatic work may continue.", "수동 유지에만 적용합니다. 자동 유지는 계속될 수 있습니다."), words: ["manual", "off"])
        ]
    }
}

@MainActor
struct CommandLineControlGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showURLs = false
    @State private var showScope = false

    private var executable: URL { CommandLineControlGuide.executable(in: Bundle.main.bundleURL) }

    var body: some View {
        V4FeatureSheet(title: L("Command-line Control", "명령으로 제어")) {
            Note(L("Open this version of Tether first. Copy a command into Terminal to use it.",
                   "같은 버전의 Tether를 먼저 실행하세요. 명령을 복사해 터미널에서 사용합니다."))
            ForEach(CommandLineControlGuide.examples) { example in
                VStack(alignment: .leading, spacing: 6) {
                    SettingRow(title: example.title, detail: example.detail) {
                        Button(L("Copy", "복사")) { copy(example.commandLine(executable: executable)) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("command-guide-copy-\(example.id)")
                    }
                    code(example.commandLine(executable: executable))
                }
            }
            SettingsDisclosure(title: L("Control with URLs", "URL로 제어"),
                isExpanded: $showURLs, groupsSection: false) {
                Note(L("Open a copied URL from Shortcuts or another tool to send the same command.",
                       "복사한 URL을 단축어나 다른 도구에서 열어 같은 명령을 보낼 수 있습니다."))
                ForEach(CommandLineControlGuide.examples) { example in
                    VStack(alignment: .leading, spacing: 6) {
                        SettingRow(title: example.title) {
                            Button(L("Copy URL", "URL 복사")) { copy(example.urlString) }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("command-guide-url-\(example.id)")
                        }
                        code(example.urlString)
                    }
                }
            }.accessibilityIdentifier("command-guide-url-details")
            SettingsDisclosure(title: L("Scope & Help", "사용 범위와 도움말"),
                isExpanded: $showScope, groupsSection: false) {
                Note(L("Commands control manual work in the running app. An external process ending does not automatically end it. Power and protection limits still apply; ended manual work does not restart.",
                       "실행 중인 앱의 수동 유지를 제어합니다. 외부 프로세스가 끝났다는 이유로 자동 종료되지 않습니다. 전원·보호 한도는 계속 적용되며 종료된 수동 유지는 다시 시작하지 않습니다."))
                SettingRow(title: L("Full command help", "전체 명령 도움말")) {
                    Button(L("Copy help command", "도움말 명령 복사")) {
                        copy(CommandLineGuideExample(id: "help", title: "", detail: "", words: ["--help"])
                            .commandLine(executable: executable))
                    }.buttonStyle(.bordered)
                }
            }.accessibilityIdentifier("command-guide-scope-details")
        } actions: {
            Button(L("Done", "닫기")) { dismiss() }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("command-guide-close")
            Spacer()
        }
        .accessibilityIdentifier("settings-command-guide-sheet")
    }

    private func code(_ value: String) -> some View {
        Text(value).font(TetherTypography.settingsBody.monospaced())
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
