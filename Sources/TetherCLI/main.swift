import Foundation
import TetherCore

let wantsJSON = arguments.contains("--json")
if arguments.first == "run" { performRunCommand(arguments) }
if arguments.first == "displays", !arguments.contains("--help") {
    let report = DisplayProbe.inspect()
    if wantsJSON {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { print(String(decoding: try encoder.encode(report), as: UTF8.self)) }
        catch { fail("Could not encode display observations") }
    }
    else {
        print(report.summary)
        print(report.guidance)
        for display in report.displays {
            print("\(display.name): \(display.detail)\n  \(display.evidence)")
        }
        if let issue = report.issue { print(issue) }
    }
    exit(report.graphicsAvailable ? 0 : 1)
}
if arguments.first == "diagnose" {
    if arguments.contains("--snapshot-json") {
        guard arguments == ["diagnose", "--snapshot-json"] else {
            fail("Usage: tether diagnose --snapshot-json", code: 2)
        }
        printPhysicalEvidence()
    }
    diagnose(Array(arguments.dropFirst()))
}
if arguments.first == "doctor" {
    doctor()
}

let words = arguments.filter { !$0.hasPrefix("-") }

if arguments.contains("--help") || arguments.contains("-h") || words.first == "help" {
    print(usageText)
    exit(0)
}

if arguments.first == "task" { performTaskCommand(arguments) }
if arguments.first == "manual", arguments.contains("--pid") { performManualPIDCommand(arguments) }

guard let command = TetherCommand.parse(words) else {
    if words.first == "hold" {
        fail(L("Give a time between 1 and 120 minutes, e.g. tether hold 1h30m", "시간을 1분에서 120분 사이로 적어 주세요. 예: tether hold 1h30m"), code: 2)
    }
    fail(L("Unknown command: \(words.joined(separator: " "))\n\n\(usageText)", "알 수 없는 명령입니다: \(words.joined(separator: " "))\n\n\(usageText)"), code: 2)
}

// Legacy helper fixtures remain isolated to an explicitly private helper socket.
// Production commands go through the running app and never become a second writer.
let legacyFixture = TetherPaths.serviceSocket != TetherPaths.productionSocket
if !legacyFixture {
    guard arguments.filter({ $0.hasPrefix("-") }).allSatisfy({ $0 == "--json" }) else {
        fail(L("Unsupported command option.", "지원하지 않는 명령 옵션입니다."), code: 2)
    }
    do {
        let reply = try userSessionClient().perform(command)
        printUserSession(reply, command: command, json: wantsJSON)
        exit(0)
    } catch let error as UserSessionFailure where command == .status && error.code == "appUnavailable" {
        // Read-only legacy diagnostics can still explain why the app is unavailable.
    } catch { fail(error.localizedDescription) }
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
                              : L("Tether is on. The selected power condition controls clamshell mode.", "Tether를 켰습니다. 선택한 전원 조건에 따라 클램쉘 모드가 작동합니다."))
    } else {
        print(L("Tether is off until you turn it on again. macOS and other apps still control their own sleep behavior.",
                "다시 켤 때까지 Tether를 껐습니다. macOS와 다른 앱의 잠자기 동작은 계속 적용됩니다."))
    }

case .sleep:
    requireHelper(state)
    // Let the Return key (or a hand on the trackpad) settle: input right after the request
    // cancels the sleep.
    let settleBy = Date().addingTimeInterval(3)
    while !UserInput.settled(), Date() < settleBy { usleep(100_000) }
    guard ControlStore.sleepNow() else { fail(cannotWrite) }
    print(L("Sleep requested. macOS determines when sleep completes.", "잠자기를 요청했습니다. 실제 절전 완료는 macOS에서 결정합니다."))

case .hold(let minutes):
    requireHelper(state)
    guard state.control.enabled else { fail(L("Tether is off. Run 'tether on' first.", "Tether가 꺼져 있습니다. 먼저 'tether on'을 실행해 주세요.")) }
    let percent = state.status?.batteryPercent ?? SystemProbe.batteryPercent()
    guard SafetyPolicy.canStartHold(batteryPercent: percent, user: state.limits) else {
        let floor = SafetyPolicy.floor(state.limits)
        fail(L("The battery is at \(percent ?? 0)%, at or under the \(floor)% floor, so a hold would end at once.",
               "배터리가 \(percent ?? 0)%로 하한선 \(floor)% 이하라 유지해도 바로 끝납니다."))
    }
    let after = change { ControlStore.startHold(minutes: minutes, source: "cli") }
    if let minutes = after.control.pendingHoldMinutes {
        print(L("Waiting to unplug: \(minutes) minutes. Cancel with tether hold off.", "전원 분리 후 \(minutes)분 유지 예약. 취소: tether hold off"))
        exit(0)
    }
    guard let until = after.status?.batteryHoldUntil else {
        fail(L("The helper didn't take the battery hold. Check 'tether status'.", "도우미가 배터리 유지를 받지 않았습니다. 'tether status'로 상태를 확인해 주세요."))
    }
    let floor = SafetyPolicy.floor(after.limits)
    print(L("Staying awake on battery until \(time(until)). It sleeps sooner if it gets hot or the battery reaches \(floor)%.",
            "배터리에서도 \(time(until))까지 유지합니다. 뜨거워지거나 배터리가 \(floor)%가 되면 먼저 잠듭니다."))

case .extendHold(let minutes):
    requireHelper(state)
    guard state.status?.batteryHoldUntil != nil else {
        fail(L("No battery hold is running. Start one with 'tether hold 1h'.", "배터리 유지가 켜져 있지 않습니다. 'tether hold 1h'로 먼저 켜 주세요."))
    }
    let after = change { ControlStore.extendHold(minutes: minutes) }
    if let minutes = after.control.pendingHoldMinutes {
        print(L("Waiting to unplug: \(minutes) minutes. Cancel with tether hold off.", "전원 분리 후 \(minutes)분 유지 예약. 취소: tether hold off"))
        exit(0)
    }
    guard let until = after.status?.batteryHoldUntil else { fail(cannotWrite) }
    print(L("Battery hold extended until \(time(until)) (at most 4 h from when it started).",
            "배터리 유지를 \(time(until))까지 늘렸습니다 (시작부터 최대 4시간)."))

case .cancelHold:
    requireHelper(state)
    let after = change { ControlStore.cancelHold() }
    let sleeping = after.snapshot.power == .battery && after.snapshot.lidClosed
    print(sleeping ? L("Battery hold ended. The lid is closed, so the Mac is going to sleep.", "배터리 유지를 껐습니다. 덮개가 닫혀 있어 Mac이 잠듭니다.")
                   : L("Battery hold ended.", "배터리 유지를 껐습니다."))
case .manual, .extendManual, .endManual, .automatic, .condition:
    fail(UserSessionFailure("coordinatorUnavailable").localizedDescription)
}
