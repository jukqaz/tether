import Foundation

/// Wording shared by the menu bar app and the `tether` command, in English and Korean.
public enum Texts {
    public static func thermal(_ level: Int) -> String {
        switch level {
        case 0: L("normal", "정상")
        case 1: L("fair", "보통")
        case 2: L("serious", "심각")
        default: L("critical", "위험")
        }
    }

    /// "1 h 23 min" / "1시간 23분", "42 min" / "42분", "30 s" / "30초".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return L("\(s) s", "\(s)초") }
        let hours = s / 3600
        let minutes = s % 3600 / 60
        if hours == 0 { return L("\(minutes) min", "\(minutes)분") }
        if minutes == 0 { return L("\(hours) h", "\(hours)시간") }
        return L("\(hours) h \(minutes) min", "\(hours)시간 \(minutes)분")
    }

    /// Accumulated time for stats, in whole minutes.
    public static func total(_ seconds: TimeInterval) -> String {
        seconds < 60 ? L("0 min", "0분") : duration(seconds)
    }

    /// A ticking countdown: "29:41", or "1:29:41" from an hour up. Rounded up, so it never shows
    /// 0:00 while time is left.
    public static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        let hours = s / 3600, minutes = s % 3600 / 60, rest = s % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// Why the Mac went to sleep, from IOPMrootDomain "Last Sleep Reason".
    public static func sleepCause(_ record: SleepRecord) -> String {
        if record.byTether { return L("Tether put it to sleep", "Tether가 재움") }
        switch record.sleepReason ?? "" {
        case let r where r.contains("Clamshell"): return L("lid closed", "덮개 닫힘")
        case let r where r.contains("Idle"): return L("idle", "사용하지 않아서")
        case let r where r.contains("Power Button"): return L("power button", "전원 버튼")
        case let r where r.contains("Low Power"): return L("battery low", "배터리 부족")
        case let r where r.contains("Thermal"): return L("overheating", "과열")
        case let r where r.contains("Software"): return L("an app or the menu", "앱이나 메뉴에서")
        case "": return L("unknown", "알 수 없음")
        case let r: return r
        }
    }

    /// What woke the Mac, from IOPMrootDomain "Wake Type" and "Wake Reason".
    public static func wakeCause(_ record: SleepRecord) -> String {
        let text = [record.wakeType, record.wakeReason].compactMap { $0 }.joined(separator: " ")
        if text.contains("LidOpen") || text.contains("Lid Open") { return L("lid opened", "덮개 열림") }
        if text.contains("PowerButton") || text.contains("PwrBtn") || text.contains("Power Button") {
            return L("power button", "전원 버튼")
        }
        if text.contains("UserActivity") || text.contains("HID") { return L("keyboard or trackpad", "키보드·트랙패드") }
        if text.contains("AC") && text.contains("Adapter") { return L("power connected", "전원 연결") }
        if text.contains("wifi") || text.contains("ARPT") || text.contains("WLAN") || text.contains("bt") {
            return L("Wi-Fi or Bluetooth", "Wi-Fi·블루투스")
        }
        if text.contains("RTC") || text.contains("Maintenance") || text.contains("SleepService") {
            return L("scheduled system task", "예약된 시스템 작업")
        }
        return text.isEmpty ? L("unknown", "알 수 없음") : L("other", "기타")
    }

    /// How a sleep drain rate compares with the usual 1–2 %/h.
    public static func drainLevel(_ perHour: Double) -> String {
        perHour < 1.5 ? L("normal", "정상") : (perHour < SleepLog.highDrain ? L("a bit high", "조금 높음") : L("high", "높음"))
    }

    /// One line describing a finished lid session.
    public static func session(_ s: LidSession) -> String {
        var parts = [L("\(duration(s.duration)) closed", "\(duration(s.duration)) 동안")]
        if let t = s.maxTemperature { parts.append(L(String(format: "peak %.1f°C", t), String(format: "최고 %.1f°C", t))) }
        parts.append(L("heat \(thermal(s.maxThermal))", "발열 \(thermal(s.maxThermal))"))
        if let a = s.batteryStart, let b = s.batteryEnd, a != b {
            parts.append(L("battery \(a)% → \(b)%", "배터리 \(a)% → \(b)%"))
        }
        if s.lowPower { parts.append(L("Low Power Mode used", "저전력 모드 사용")) }
        return parts.joined(separator: " · ")
    }

    /// Who armed a battery hold, for the panel; nil for the app itself.
    public static func holdSource(_ raw: String?) -> String? {
        guard let raw, raw != "app" else { return nil }
        if raw.hasPrefix("run:") {
            let command = String(raw.dropFirst(4))
            return L("tether run: \(command)", "tether run: \(command)")
        }
        switch raw {
        case "cli": return L("from the terminal", "터미널에서")
        case "url": return L("from a shortcut or URL", "단축어·URL에서")
        default: return nil
        }
    }

    /// What a blocker holds off.
    public static func blockerKind(_ kind: SleepBlocker.Kind) -> String {
        switch kind {
        case .system: L("keeps the Mac awake", "잠자기 막음")
        case .display: L("keeps the display on", "화면 꺼짐 막음")
        }
    }
}

