import Foundation

/// A small, allowlisted presentation of existing logs. Never expose raw command output,
/// process arguments or assertion payloads in the activity list.
public struct ActivityEvent: Identifiable, Equatable, Sendable {
    public var id: Int
    public var date: Date
    public var kind: Kind
    public enum Kind: String, Sendable {
        case started, powerConnected, powerDisconnected, lidClosed, lidOpened
        case reserved, reservationCancelled, holdStarted, holdExtended, holdEndedTime, holdEndedBattery
        case heatStop, sensorStop, protectionStop, cancelled, overrideOn, overrideOff, sleepRequested
        case screenRetry, screenConfirmed, screenStop, foreignOverride, marker, lowPowerOn, lowPowerRestored, willSleep, poweredOn, commandFailed
        case appConnected, appDisconnected
        case sleepDeferredOtherRequests, sleepDeferredObservationUnavailable

        public var title: String {
            switch self {
            case .started: L("Helper started", "도우미 시작")
            case .powerConnected: L("Power connected", "전원 연결 감지")
            case .powerDisconnected: L("Power disconnected", "전원 분리 감지")
            case .lidClosed: L("Lid closed", "덮개 닫힘 감지")
            case .lidOpened: L("Lid opened", "덮개 열림 감지")
            case .reserved: L("Battery session reserved", "전원 분리 후 사용 예약")
            case .reservationCancelled: L("Reservation cancelled", "배터리 사용 예약 취소")
            case .holdStarted: L("Battery timer started", "배터리 사용 타이머 시작")
            case .holdExtended: L("Battery timer extended", "배터리 사용 시간 연장")
            case .holdEndedTime: L("Time limit reached", "사용 시간이 끝나 유지 종료")
            case .holdEndedBattery: L("Battery reserve reached", "배터리 잔량 한도로 유지 종료")
            case .heatStop: L("Stopped for heat protection", "발열 보호로 유지 중지")
            case .sensorStop: L("Stopped because sensor readings were unavailable", "센서값을 확인할 수 없어 유지 중지")
            case .protectionStop: L("Stopped by a protection condition", "보호 조건으로 유지 중지")
            case .cancelled: L("Battery session cancelled", "사용자가 배터리 유지 종료")
            case .overrideOn: L("Tether sleep prevention applied", "Tether 잠자기 방지 적용")
            case .overrideOff: L("Tether sleep prevention released", "Tether 잠자기 방지 해제")
            case .sleepRequested: L("System sleep requested", "시스템 잠자기 요청")
            case .sleepDeferredOtherRequests: L("Automatic sleep deferred for another app's work request", "다른 앱의 작업 유지 요청으로 자동 잠자기를 보류했습니다")
            case .sleepDeferredObservationUnavailable: L("Automatic sleep deferred because request observation failed", "작업 유지 요청을 확인하지 못해 자동 잠자기를 보류했습니다")
            case .screenRetry: L("Display sleep recovery requested", "화면 절전 재시도")
            case .screenConfirmed: L("Display sleep observed; hold retained", "화면 절전 확인 · 유지 계속")
            case .screenStop: L("Stopped because display sleep was not maintained", "화면 절전이 유지되지 않아 중지")
            case .foreignOverride: L("Another power setting detected; automatic reapplication stopped", "다른 전원 설정을 감지해 자동 재적용 중지")
            case .marker: L("Problem moment marked", "문제 발생 시점 표시")
            case .lowPowerOn: L("Low Power Mode applied", "저전력 모드 적용")
            case .lowPowerRestored: L("Low Power Mode restored", "이전 저전력 설정 복원")
            case .willSleep: L("macOS announced a sleep transition", "macOS의 잠자기 전환 알림 수신")
            case .poweredOn: L("macOS announced wake", "macOS의 깨어남 알림 수신")
            case .commandFailed: L("Power change failed", "전원 설정 적용 실패")
            case .appConnected: L("App connected to the helper", "앱이 도우미에 연결됨")
            case .appDisconnected: L("App connection ended; releasing Tether's hold", "앱 연결 종료로 Tether 유지 해제 중")
            }
        }
        public var symbol: String {
            switch self {
            case .marker: "flag"
            case .heatStop, .sensorStop, .protectionStop, .screenStop, .foreignOverride, .commandFailed: "exclamationmark.shield"
            case .sleepRequested, .willSleep: "moon"
            case .sleepDeferredOtherRequests, .sleepDeferredObservationUnavailable: "pause.circle"
            case .reserved, .holdStarted, .holdExtended, .holdEndedTime: "timer"
            case .powerConnected, .powerDisconnected: "powerplug"
            default: "circle.dotted"
            }
        }
    }
}

public enum RecentActivity {
    public static func read(path: String, limit: Int = 20) -> [ActivityEvent] {
        parse(LogArchive.read(path: path), limit: limit)
    }

