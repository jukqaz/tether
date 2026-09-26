import Foundation
import TetherCore

// `tether`: control Tether from a terminal, a script, an agent, or Shortcuts ("Run Shell Script").
// Writes the same control file the menu bar app writes; the helper applies it.

let usageText = L("""
tether: control Tether's clamshell mode

  tether [status] [--json]      current state (--json for scripts and agents)
  tether on | off | toggle      turn Tether on, off, or flip it
  tether sleep                  sleep now, even on power
  tether hold <time>            stay awake on battery too: 30m, 1h, 1h30m, 90 (minutes), up to 4h
  tether hold off               end the battery hold
  tether run [--max <time>] [--] <command…>
                                keep the Mac awake until the command finishes (lid closed and on
                                battery too, within the safety limits), then let it sleep again
  tether blank                  turn the screen off without locking (needs the menu bar app)

The same commands work as URLs: tether://sleep, tether://hold/90m, tether://blank
""", """
tether: Tether 클램쉘 모드 제어

  tether [status] [--json]      지금 상태 (--json: 스크립트·에이전트용)
  tether on | off | toggle      Tether 켜기 / 끄기 / 전환
  tether sleep                  지금 잠자기 (전원이 연결돼 있어도)
  tether hold <시간>             배터리에서도 유지: 30m, 1h, 1h30m, 90 (분), 최대 4h
  tether hold off               배터리 유지 끄기
  tether run [--max <시간>] [--] <명령…>
                                명령이 끝날 때까지 깨어 있게 함 (덮개를 닫고 배터리여도 안전 기준 안에서),
                                끝나면 다시 잠들 수 있게 풀어 줌
  tether blank                  잠그지 않고 화면만 끄기 (메뉴바 앱이 켜져 있어야 함)

같은 명령을 URL로도 쓸 수 있습니다: tether://sleep, tether://hold/90m, tether://blank
""")

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let cannotWrite = L("Can't write the control file (\(TetherPaths.controlPath)). Try reinstalling the helper.",
                    "설정 파일을 쓸 수 없습니다 (\(TetherPaths.controlPath)). 도우미를 다시 설치해 보세요.")

// MARK: Reading state

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

func time(_ t: Double) -> String {
    Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened)
}

/// Other processes' power assertions, without Tether's own.
func blockers() -> [SleepBlocker] {
    SystemProbe.sleepBlockers().filter { $0.process != "Tether" && !$0.process.hasPrefix("local.tether") }
}

