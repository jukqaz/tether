import Foundation
import TetherCore

@MainActor
extension AppModel {
    /// Saves only the next manual request's options. Current requests and global
    /// display/lid permissions retain their independent owners and captured values.
    @discardableResult
    func saveManualDefaultsOptions(_ options: V4RequestOptions, expectedGeneration: UInt64) -> Bool {
        guard acceptingUserCommands, !commandPending, capabilities.generalIdleAvailable else {
            errorText = L("Manual defaults cannot be changed in the current app or device state.",
                          "현재 앱·기기 상태에서는 수동 작업 기본값을 바꿀 수 없습니다.")
            return false
        }
        var next = v4Settings
        guard next.generation == expectedGeneration else {
            errorText = L("Settings changed. Reopen this detail and review the current defaults before applying.",
                          "설정이 바뀌었습니다. 이 상세를 다시 열고 현재 기본값을 확인한 뒤 적용하세요.")
            return false
        }
        guard capabilities.lidControlAvailable || options.closedLid == next.nextManualOptions.closedLid else {
            errorText = L("Closed-lid control is not available on this Mac. Its saved choice was preserved.",
                          "이 Mac에서는 덮개를 제어할 수 없습니다. 저장된 선택은 보존했습니다.")
            return false
        }
        next.nextManualOptions = options
        return saveV4AutomaticRules(next)
    }
}
