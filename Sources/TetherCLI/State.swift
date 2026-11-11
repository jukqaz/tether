import Foundation
import TetherCore

struct State {
    let installed: Bool
    let status: Status?
    let usage: Usage?
    let control: Control
    let snapshot: Snapshot
    init() {
        let development = TetherPaths.serviceSocket != TetherPaths.productionSocket
        let reply = try? ServiceClient().perform(ServiceRequest(.snapshot))
        installed = reply != nil || (!development && FileManager.default.fileExists(atPath: TetherPaths.helperPlistPath))
        var observed = reply?.status ?? (development ? nil : JSONFile.read(Status.self, from: TetherPaths.statusPath))
        if let protection = reply?.protection { observed?.protection = protection }
        status = observed
        control = reply?.control ?? (development ? Control(enabled: false) : ControlStore.read())
        usage = development ? nil : JSONFile.read(Usage.self, from: TetherPaths.usagePath)
        if development, let observed {
            snapshot = Snapshot(power: observed.power, lidClosed: observed.lidClosed, sleepDisabled: observed.sleepDisabled)
        } else { snapshot = SystemProbe.snapshot() }
    }

    var responding: Bool {
        guard let status else { return false }
        return Date().timeIntervalSince1970 - status.updatedAt < 90
    }

    var clamshell: Bool { responding && control.enabled && status?.protection?.blockReason == nil && snapshot.sleepDisabled && Policy.wantsClamshell(snapshot, enabled: control.enabled, sleepNowPending: false, batteryHold: status?.batteryHoldUntil != nil, condition: control.condition) }

    /// The explicit battery-hold limits the helper enforces.
    var limits: UserLimits? { control.limits }
}

func requireHelper(_ state: State) {
    guard SystemProbe.isSupportedMac || (TetherPaths.serviceSocket != TetherPaths.productionSocket && state.status?.protection?.dryRun == true) else {
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
    guard body() else { fail(cannotWrite) }
    // The service replies after applying this request, so another client's status timestamp
    // can no longer be mistaken for our acknowledgement.
    return State()
}