    public static func parse(_ text: String, limit: Int = 20, timeZone: TimeZone = .current) -> [ActivityEvent] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; formatter.isLenient = false
        let limit = min(100, max(0, limit))
        guard limit > 0 else { return [] }
        var result: [ActivityEvent] = [], power: String?, lid: String?, block: String?
        var sequence = 0
        func append(_ kind: ActivityEvent.Kind, at date: Date) {
            result.append(ActivityEvent(id: sequence, date: date, kind: kind))
            sequence += 1
            if result.count > limit { result.removeFirst() }
        }
        for line in text.split(separator: "\n") {
            guard line.count > 20, line[line.index(line.startIndex, offsetBy: 19)] == " ",
                  let date = formatter.date(from: String(line.prefix(19))) else { continue }
            let message = String(line.dropFirst(20))
            if message.hasPrefix("observed: ") {
                let pairs = message.dropFirst(10).split(separator: " ").compactMap { part -> (String, String)? in
                    let pair = part.split(separator: "=", maxSplits: 1); guard pair.count == 2 else { return nil }
                    return (String(pair[0]), String(pair[1]))
                }
                // Do not trap on duplicate or malformed keys from an incomplete log tail.
                var fields: [String: String] = [:]; for (key, value) in pairs { fields[key] = value }
                if let current = fields["power"], ["ac", "battery"].contains(current) {
                    if let power, power != current { append(current == "ac" ? .powerConnected : .powerDisconnected, at: date) }
                    power = current
                }
                if let current = fields["lid"], ["open", "closed"].contains(current) {
                    if let lid, lid != current { append(current == "closed" ? .lidClosed : .lidOpened, at: date) }
                    lid = current
                }
                if let current = fields["block"] {
                    if current != "none", current != block { append(.protectionStop, at: date) }
                    block = current
                }
            } else if let kind = kind(message) { append(kind, at: date) }
        }
        // Keep physical log order. A wall-clock correction must not reorder the causal chain.
        return result.reversed()
    }

    private static func kind(_ message: String) -> ActivityEvent.Kind? {
        if message.hasPrefix("started v") { return .started }
        if message.hasPrefix("diagnostic marker "), UUID(uuidString: String(message.dropFirst(18))) != nil { return .marker }
        switch message {
        case "activity: battery session reserved": return .reserved
        case "activity: battery reservation cancelled": return .reservationCancelled
        case "battery hold armed", "on battery with a battery hold: clamshell kept": return .holdStarted
        case "battery hold extended": return .holdExtended
        case "battery hold ended: time is up": return .holdEndedTime
        case "battery hold ended: battery at the floor": return .holdEndedBattery
        case "battery hold ended: battery too hot", "battery hold ended: system thermal pressure": return .heatStop
        case "battery hold ended: battery temperature unreadable": return .sensorStop
        case "battery hold cancelled": return .cancelled
        case "on power: clamshell on", "battery hold: clamshell on": return .overrideOn
        case "clamshell override released", "power disconnected: clamshell off", "Tether turned off: clamshell off", "helper stopping: clamshell off", "sleep now: clamshell off": return .overrideOff
        case "app session connected": return .appConnected
        case "app session disconnected: app requested detach; ending temporary work and releasing owned power changes",
             "app session disconnected: process exited; ending temporary work and releasing owned power changes",
             "app session disconnected: process no longer alive; ending temporary work and releasing owned power changes": return .appDisconnected
        case "lid already closed: sleep requested", "sleep now requested", "lid closed on AC and overheating: sleep requested", "lid closed on a charger that can't keep up, battery at the floor and draining: sleep requested": return .sleepRequested
        case "automatic sleep deferred: otherRequests; foreign requests preserved": return .sleepDeferredOtherRequests
        case "automatic sleep deferred: observationUnavailable; foreign requests preserved": return .sleepDeferredObservationUnavailable
        case "activity: display recovery requested": return .screenRetry
        case "activity: display sleep confirmed": return .screenConfirmed
        case "activity: display recovery stopped",
             "display sleep not maintained; hold stopped without repeated display-off requests": return .screenStop
        case "power override changed externally; automatic reapplication suspended": return .foreignOverride
        case "lid closed on AC and running hot: Low Power Mode on", "battery hold: Low Power Mode on", "battery hold: Low Power Mode on (already on)": return .lowPowerOn
        case "heat guard released: Low Power Mode restored", "battery hold: Low Power Mode off, restored": return .lowPowerRestored
        case "system power: will sleep": return .willSleep
        case "system power: powered on": return .poweredOn
        case "command result: simulated failure": return .commandFailed
        case "power mode restoration was not confirmed; recovery state retained",
             "helper removal deferred: power restoration incomplete; recovery files retained": return .commandFailed
        default:
            return message.hasPrefix("error: pmset ") ? .commandFailed : nil
        }
    }
}
