import SwiftUI
import TetherCore

struct UpdateSettingsCard: View {
    @ObservedObject var model: AppModel
    var migration: MigrationReport?
    var includesOverview = true
    private var status: AppUpdateStatus { model.updateStatus }

    var body: some View {
        Group {
            if includesOverview {
                SettingsCard(title: L("Updates", "업데이트"), symbol: "arrow.down.circle") { settingsContent }
            } else {
                settingsContent
            }
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if includesOverview {
                SettingRow(title: "Tether \(AppModel.appDisplayVersion)", detail: L("Build \(AppModel.appBuild)", "빌드 \(AppModel.appBuild)")) {
                    Button(status.checking ? L("Checking…", "확인 중…") : model.availableUpdate == nil ? L("Check for Updates…", "업데이트 확인…") : L("View Update…", "업데이트 보기…")) { model.checkForUpdates(force: true) }
                        .disabled(model.developmentService || status.checking || status.waitingForOpenLid)
                }
                if status.waitingForOpenLid {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L("Installation paused", "설치 대기 중"), systemImage: "laptopcomputer")
                            .font(.callout.weight(.medium))
                        Note(L("Open your MacBook, finish your current work, then continue. Opening the lid alone will not install the update.", "MacBook을 열고 진행 중인 작업을 마친 뒤 계속해 주세요. 덮개를 열기만 해서는 설치하지 않습니다."))
                        Button(L("Continue Installation", "설치 계속")) { model.resumeUpdateInstallation() }
                    }
                } else if let error = status.error {
                    Note(L("Could not check or install the update. ", "업데이트 확인 또는 설치를 완료하지 못했습니다. ") + error)
                } else if let update = model.availableUpdate {
                    Label(L("\(update) is available", "새 버전 \(update)을 사용할 수 있습니다"), systemImage: "arrow.down.circle.fill")
                        .font(.callout).foregroundStyle(Color.tetherAccent)
                } else if let date = status.lastChecked {
                    Text(L("Last checked: ", "최근 확인: ") + date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(Color.tetherSecondary)
                }
                Divider()
            }
            SettingRow(title: L("Update channel", "업데이트 채널"), showsAccessibleTitle: false) {
                Picker(L("Update channel", "업데이트 채널"), selection: Binding(get: { model.updateChannel }, set: { model.setUpdateChannel($0) })) {
                    Text(L("Stable", "정식")).tag(UpdateChannel.stable)
                    Text(L("Stable + Beta", "정식 + 베타")).tag(UpdateChannel.beta)
                }.labelsHidden().frame(width: SettingsMetrics.controlWidth, alignment: .trailing)
                    .disabled(model.developmentService || status.sessionInProgress)
            }
            Note(model.updateChannel == .beta
                 ? L("Includes beta releases. Choose Stable to wait for the next stable release; your installed version will not be downgraded.", "베타도 함께 받습니다. 정식으로 바꾸면 현재 버전을 유지하고 더 새로운 정식 버전을 기다립니다.")
                 : L("Only stable releases are offered. Your installed version will not be downgraded.", "정식 배포만 받습니다. 이미 설치한 버전보다 이전 버전으로 되돌리지 않습니다."))
            if status.sessionInProgress {
                Note(L("Finish or dismiss the current update before changing channels. Use View Update to open it.", "채널 변경은 진행 중인 업데이트를 마치거나 업데이트 창에서 ‘나중에’를 선택한 뒤 가능합니다."))
            }
            if includesOverview {
                Divider()
                SettingsToggle(title: L("Check automatically each day", "하루에 한 번 자동 확인"), isOn: $model.checkUpdates).disabled(model.developmentService)
            }
            Note(model.capabilities.hardware == .portable
                ? L("Automatic checks show available updates in App settings. Installation requires your action and an open MacBook.", "자동 확인 결과는 앱 설정에 표시합니다. 직접 설치를 선택해야 하며 MacBook이 열려 있어야 합니다.")
                : L("Automatic checks show available updates in App settings. Installation requires your action.", "자동 확인 결과는 앱 설정에 표시합니다. 직접 설치를 선택해야 합니다."))
            Note(L("Existing settings are retained. A helper update may require administrator authorization.", "기존 설정은 유지됩니다. 전원 관리 도우미를 업데이트할 때 관리자 암호가 필요할 수 있습니다."))
            if let migration {
                Label(L("Previous settings migrated · backup retained", "이전 설정 복원 완료 · 백업 보관 중"), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(Color.tetherSuccess)
                if migration.toSchema >= 3 {
                    Note(L("Energy modes now follow macOS. Battery reserve and time settings were kept; old temperature cutoffs were backed up and retired.", "전원 모드는 macOS에 맡깁니다. 배터리 잔량·시간 설정은 유지하고, 이전 온도 제한은 백업 후 정리했습니다."))
                    if migration.cleared.contains("temperaturePolicyRequiresResume") {
                        Note(L("The upgrade stopped sessions that used explicit temperature cutoffs. Review the new protection policy before resuming.", "기존 온도 제한을 사용하던 세션은 업데이트 시 중단했습니다. 새 보호 기준을 확인한 뒤 다시 켜 주세요."))
                    }
                }
                if migration.frozeAdaptiveLimits {
                    Note(L("Battery reserve and duration were preserved as fixed limits.", "기존 자동 잔량·시간 한도는 이관 시점의 고정 한도로 보존했습니다."))
                }
            }
        }
    }
}
