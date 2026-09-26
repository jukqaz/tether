import Foundation
import TetherCore

let wantsJSON = arguments.contains("--json")
if arguments.first == "run" {
    run(Array(arguments.dropFirst()))
}
if arguments.first == "diagnose" {
    diagnose(Array(arguments.dropFirst()))
}

let words = arguments.filter { !$0.hasPrefix("-") }

if arguments.contains("--help") || arguments.contains("-h") || words.first == "help" {
    print(usageText)
    exit(0)
}

guard let command = TetherCommand.parse(words) else {
    if words.first == "hold" {
        fail(L("Give a time between 1 minute and 4 hours, e.g. tether hold 1h30m", "시간을 1분에서 4시간 사이로 적어 주세요. 예: tether hold 1h30m"), code: 2)
    }
    fail(L("Unknown command: \(words.joined(separator: " "))\n\n\(usageText)", "알 수 없는 명령입니다: \(words.joined(separator: " "))\n\n\(usageText)"), code: 2)
}

let state = State()
switch command {
case .status:
    printStatus(state, json: wantsJSON)

case .on, .off, .toggle:
    requireHelper(state)
    let on = command == .toggle ? !state.control.enabled : command == .on
    let after = change { ControlStore.setEnabled(on) }
    if on {
        print(after.clamshell ? L("Tether is on. Closing the lid won't sleep the Mac.", "Tether를 켰습니다. 덮개를 닫아도 잠들지 않습니다.")
                              : L("Tether is on. Clamshell mode starts when power is connected.", "Tether를 켰습니다. 전원을 연결하면 클램쉘 모드가 켜집니다."))
    } else {
        print(after.snapshot.lidClosed ? L("Tether is off. The lid is closed, so the Mac is going to sleep.", "Tether를 껐습니다. 덮개가 닫혀 있어 Mac이 잠듭니다.")
                                       : L("Tether is off until power is connected again. Closing the lid will sleep the Mac.",
                                           "전원을 다시 연결할 때까지 Tether를 껐습니다. 이제 덮개를 닫으면 잠듭니다."))
    }

case .sleep:
    requireHelper(state)
    // Let the Return key (or a hand on the trackpad) settle: input right after the request
    // cancels the sleep.
    let settleBy = Date().addingTimeInterval(3)
    while !UserInput.settled(), Date() < settleBy { usleep(100_000) }
    guard ControlStore.sleepNow() else { fail(cannotWrite) }
    print(L("Putting the Mac to sleep.", "Mac을 잠재웁니다."))

case .hold(let minutes):
    requireHelper(state)
    guard state.control.enabled else { fail(L("Tether is off. Run 'tether on' first.", "Tether가 꺼져 있습니다. 먼저 'tether on'을 실행해 주세요.")) }
    let percent = state.status?.batteryPercent ?? SystemProbe.batteryPercent()
    guard SafetyPolicy.canStartHold(batteryPercent: percent, user: state.control.limits) else {
        let floor = SafetyPolicy.floor(state.control.limits)
        fail(L("The battery is at \(percent ?? 0)%, at or under the \(floor)% floor, so a hold would end at once.",
               "배터리가 \(percent ?? 0)%로 하한선 \(floor)% 이하라 유지해도 바로 끝납니다."))
    }
    let after = change { ControlStore.startHold(minutes: minutes, source: "cli") }
    guard let until = after.status?.batteryHoldUntil else {
        fail(L("The helper didn't take the battery hold. Check 'tether status'.", "도우미가 배터리 유지를 받지 않았습니다. 'tether status'로 상태를 확인해 주세요."))
    }
    let floor = SafetyPolicy.floor(after.control.limits)
    print(L("Staying awake on battery until \(time(until)). It sleeps sooner if it gets hot or the battery reaches \(floor)%.",
            "배터리에서도 \(time(until))까지 유지합니다. 뜨거워지거나 배터리가 \(floor)%가 되면 먼저 잠듭니다."))

case .cancelHold:
    requireHelper(state)
    let after = change { ControlStore.cancelHold() }
    let sleeping = after.snapshot.power == .battery && after.snapshot.lidClosed
    print(sleeping ? L("Battery hold ended. The lid is closed, so the Mac is going to sleep.", "배터리 유지를 껐습니다. 덮개가 닫혀 있어 Mac이 잠듭니다.")
                   : L("Battery hold ended.", "배터리 유지를 껐습니다."))
}
