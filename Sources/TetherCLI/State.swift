import Foundation
import TetherCore

struct State {
    let installed = FileManager.default.fileExists(atPath: TetherPaths.helperPlistPath)
    let status = JSONFile.read(Status.self, from: TetherPaths.statusPath)
    let usage = JSONFile.read(Usage.self, from: TetherPaths.usagePath)
    let control = ControlStore.read()
    let snapshot = SystemProbe.snapshot()

    var responding: Bool {
        guard let status else { return false }
        return Date().timeIntervalSince1970 - status.updatedAt < 90
    }

    var clamshell: Bool { responding && control.enabled && snapshot.sleepDisabled }

    /// The battery-hold limits the helper enforces, auto-adjust included.
    var limits: UserLimits? { control.limitsInForce(UsageSummary(usage, now: Date())) }
}

func requireHelper(_ state: State) {
    guard SystemProbe.isSupportedMac else {
        fail(L("This Mac has no built-in battery or lid, so Tether's rules don't apply.",
               "이 Mac에는 내장 배터리나 덮개가 없어 Tether 규칙이 적용되지 않습니다."))
    }
    guard state.installed else {
        fail(L("The helper isn't installed. Install it from Tether in the menu bar.",
               "도우미가 설치되지 않았습니다. 메뉴바의 Tether에서 설치해 주세요."))
    }
    guard state.responding else {
        fail(L("The helper isn't responding. Reinstall it from Tether's settings.",
               "도우미가 응답하지 않습니다. Tether 설정에서 도우미를 다시 설치해 주세요."))
    }
}

/// Writes the control file, then waits briefly for the helper to apply it.
@discardableResult
func change(_ body: () -> Bool) -> State {
    let before = Date().timeIntervalSince1970
    guard body() else { fail(cannotWrite) }
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if let status = JSONFile.read(Status.self, from: TetherPaths.statusPath), status.updatedAt >= before { break }
        usleep(100_000)
    }
    return State()
}