func printStatus(_ s: State, json: Bool) {
    if json {
        printJSON(s)
        return
    }
    guard SystemProbe.isSupportedMac else {
        print(L("This Mac has no built-in battery or lid: Tether leaves its sleep settings alone.",
                "이 Mac에는 내장 배터리나 덮개가 없어 Tether가 잠자기 설정을 건드리지 않습니다."))
        return
    }
    guard s.installed else {
        print(L("Helper: not installed (install it from Tether in the menu bar)", "도우미: 설치되지 않음 (메뉴바의 Tether에서 설치)"))
        return
    }
    guard s.responding, let status = s.status else {
        print(L("Helper: not responding (reinstall it from Tether's settings)", "도우미: 응답 없음 (Tether 설정에서 다시 설치)"))
        return
    }
    let now = Date()
    let state = !s.control.enabled ? L("off", "꺼짐")
        : (s.clamshell ? L("on · clamshell on", "켜짐 · 클램쉘 켜짐") : L("on · clamshell off", "켜짐 · 클램쉘 꺼짐"))
    print("Tether: \(state)")
    let power = s.snapshot.power == .ac ? L("connected", "연결됨")
        : (s.snapshot.power == .battery ? L("battery", "배터리") : L("checking", "확인 중"))
    print(L("Power: ", "전원: ") + power + (status.batteryPercent.map { " · \($0)%" } ?? ""))
    print(L("Lid: ", "덮개: ") + (s.snapshot.lidClosed ? L("closed", "닫힘") : L("open", "열림")))
    let temperature = status.batteryTemperature.map { String(format: "%.1f°C", $0) } ?? "–"
    print(L("Battery temperature: \(temperature) · heat \(Texts.thermal(status.thermal ?? 0))",
            "배터리 온도: \(temperature) · 발열 \(Texts.thermal(status.thermal ?? 0))"))
    if let until = status.batteryHoldUntil {
        print(L("Battery hold: until \(time(until)) (\(Texts.duration(until - now.timeIntervalSince1970)) left)",
                "배터리 유지: \(time(until))까지 (\(Texts.duration(until - now.timeIntervalSince1970)) 남음)"))
    }
    if status.heatGuard == true {
        print(L("Heat guard: Low Power Mode on (lid closed, on power)", "발열 보호: 저전력 모드 켜짐 (덮개 닫힘, 전원 연결)"))
    }
    if let usage = s.usage {
        let today = usage.stats.today(now: now)
        var line = L("Today: awake with the lid closed \(Texts.total(today.lidClosedSeconds))",
                     "오늘: 덮개 닫고 깨어 있음 \(Texts.total(today.lidClosedSeconds))")
        if today.forcedSleeps > 0 { line += L(" · slept \(today.forcedSleeps)×", " · 잠재움 \(today.forcedSleeps)회") }
        if today.heatGuards > 0 { line += L(" · heat guard \(today.heatGuards)×", " · 발열 보호 \(today.heatGuards)회") }
        print(line)
        if let last = usage.sleeps.recent.last, let drain = last.drainPerHour {
            print(L(String(format: "Last sleep: %@ · %.1f%%/h (%@)", Texts.duration(last.duration ?? 0), drain, Texts.drainLevel(drain)),
                    String(format: "지난 잠: %@ · 시간당 %.1f%% (%@)", Texts.duration(last.duration ?? 0), drain, Texts.drainLevel(drain))))
        }
    }
    for b in blockers() {
        print(L("Keeping the Mac awake: \(b.process) (\(b.reason.isEmpty ? Texts.blockerKind(b.kind) : b.reason))",
                "잠을 막는 앱: \(b.process) (\(b.reason.isEmpty ? Texts.blockerKind(b.kind) : b.reason))"))
    }
    if let event = status.lastEvent, let at = status.lastEventAt {
        print(L("Last event: ", "최근 이벤트: ") + "\(time(at)) \(event.displayText)")
    }
}

struct Report: Encodable {
    struct Blocker: Encodable {
        var process: String
        var kind: String
        var reason: String
    }

    var supportedMac: Bool
    var helperInstalled: Bool
    var helperResponding: Bool
    var helperVersion: String?
    var enabled: Bool
    var clamshell: Bool
    var power: PowerSource
    var lidClosed: Bool
    var batteryPercent: Int?
    var batteryTemperature: Double?
    var thermal: Int?
    var batteryHoldUntil: Date?
    var heatGuard: Bool
    var lastEvent: EventKind?
    var lastEventAt: Date?
    var today: DayStats?
    var lastSession: LidSession?
    var lastSleep: SleepRecord?
    var sleepBlockers: [Blocker]
}

