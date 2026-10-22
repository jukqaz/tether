import Foundation
import TetherCore

/// Common work is authoritative; notebook lid support has its own result.
struct CLIWorkReport: Encodable {
    let schemaVersion = 2
    let commonSessionAvailable = true
    var supportedMac: Bool
    var enabled: Bool
    var clamshell: Bool
    var power: PowerSource
    var lidClosed: Bool?
    var batteryPercent: Int?
    var thermal: Int?
    var batteryHoldUntil: Date?
    var helperInstalled: Bool
    var helperResponding: Bool
    var helperBuild: Int?
    var receipt: UserSessionReply

    init(_ reply: UserSessionReply) {
        supportedMac = SystemProbe.capabilities.generalIdleAvailable
        enabled = reply.status?.enabled ?? false
        clamshell = reply.lidSupport == .active
        power = reply.status?.power ?? .unknown
        lidClosed = reply.lidClosed; batteryPercent = reply.status?.batteryPercent
        thermal = reply.status?.thermal; batteryHoldUntil = reply.status?.batteryHoldUntil
        helperInstalled = reply.helperBuild != nil
        helperResponding = reply.helperConnected ?? false
        helperBuild = reply.helperBuild; receipt = reply
    }
}

func userSessionClient() throws -> UserSessionClient {
    guard let executable = ProcessIdentity.capture(pid: getpid())?.executable else { throw UserSessionFailure("unexpectedServer") }
    let path = UserSessionEndpoint.path
    // A test executable is accepted only with an explicit, private endpoint.
    let fixtureServer = path == UserSessionEndpoint.production ? nil
        : ProcessInfo.processInfo.environment["TETHER_USER_SESSION_SERVER_EXECUTABLE"]
    guard let server = fixtureServer ?? UserSessionEndpoint.coordinatorExecutable(forClient: executable) else {
        throw UserSessionFailure("unexpectedServer")
    }
    return UserSessionClient(path: path, expectedServer: server)
}

func printUserSession(_ reply: UserSessionReply, command: TetherCommand, json: Bool) {
    if json {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do { print(String(decoding: try encoder.encode(CLIWorkReport(reply)), as: UTF8.self)) }
        catch { fail(L("Couldn't encode the app state as JSON.", "앱 상태를 JSON으로 만들지 못했습니다.")) }
        return
    }
    if command == .sleep {
        print(L("Sleep requested. macOS determines when sleep completes.", "잠자기를 요청했습니다. 실제 절전 완료는 macOS에서 결정합니다."))
        return
    }
    guard let state = reply.status else { fail(UserSessionFailure("coordinatorUnavailable").localizedDescription) }
    print("Tether: " + (state.enabled ? L("on", "켜짐") : L("off", "꺼짐")))
    print(L("Sleep prevention: ", "절전 방지: ") + (state.holding ? L("active", "유지 중") : L("inactive", "해제됨")))
    print(L("Display keeping selected: ", "화면 유지 선택: ")
          + (state.keepDisplayAwake.map { $0 ? L("on", "켜짐") : L("off", "꺼짐") }
             ?? L("unverified", "미확인")))
    print(L("Display request: ", "화면 유지 요청: ")
          + (state.displayHolding.map { $0 ? L("active", "활성") : L("inactive", "해제됨") }
             ?? L("unverified", "미확인")))
    if let error = state.displayError { print(L("Display request error: ", "화면 유지 요청 오류: ") + error) }
    print(L("Power: ", "전원: ") + state.power.rawValue + (state.batteryPercent.map { " · \($0)%" } ?? ""))
    print(L("Automatic trigger: ", "자동 트리거: ") + (state.automaticEnabled ? state.powerCondition.title : L("off", "꺼짐")))
    let manual = !state.manualActive ? L("off", "꺼짐") : state.until.map { L("until ", "종료: ") + Texts.time($0) } ?? L("unlimited on AC", "전원 연결 중 무제한")
    print(L("Manual session: ", "수동 세션: ") + manual)
    if let minutes = state.pendingBatteryMinutes {
        print(L("Battery reservation: \(minutes) minutes after unplugging", "배터리 예약: 전원 분리 후 \(minutes)분"))
    } else if let until = state.batteryHoldUntil {
        print(L("Battery hold: until ", "배터리 유지 종료: ") + Texts.time(until))
    }
    let lid: String
    switch reply.lidSupport {
    case .notRequired: lid = L("not required on a desktop Mac", "데스크톱 Mac에는 필요 없음")
    case .inactive: lid = L("inactive", "해제됨")
    case .active: lid = L("active", "유지 중")
    case .pending: lid = L("helper acknowledgement pending", "도우미 확인 대기 중")
    case .unavailable: lid = L("unavailable; check the matching helper", "사용 불가 · 같은 버전의 도우미 확인 필요")
    case .error: lid = reply.lidError ?? L("needs review", "확인 필요")
    }
    print(L("Lid support: ", "덮개 유지: ") + lid)
    if let reason = state.blockReason { print(L("Safety stop: ", "보호 중지: ") + reason) }
    if let error = state.error { print(error) }
}
