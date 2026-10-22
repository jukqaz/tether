import SwiftUI
import TetherCore

struct SystemPage: View {
    @ObservedObject var model: AppModel
    @State private var lowPower: (battery: Int?, ac: Int?) = (nil, nil)
    @State private var checks: [HealthCheck] = []
    @State private var probed = false
    @State private var showMenuPreview = false
    @State private var confirmingRemoval = false
    @State private var migration: MigrationReport?
    @State private var showHelper = false

    var body: some View {
        SettingsScroll(title: L("App Settings", "앱 설정"), subtitle: L("Menu bar, language and updates.", "메뉴바 표시와 언어, 업데이트를 설정합니다.")) {
            if model.developmentService { PreviewNotice() }
            SettingsCard(title: L("General", "일반"), symbol: "slider.horizontal.3") {
                SettingsToggle(title: L("Open at login", "로그인하면 자동으로 열기"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })).disabled(model.developmentService)
                Divider()
                SettingsToggle(title: L("Show time and temperature in menu bar", "메뉴바에 남은 시간과 온도 표시"), isOn: $model.menuBarDetails)
                Divider()
                SettingRow(title: L("Menu bar panel", "메뉴바 메뉴")) {
                    Button(L("Preview…", "미리보기…")) { showMenuPreview = true }
                        .popover(isPresented: $showMenuPreview, arrowEdge: .trailing) { TetherPanel(model: model) }
                }
                Divider()
                SettingRow(title: L("Language", "언어")) {
                    Picker(L("Language", "언어"), selection: $model.language) {
                        Text(L("Same as macOS", "macOS와 같게")).tag(LanguageChoice.system)
                        Text("English").tag(LanguageChoice.english)
                        Text("한국어").tag(LanguageChoice.korean)
                    }.labelsHidden().frame(width: 150, alignment: .trailing)
                }
            }
            UpdateSettingsCard(model: model, migration: migration)
            ActivityReviewCard(model: model)
            SettingsCard(title: L("Troubleshooting", "문제 해결"), symbol: "wrench.and.screwdriver") {
                if model.usesUserSession {
                    Note(L("This Mac uses an app-owned work request; no administrator helper is required. Quit releases only Tether's request.", "이 Mac은 앱이 소유한 요청으로 작업을 유지합니다. 관리자 도우미가 필요하지 않으며, 종료하면 Tether의 요청만 해제합니다."))
                    if model.capabilities.hardware != .desktop {
                        Note(L("The battery or lid observation is incomplete. General idle sessions are available; closed-lid control is not confirmed.", "배터리 또는 덮개 정보를 확인하지 못했습니다. 일반 작업 유지가 가능하며 닫힌 덮개 제어는 아직 확인되지 않았습니다."))
                    }
                } else {
                DisclosureGroup(L("Power management helper", "전원 관리 도우미"), isExpanded: Binding(
                    get: { showHelper || model.problem != nil }, set: { showHelper = $0 })) {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingRow(title: L("Power management service", "전원 관리 서비스"), detail: L("Applies power rules while connected to the app. Quitting ends the hold.", "앱과 연결된 동안 전원 규칙을 적용합니다. 종료하면 유지를 해제합니다.")) {
                            StatusBadge(text: model.helperStatus.text, color: model.helperResponding ? .tetherMint : model.helperStatus.color)
                        }
                        Divider()
                        HStack {
                            if model.helperInstalled {
                                Button(model.helperOutdated ? L("Finish Update…", "업데이트 마무리…") : L("Reinstall…", "다시 설치…")) { model.installHelper() }
                                    .disabled(model.developmentService)
                            } else {
                                Button(L("Install Helper…", "도우미 설치…")) { model.installHelper() }
                                    .buttonStyle(.borderedProminent).tint(Color.tetherAction).disabled(model.developmentService)
                            }
                            Spacer()
                            Button(L("Show Log", "기록 보기")) { model.openLog() }
                        }
                        if let problem = model.problem { ProblemBanner(problem: problem, model: model, compact: false) }
                    }.padding(.top, 12)
                }
                }
                Divider()
                DisclosureGroup(L("Display, sleep and last action", "화면과 잠자기 상태")) {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingRow(title: L("Display setup", "화면 구성")) {
                            Text(model.snapshot.displayTopology.title).foregroundStyle(Color.tetherSecondary)
                        }
                        Button(L("Inspect displays & causes…", "화면 연결·원인 점검…")) { model.showActivityReview = true }
                        Divider()
                        if !model.usesUserSession {
                          SettingRow(title: L("Built-in display", "내장 디스플레이")) {
                            Text(model.status?.displaySleeping.map { $0 ? L("Asleep", "꺼짐으로 보고됨") : L("Awake", "켜짐으로 보고됨") } ?? L("Unknown", "확인 불가")).foregroundStyle(Color.tetherSecondary)
                        }
                        Divider()
                        }
                        SettingRow(title: L("Prevent sleep", "시스템 잠자기 방지")) {
                            Text(model.usesUserSession && model.userSessionStatus?.error != nil ? L("Unverified", "확인 필요") : model.workSessionHolding ? L("On", "켜짐") : L("Off", "꺼짐")).foregroundStyle(Color.tetherSecondary)
                        }
                        Divider()
                        SettingRow(title: L("Low Power Mode", "저전력 모드")) { Text(lowPowerText).foregroundStyle(Color.tetherSecondary) }
                        if let event = model.lastEventText {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L("Last action", "최근 동작")).font(.callout.weight(.medium))
                                Text(event).font(.caption).foregroundStyle(Color.tetherSecondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Note(L("A command being sent does not confirm physical sleep. Display and sleep observations are shown separately.", "macOS가 보고한 상태입니다. 실제 화면 전원 상태와 다를 수 있습니다."))
                    }.padding(.top, 12)
                }
                Divider()
                RecentActivityView(model: model)
                Divider()
                DisclosureGroup(L("Checks, logging and reports", "진단과 보고서")) {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.developmentService {
                            Note(L("Device checks are not run in this preview.", "미리보기에서는 실제 기기의 설치 상태를 점검하지 않습니다."))
                        } else if !probed {
                            Label(L("Checking…", "점검 중…"), systemImage: "ellipsis.circle").foregroundStyle(Color.tetherSecondary)
                        } else {
                            let problems = checks.filter { $0.result != .ok }
                            if problems.isEmpty, !checks.isEmpty {
                                Label(L("All \(checks.count) checks pass", "점검 \(checks.count)개 모두 정상"), systemImage: "checkmark.circle.fill").foregroundStyle(Color.tetherMint)
                            } else {
                                ForEach(problems, id: \.name) { check in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(check.name, systemImage: check.result == .failed ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                            .foregroundStyle(check.result == .failed ? Color.red : .orange)
                                        Note(check.detail)
                                    }
                                }
                            }
                        }
                        Divider()
                        DiagnosticControls(model: model)
                    }.padding(.top, 12)
                }
                Divider()
                DisclosureGroup(L("System settings, command line & removal", "고급 관리")) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Button(L("Battery Settings…", "배터리 설정…")) { model.open(.battery) }
                            Button(L("Login Items…", "로그인 항목…")) { model.open(.loginItems) }
                            Button("GitHub…") { NSWorkspace.shared.open(UpdateChecker.projectURL) }.disabled(model.developmentService)
                        }
                        SettingsToggle(title: L("Install tether command", "tether 명령 설치"), isOn: Binding(get: { model.cliInstalled }, set: { model.setCLIInstalled($0) })).disabled(model.developmentService)
                        Note(L("The watchdog checks every 30 seconds and releases the override after 90 seconds without a helper update, on either power source.", "감시 장치는 30초마다 확인하며, 도우미가 90초 동안 보고하지 않으면 전원 종류와 관계없이 시스템 잠자기 방지를 해제합니다."))
                        Divider()
                        HStack {
                            Button(L("Remove Helper…", "도우미 제거…"), role: .destructive) { model.uninstallHelper() }.disabled(model.developmentService || !model.helperInstalled)
                            Spacer()
                            Button(L("Uninstall Tether…", "Tether 완전히 제거…"), role: .destructive) { confirmingRemoval = true }.disabled(model.developmentService)
                        }
                        Note(L("Full removal clears settings and logs, restores normal sleep, and moves the app to the Trash.", "완전히 제거하면 설정·기록을 지우고 잠자기 설정을 복원한 뒤 앱을 휴지통으로 옮깁니다."))
                    }.padding(.top, 16)
                }
            }
        }
        .toggleStyle(.switch).controlSize(.regular)
        .confirmationDialog(L("Uninstall Tether completely?", "Tether를 완전히 제거할까요?"), isPresented: $confirmingRemoval) {
            Button(L("Uninstall", "제거"), role: .destructive) { model.uninstallEverything() }
            Button(L("Cancel", "취소"), role: .cancel) {}
        } message: { Text(L("Your administrator password is needed once. Your Mac goes back to normal sleep.", "관리자 암호를 한 번 입력해야 해요. Mac은 원래의 잠자기 동작으로 돌아가요.")) }
        .task {
            if model.developmentService { return }
            if model.protection?.blockReason != "migrationFailed", JSONFile.read(Control.self, from: TetherPaths.controlPath)?.schemaVersion == Control.currentSchema {
                migration = JSONFile.read(MigrationReport.self, from: TetherPaths.supportDirectory + "/migration-report.json")
            }
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) {
                    (SystemProbe.lowPowerModes(), HealthChecks.run())
                }.value
                guard !Task.isCancelled else { return }
                lowPower = result.0; checks = result.1
                probed = true
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var lowPowerText: String {
        if model.developmentService { return L("Not checked", "조회하지 않음") }
        func text(_ value: Int?) -> String { value.map { $0 == 1 ? L("On", "켜짐") : ($0 == 2 ? L("Off · High Power", "꺼짐 · 고성능") : L("Off", "꺼짐")) } ?? "–" }
        return L("Battery \(text(lowPower.battery)) · Power \(text(lowPower.ac))", "배터리 \(text(lowPower.battery)) · 전원 \(text(lowPower.ac))")
    }
}
