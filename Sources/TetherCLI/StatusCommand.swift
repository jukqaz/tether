import Foundation
import TetherCore

/// Other processes' power assertions, without Tether's own.
func blockers() -> [SleepBlocker] {
    SystemProbe.sleepBlockers().filter { $0.process != "Tether" && !$0.process.hasPrefix("local.tether") }
}

func printStatus(_ s: State, json: Bool) {
    if json {
        printJSON(s)
        return
    }
    guard SystemProbe.capabilities.generalIdleAvailable else {
        print(L("This Mac has no built-in battery or lid: Tether leaves its sleep settings alone.",
                "이 Mac에는 내장 배터리나 덮개가 없어 Tether가 잠자기 설정을 건드리지 않습니다."))
        return
    }
    if SystemProbe.capabilities.helperInstallTarget == .desktop {
        print(UserSessionFailure("appUnavailable").localizedDescription)
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
    if let protection = status.protection {
        if let reason = protection.blockReason { print("\(L("Safety stop", "보호 중지")): \(reason)") }
    }
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
    if let recovery = status.currentDisplayRecovery(now: now) { print(recovery.summary) }
    if status.heatGuard == true {
        print(L("Legacy energy mode recovery pending", "구버전 전원 모드 복원 대기 중"))
    }
    if let usage = s.usage {
        let today = usage.stats.today(now: now)
        var line = L("Today: awake with the lid closed \(Texts.total(today.lidClosedSeconds))",
                     "오늘: 덮개 닫고 깨어 있음 \(Texts.total(today.lidClosedSeconds))")
        if today.sleepRequestAttempts > 0 { line += " · " + Texts.sleepRequestAttempts(today.sleepRequestAttempts) }
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
    let schemaVersion = 2
    let commonSessionAvailable = false
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
    var today: Today?
    var limits: Limits
    var lastSession: LidSession?
    var lastSleep: SleepRecord?
    var protection: ProtectionStatus?
    var displayRecovery: DisplayRecoveryStatus?
    var sleepBlockers: [Blocker]

    /// Today's totals, without the temperature histograms kept in usage.json.
    struct Today: Encodable {
        var day: String
        var lidClosedMinutes: Int
        /// Retained JSON field for older consumers; this counts request attempts.
        var forcedSleeps: Int
        var sleepRequestAttempts: Int
        var batteryHolds: Int
        var heatGuards: Int
        var lidClosedPeakTemperature: Double?
        var lidOpenPeakTemperature: Double?

        init(_ d: DayStats) {
            day = d.day
            lidClosedMinutes = Int(d.lidClosedSeconds / 60)
            forcedSleeps = d.forcedSleeps
            sleepRequestAttempts = d.sleepRequestAttempts
            batteryHolds = d.batteryHolds
            heatGuards = d.heatGuards
            lidClosedPeakTemperature = d.closedTemps?.max
            lidOpenPeakTemperature = d.openTemps?.max
        }
    }

    /// The battery-hold limits in force, auto-adjust included.
    struct Limits: Encodable {
        var batteryFloor: Int
        var maxHoldHours: Double

        init(_ user: UserLimits?) {
            batteryFloor = SafetyPolicy.floor(user)
            maxHoldHours = SafetyPolicy.maxHold(user) / 3600
        }
    }
}

func printJSON(_ s: State) {
    let report = Report(
        supportedMac: SystemProbe.capabilities.generalIdleAvailable, helperInstalled: s.installed, helperResponding: s.responding,
        helperVersion: s.status?.version, enabled: s.control.enabled, clamshell: s.clamshell, power: s.snapshot.power,
        lidClosed: s.snapshot.lidClosed, batteryPercent: s.status?.batteryPercent ?? SystemProbe.batteryPercent(),
        batteryTemperature: s.status?.batteryTemperature, thermal: s.status?.thermal,
        batteryHoldUntil: s.status?.batteryHoldUntil.map { Date(timeIntervalSince1970: $0) },
        heatGuard: s.status?.heatGuard ?? false, lastEvent: s.status?.lastEvent,
        lastEventAt: s.status?.lastEventAt.map { Date(timeIntervalSince1970: $0) },
        today: s.usage.map { Report.Today($0.stats.today(now: Date())) }, limits: Report.Limits(s.limits),
        lastSession: s.usage?.recentSessions.last,
        lastSleep: s.usage?.sleeps.recent.last,
        protection: s.status?.protection,
        displayRecovery: s.status?.displayRecovery,
        sleepBlockers: blockers().map { Report.Blocker(process: $0.process, kind: $0.kind.rawValue, reason: $0.reason) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(report) else { fail(L("Couldn't encode the state as JSON.", "상태를 JSON으로 만들지 못했습니다.")) }
    print(String(decoding: data, as: UTF8.self))
}
