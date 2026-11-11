import SwiftUI
import TetherCore

extension AppModel {
    var screenLockSettingTitle: String {
        switch systemSettings.currentScreenLock {
        case .off: L("Password requirement off", "자동 암호 요구 꺼짐")
        case .immediate: L("Password required immediately", "화면 꺼짐 후 즉시 암호 요구")
        case .after(let seconds): L("Password required after \(Texts.duration(Double(seconds)))", "화면 꺼짐 후 \(Texts.duration(Double(seconds))) 뒤 암호 요구")
        case .unavailable: systemSettings.reading ? L("Reading macOS settings…", "macOS 설정 확인 중…") : L("Password policy unavailable", "암호 요구 설정을 확인하지 못했습니다")
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