func printJSON(_ s: State) {
    let report = Report(
        supportedMac: SystemProbe.isSupportedMac, helperInstalled: s.installed, helperResponding: s.responding,
        helperVersion: s.status?.version, enabled: s.control.enabled, clamshell: s.clamshell, power: s.snapshot.power,
        lidClosed: s.snapshot.lidClosed, batteryPercent: s.status?.batteryPercent ?? SystemProbe.batteryPercent(),
        batteryTemperature: s.status?.batteryTemperature, thermal: s.status?.thermal,
        batteryHoldUntil: s.status?.batteryHoldUntil.map { Date(timeIntervalSince1970: $0) },
        heatGuard: s.status?.heatGuard ?? false, lastEvent: s.status?.lastEvent,
        lastEventAt: s.status?.lastEventAt.map { Date(timeIntervalSince1970: $0) },
        today: s.usage?.stats.today(now: Date()), lastSession: s.usage?.recentSessions.last,
        lastSleep: s.usage?.sleeps.recent.last,
        sleepBlockers: blockers().map { Report.Blocker(process: $0.process, kind: $0.kind.rawValue, reason: $0.reason) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(report) else { fail(L("Couldn't encode the state as JSON.", "상태를 JSON으로 만들지 못했습니다.")) }
    print(String(decoding: data, as: UTF8.self))
}

// MARK: Changing state

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

// MARK: tether run

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
        FileHandle.standardError.write(Data(L("Tether is off: the command runs, but closing the lid will sleep the Mac.\n",
                                              "Tether가 꺼져 있습니다: 명령은 실행하지만 덮개를 닫으면 잠듭니다.\n").utf8))
    }

    // Our own hold, sized to the command's worst case; one already armed is left alone.
    var ownHold: Double?
    if state.control.enabled, state.status?.batteryHoldUntil == nil {
        let longest = Int(SafetyPolicy.maxHold(state.control.limits) / 60)
        let minutes = min(maxMinutes ?? longest, longest)
        let after = change { ControlStore.startHold(minutes: minutes) }
        ownHold = after.control.batteryHoldUntil
        FileHandle.standardError.write(Data(L("tether: staying awake (up to \(Texts.duration(TimeInterval(minutes * 60))) on battery) until the command finishes\n",
                                              "tether: 명령이 끝날 때까지 깨어 있습니다 (배터리로는 최대 \(Texts.duration(TimeInterval(minutes * 60))))\n").utf8))
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
    let message: String
    if let ownHold, ControlStore.read().batteryHoldUntil == ownHold {
        ControlStore.cancelHold()
        message = L("tether: done after \(took); the Mac may sleep again\n", "tether: \(took) 만에 끝났습니다. 이제 다시 잠들 수 있습니다\n")
    } else if ownHold != nil {
        // Someone ended or replaced the hold meanwhile (the panel, another command): theirs now.
        message = L("tether: done after \(took); the battery hold was changed meanwhile, so it was left as it is\n",
                    "tether: \(took) 만에 끝났습니다. 그사이 배터리 유지가 바뀌어 그대로 두었습니다\n")
    } else {
        message = L("tether: done after \(took)\n", "tether: \(took) 만에 끝났습니다\n")
    }
    FileHandle.standardError.write(Data(message.utf8))
    let status = process.terminationStatus
    exit(process.terminationReason == .uncaughtSignal ? 128 + status : status)
}

// MARK: Main

let wantsJSON = arguments.contains("--json")
if arguments.first == "run" {
    run(Array(arguments.dropFirst()))
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
                                       : L("Tether is off. Closing the lid will sleep the Mac.", "Tether를 껐습니다. 이제 덮개를 닫으면 잠듭니다."))
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
    let after = change { ControlStore.startHold(minutes: minutes) }
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

case .blank:
    // Gamma changes last only as long as the process that made them, so the app does this.
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "tether://blank"]
    do {
        try open.run()
        open.waitUntilExit()
    } catch {
        fail(L("Couldn't reach the menu bar app: \(error.localizedDescription)", "메뉴바 앱을 부르지 못했습니다: \(error.localizedDescription)"))
    }
    guard open.terminationStatus == 0 else {
        fail(L("Couldn't reach the menu bar app (open \(open.terminationStatus)).", "메뉴바 앱을 부르지 못했습니다 (open \(open.terminationStatus))."))
    }
    print(state.clamshell && !state.snapshot.lidClosed
          ? L("Turning the screen off. It isn't locked: move the mouse or press a key to bring it back.",
              "화면을 끕니다. 잠그지 않으니 마우스나 키보드를 쓰면 다시 켜집니다.")
          : L("The screen can only be turned off while clamshell mode is on and the lid is open.",
              "클램쉘 모드가 켜져 있고 덮개가 열려 있을 때만 화면을 끌 수 있습니다."))
}
