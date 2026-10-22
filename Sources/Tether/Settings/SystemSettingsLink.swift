import SwiftUI
import TetherCore

extension AppModel {
    var clamshellLockRequirementVisible: Bool {
        capabilities.lidControlAvailable && (clamshellActive || workSessionHolding)
    }
    var screenLockSettingTitle: String {
        switch systemSettings.currentScreenLock {
        case .off: L("Password requirement off", "자동 암호 요구 꺼짐")
        case .immediate: L("Password required immediately", "화면 꺼짐 후 즉시 암호 요구")
        case .after(let seconds): L("Password required after \(Texts.duration(Double(seconds)))", "화면 꺼짐 후 \(Texts.duration(Double(seconds))) 뒤 암호 요구")
        case .unavailable: systemSettings.reading ? L("Reading macOS settings…", "macOS 설정 확인 중…") : L("Password policy unavailable", "암호 요구 설정을 확인하지 못했습니다")
        }
    }
}

/// Work holding, macOS's password policy, and actual unlocked remote use are
/// different observations. A setting read is never an unlocked-session badge.
struct ClamshellLockNotice: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.clamshellLockRequirementVisible && model.systemSettings.currentScreenLock != .off {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 10) {
                    Label(L("Review macOS password requirements", "macOS 암호 요구 확인 필요"), systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.caption).foregroundStyle(Color.tetherWarning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L("Lock Screen…", "잠금 화면 설정…")) { model.open(.lockScreen) }
                        .buttonStyle(.borderless).font(.caption.weight(.medium)).fixedSize()
                        .disabled(model.userCommandsArePreview || model.developmentService)
                }
                Text(model.screenLockSettingTitle)
                    .font(.caption).foregroundStyle(Color.tetherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SystemLockSettingsCard: View {
    @ObservedObject var model: AppModel
    var body: some View {
        SettingsCard(title: L("macOS display & lock", "macOS 화면·잠금"), symbol: "lock.open") {
            SettingRow(title: L("Password after display sleep", "화면 꺼짐 후 암호 요구"), detail: model.screenLockSettingTitle) {
                Button(L("Lock Screen settings…", "잠금 화면 설정…")) { model.open(.lockScreen) }
                    .disabled(model.userCommandsArePreview || model.developmentService)
            }
            Note(L("This is the macOS password policy, not the current lock state. It does not confirm unlocked remote use. Tether does not change it.",
                   "현재 잠금 상태가 아닌 macOS의 암호 요구 설정입니다. 원격에서 잠금 없이 사용할 수 있다는 뜻이 아니며 Tether가 이를 변경하지 않습니다."))
            HStack {
                Text(L("Changes in System Settings are reflected here.", "시스템 설정에서 바꾸면 여기에도 반영됩니다."))
                    .font(.caption).foregroundStyle(Color.tetherSecondary)
                Spacer(minLength: 8)
                Button(L("Check again", "다시 확인")) { model.systemSettings.refresh(force: true) }
                    .disabled(model.systemSettings.reading || model.developmentService || model.userCommandsArePreview)
            }
        }
    }
}

struct LoginItemSystemNotice: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.launchAtLogin && model.systemSettings.value.loginItemDisabled == true {
            SettingRow(title: L("macOS blocks automatic launch", "macOS에서 자동 실행 차단됨"),
                       detail: L("The registration is retained. Review the system permission to enable it.", "등록은 유지되어 있습니다. 자동 실행을 허용하려면 시스템 권한을 확인하세요.")) {
                Button(L("Login Items…", "로그인 항목…")) { model.open(.loginItems) }
                    .disabled(model.userCommandsArePreview || model.developmentService)
            }
        } else if model.launchAtLogin && model.systemSettings.checkedAt != nil && model.systemSettings.value.loginItemDisabled == nil {
            Note(L("Registered for login. The macOS launch permission could not be confirmed.", "로그인 자동 실행은 등록되어 있으나 macOS의 차단 여부를 확인하지 못했습니다."))
        }
    }
}
