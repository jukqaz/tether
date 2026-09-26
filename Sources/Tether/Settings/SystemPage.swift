import SwiftUI
import TetherCore

struct SystemPage: View {
    @ObservedObject var model: AppModel
    @State private var lowPower: (battery: Int?, ac: Int?) = (nil, nil)
    @State private var blockers: [SleepBlocker] = []
    @State private var checks: [HealthCheck] = []
    @State private var confirmingRemoval = false

    var body: some View {
        Page {
            Section {
                LabeledContent(L("Status", "상태")) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.helperStatus.color)
                            .frame(width: 8, height: 8)
                        Text(model.helperStatus.text)
                    }
                }
                HStack {
                    if model.helperInstalled {
                        Button(L("Reinstall…", "다시 설치…")) { model.installHelper() }
                        Button(L("Remove…", "제거…"), role: .destructive) { model.uninstallHelper() }
                    } else {
                        Button(L("Install…", "설치…")) { model.installHelper() }
                    }
                    Spacer()
                    Button(L("Show Log", "기록 보기")) { model.openLog() }
                }
            } header: {
                Text(L("Helper", "도우미"))
            } footer: {
                Note(L("The helper runs with administrator rights and keeps the power rules even while the app is closed. Remove it here so “prevent sleep” is turned back off.",
                       "도우미는 관리자 권한으로 돌며, 앱이 꺼져 있어도 전원 규칙을 지켜요. 지울 때는 여기서 제거해야 잠자기 금지가 풀려요."))
            }

            Section {
                LabeledContent(L("Prevent sleep", "잠자기 금지")) {
                    Text(model.snapshot.sleepDisabled ? L("on", "켜짐") : L("off", "꺼짐"))
                }
                LabeledContent(L("Low Power Mode", "저전력 모드")) {
                    HStack(spacing: 8) {
                        Text(lowPowerText)
                        Button(L("Battery Settings…", "배터리 설정…")) { model.open(.battery) }
                    }
                }
                LabeledContent(L("Keep-screen-on request", "화면 켜 둠 요청")) {
                    Text(model.holdsDisplayAwake ? L("active", "사용 중") : L("inactive", "사용 안 함"))
                }
                LabeledContent(L("Background items (3)", "백그라운드 항목 3개")) {
                    Button(L("Open Login Items…", "로그인 항목 열기…")) { model.open(.loginItems) }
                }
            } header: {
                Text(L("What Tether Changes", "Tether가 바꾸는 시스템 설정"))
            } footer: {
                Note(L("“Prevent sleep” is a hidden setting, on only while power is connected, and not shown in System Settings. Low Power Mode is switched on only in the cases chosen in Safety, then restored. The keep-screen-on request shows in Activity Monitor › Energy. A small watchdog checks every minute that sleep is never left off on battery should the helper stop. Sleep and display timers, the lock password, the screen saver and input sources are never changed.",
                       "잠자기 금지는 전원이 연결돼 있을 때만 켜는 숨은 값이라 설정 앱에는 없어요. 저전력 모드는 배터리와 발열 설정에서 고른 경우에만 잠깐 켜고 원래 값으로 돌려요. 화면 켜 둠 요청은 활동 모니터 › 에너지에 보여요. 작은 감시 장치가 1분마다 확인해서, 도우미가 멈춰도 배터리에서 잠자기 금지가 남지 않게 해요. 잠자기·화면 끄기 타이머, 잠금 암호, 화면 보호기, 입력 소스는 바꾸지 않아요."))
            }

            Section {
                if blockers.isEmpty {
                    Text(L("No other app is keeping the Mac awake.", "지금 잠을 막는 다른 앱이 없어요."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(blockers.enumerated()), id: \.offset) { _, b in
                        LabeledContent {
                            Text(b.reason.isEmpty ? Texts.blockerKind(b.kind) : "\(b.reason) · \(Texts.blockerKind(b.kind))")
                                .foregroundStyle(.secondary)
                        } label: {
                            Text(b.process)
                        }
                    }
                }
            } header: {
                Text(L("Apps Keeping the Mac Awake", "잠을 막는 앱"))
            } footer: {
                Note(L("Apps can hold off idle sleep, on battery too; that's what an AI app's “prevent sleep” setting does. Closing the lid and Tether's own sleep still win, but with the lid open on battery the Mac stays awake and drains.",
                       "앱은 배터리일 때도 '입력이 없어 잠드는 것'을 막을 수 있어요. AI 앱의 '절전 방지' 설정이 이런 방식이에요. 덮개를 닫거나 Tether가 재우는 것은 막지 못하지만, 배터리로 덮개를 열어 둔 채 두면 Mac이 깨어 있어 배터리가 닳아요."))
            }

            Section {
                let problems = checks.filter { $0.result != .ok }
                if problems.isEmpty, !checks.isEmpty {
                    Label(L("All \(checks.count) checks pass", "점검 \(checks.count)개 모두 정상"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(problems, id: \.name) { check in
                        LabeledContent {
                            Text(check.detail).foregroundStyle(.secondary)
                        } label: {
                            Label(check.name, systemImage: check.result == .failed ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(check.result == .failed ? Color.red : Color.orange)
                        }
                    }
                }
                Toggle(L("Detailed logging", "자세한 기록 남기기"),
                       isOn: Binding(get: { model.debugLogging }, set: { model.setDebugLogging($0) }))
                    .disabled(!model.helperInstalled)
                HStack(spacing: 8) {
                    Button(L("Create Report…", "보고서 만들기…")) { model.createDiagnosticReport() }
                    Button(L("Copy Report", "보고서 복사")) { model.createDiagnosticReport(copy: true) }
                    if model.diagnosticsBusy {
                        ProgressView().controlSize(.small)
                    } else if let note = model.reportNote {
                        Text(note).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .disabled(model.diagnosticsBusy)
            } header: {
                Text(L("Diagnostics", "진단"))
            } footer: {
                Note(L("If something goes wrong, turn on detailed logging, make it happen again, then create a report for an issue or an AI assistant. It's a Markdown file on your Desktop with the settings, recent sleeps and logs; your user name and the Mac's name are masked, and nothing is sent anywhere. In Terminal: tether diagnose --record",
                       "문제가 생기면 자세한 기록을 켜고 문제를 다시 일으킨 뒤 보고서를 만들어 이슈나 AI 도우미에게 주세요. 설정, 최근 잠자기 기록, 로그가 담긴 Markdown 파일이 바탕화면에 저장되고, 사용자·Mac 이름은 가려지며 어디에도 전송되지 않아요. 터미널에서는 tether diagnose --record"))
            }

            Section {
                LabeledContent(L("Version", "버전")) {
                    Text("v\(AppModel.appVersion)")
                }
                Toggle(L("Check for updates automatically", "업데이트 자동 확인"), isOn: $model.checkUpdates)
                HStack {
                    if let update = model.availableUpdate {
                        Label(L("Tether \(update) is available", "Tether \(update)이(가) 나왔어요"), systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(Color.tetherMint)
                        Spacer()
                        Button(L("Download…", "받기…")) { model.openReleases() }
                    } else {
                        Button(L("Check Now", "지금 확인")) { model.checkForUpdates(force: true) }
                        Spacer()
                        Button(L("GitHub…", "GitHub…")) { NSWorkspace.shared.open(UpdateChecker.projectURL) }
                    }
                }
            } header: {
                Text(L("Updates", "업데이트"))
            } footer: {
                Note(L("Once a day Tether asks GitHub for the latest release; nothing else is sent.",
                       "하루에 한 번 GitHub에 최신 릴리스만 물어봐요. 다른 정보는 보내지 않아요."))
            }

            Section {
                HStack {
                    Spacer()
                    Button(L("Uninstall Tether…", "Tether 완전히 제거…"), role: .destructive) { confirmingRemoval = true }
                }
            } footer: {
                Note(L("Removes the helper (turning “prevent sleep” back off), its files and logs, the login item, the tether command and preferences, then moves the app to the Trash.",
                       "도우미(잠자기 금지 해제 포함), 설정·기록 파일, 로그인 항목, tether 명령, 환경설정을 지우고 앱을 휴지통으로 옮겨요."))
            }
        }
        .confirmationDialog(L("Uninstall Tether completely?", "Tether를 완전히 제거할까요?"), isPresented: $confirmingRemoval) {
            Button(L("Uninstall", "제거"), role: .destructive) { model.uninstallEverything() }
            Button(L("Cancel", "취소"), role: .cancel) {}
        } message: {
            Text(L("Your administrator password is needed once. Your Mac goes back to normal sleep.",
                   "관리자 암호를 한 번 입력해야 해요. Mac은 원래의 잠자기 동작으로 돌아가요."))
        }
        .task {
            // Only while this page is visible.
            while !Task.isCancelled {
                lowPower = SystemProbe.lowPowerModes()
                blockers = model.sleepBlockers()
                checks = HealthChecks.run()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var lowPowerText: String {
        func text(_ value: Int?) -> String { value.map { $0 == 1 ? L("on", "켜짐") : L("off", "꺼짐") } ?? "–" }
        var line = L("battery \(text(lowPower.battery)) · power \(text(lowPower.ac))", "배터리 \(text(lowPower.battery)) · 전원 \(text(lowPower.ac))")
        if model.heatGuardActive {
            line += L(" (heat guard)", " (발열 보호)")
        } else if model.holdingOnBattery {
            line += L(" (battery hold)", " (배터리 유지)")
        }
        return line
    }
}