extension EventKind {
    public var displayText: String {
        switch self {
        case .started: L("helper started", "도우미 시작")
        case .clamshellOn: L("power connected → clamshell on", "전원 연결 → 클램쉘 켬")
        case .clamshellOffPower: L("power disconnected → clamshell off", "전원 해제 → 클램쉘 끔")
        case .clamshellOffDisabled: L("Tether turned off → clamshell off", "Tether 끔 → 클램쉘 끔")
        case .clamshellOffSleepNow: L("sleep now → clamshell off", "지금 잠자기 → 클램쉘 끔")
        case .lidSleep: L("lid was closed → put to sleep", "덮개 닫힌 상태 → 잠재움")
        case .sleepNow: L("sleep now", "지금 잠자기")
        case .sleepRefused: L("sleep refused → retried", "잠자기 거부됨 → 다시 시도")
        case .stopping: L("helper stopping → clamshell off", "도우미 종료 → 클램쉘 끔")
        case .holdOnBattery: L("battery hold started · Low Power Mode", "배터리 유지 시작 · 저전력 모드")
        case .holdEndedTime: L("battery hold ended · time up", "배터리 유지 종료 · 시간 끝")
        case .holdEndedBattery: L("battery hold ended · battery low", "배터리 유지 종료 · 배터리 부족")
        case .holdEndedHeat: L("battery hold ended · battery hot", "배터리 유지 종료 · 배터리 과열")
        case .holdEndedThermal: L("battery hold ended · system heat", "배터리 유지 종료 · 시스템 발열")
        case .holdEndedSensor: L("battery hold ended · no temperature", "배터리 유지 종료 · 온도 확인 불가")
        case .holdCancelled: L("battery hold cancelled", "배터리 유지 취소")
        case .heatGuardOn: L("heat guard · Low Power Mode on", "발열 보호 · 저전력 모드 켬")
        case .heatGuardOff: L("heat guard off · Low Power Mode restored", "발열 보호 끝 · 저전력 모드 복원")
        case .heatCritical: L("critical heat for 3 minutes", "발열 위험 3분 지속")
        case .overheatSleep: L("overheating on power → put to sleep", "전원 연결 중 과열 → 잠재움")
        }
    }
}

extension HoldEnd {
    public var displayReason: String {
        switch self {
        case .time: L("the time you set is up", "정한 시간이 끝났습니다")
        case .battery: L("the battery reached its floor", "배터리가 하한선까지 내려갔습니다")
        case .heat: L("the battery got too hot", "배터리 온도가 안전 기준을 넘었습니다")
        case .thermal: L("the system got too hot", "시스템 발열이 안전 기준을 넘었습니다")
        case .sensor: L("the battery temperature could not be read", "배터리 온도를 읽을 수 없었습니다")
        case .cancelled: L("the hold was cancelled", "배터리 유지가 취소됐습니다")
        }
    }
}
