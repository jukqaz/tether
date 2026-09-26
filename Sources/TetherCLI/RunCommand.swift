import Foundation
import TetherCore

/// Keeps the Mac awake for one command: arms a battery hold (unless one is already armed), runs
/// the command with the terminal attached, then ends the hold it armed. Exits with the command's
/// status.
func run(_ rest: [String]) -> Never {
    var words = rest
    var maxMinutes: Int?
    while let first = words.first, first.hasPrefix("-") {
        words.removeFirst()
        if first == "--" { break }
        if first == "--max", let value = words.first {
            words.removeFirst()
            guard let minutes = HoldDuration.minutes(value) else {
                fail(L("Give --max between 1 minute and 4 hours, e.g. --max 2h.", "--max는 1분에서 4시간 사이로 적어 주세요. 예: --max 2h"), code: 2)
            }
            maxMinutes = minutes
        } else {
            fail(L("Unknown option: \(first)", "알 수 없는 옵션: \(first)"), code: 2)
        }
    }
    guard !words.isEmpty else {
        fail(L("Say what to run, e.g. tether run -- make release", "실행할 명령을 적어 주세요. 예: tether run -- make release"), code: 2)
    }

    let state = State()
    requireHelper(state)
    if !state.control.enabled {
        note(L("Tether is off: the command runs, but closing the lid will sleep the Mac.",
               "Tether가 꺼져 있습니다: 명령은 실행하지만 덮개를 닫으면 잠듭니다."))
    }

    // Our own hold, sized to the command's worst case; one already armed is left alone.
    var ownHold: Double?
    let percent = state.status?.batteryPercent ?? SystemProbe.batteryPercent()
    let canHold = SafetyPolicy.canStartHold(batteryPercent: percent, user: state.limits)
    if state.control.enabled, !canHold {
        note(L("tether: the battery is at or under its floor, so there's no battery hold; on power it stays awake as usual",
               "tether: 배터리가 하한선 이하라 배터리 유지 없이 실행합니다. 전원이 연결돼 있으면 평소처럼 깨어 있습니다"))
    }
    if state.control.enabled, canHold, state.status?.batteryHoldUntil == nil {
        let longest = Int(SafetyPolicy.maxHold(state.limits) / 60)
        let minutes = min(maxMinutes ?? longest, longest)
        let name = (words[0] as NSString).lastPathComponent
        let after = change { ControlStore.startHold(minutes: minutes, source: "run:\(name)") }
        ownHold = after.control.batteryHoldUntil
        let longestText = Texts.duration(TimeInterval(minutes * 60))
        note(L("tether: staying awake (up to \(longestText) on battery) until the command finishes",
               "tether: 명령이 끝날 때까지 깨어 있습니다 (배터리로는 최대 \(longestText))"))
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = words
    let started = Date()
    do {
        try process.run()
    } catch {
        if let ownHold, ControlStore.read().batteryHoldUntil == ownHold { ControlStore.cancelHold() }
        fail(L("Couldn't start \(words[0]): \(error.localizedDescription)", "\(words[0])을(를) 시작하지 못했습니다: \(error.localizedDescription)"))
    }

    // Ctrl-C reaches the command through the terminal; tether waits for it and cleans up.
    // (Set after launching, or the child would inherit the ignored signals.)
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    term.setEventHandler { process.terminate() }
    term.resume()
    process.waitUntilExit()

    let took = Texts.duration(Date().timeIntervalSince(started))
    if let ownHold, ControlStore.read().batteryHoldUntil == ownHold {
        ControlStore.cancelHold()
        note(L("tether: done after \(took); the Mac may sleep again", "tether: \(took) 만에 끝났습니다. 이제 다시 잠들 수 있습니다"))
    } else if ownHold != nil {
        // Someone ended or replaced the hold meanwhile (the panel, another command): theirs now.
        note(L("tether: done after \(took); the battery hold was changed meanwhile, so it was left as it is",
               "tether: \(took) 만에 끝났습니다. 그사이 배터리 유지가 바뀌어 그대로 두었습니다"))
    } else {
        note(L("tether: done after \(took)", "tether: \(took) 만에 끝났습니다"))
    }
    let status = process.terminationStatus
    exit(process.terminationReason == .uncaughtSignal ? 128 + status : status)
}
