import Foundation

/// One quick check of Tether's moving parts, for `tether doctor`, the top of the diagnostic
/// report and Settings › System.
public struct HealthCheck: Equatable, Sendable {
    public enum Result: String, Sendable {
        case ok, warning, failed
    }

    public let name: String
    public let result: Result
    /// What was found, or what to do about it.
    public let detail: String
}

public enum HealthChecks {
    /// Runs every check as the current user. `language` picks the wording, so the report can ask
    /// for English while the app speaks Korean.
    public static func run(now: Date = Date(), language: Language = Localization.current) -> [HealthCheck] {
        func t(_ english: String, _ korean: String) -> String { language == .korean ? korean : english }
        let fm = FileManager.default
        let status = JSONFile.read(Status.self, from: TetherPaths.statusPath)
        let control = JSONFile.read(Control.self, from: TetherPaths.controlPath)
        var out: [HealthCheck] = []
        func add(_ name: String, _ result: HealthCheck.Result, _ detail: String) {
            out.append(HealthCheck(name: name, result: result, detail: detail))
        }

        guard SystemProbe.isSupportedMac else {
            add(t("Laptop", "노트북"), .warning, t("No built-in battery or lid: Tether changes nothing here.",
                                                   "내장 배터리나 덮개가 없어 Tether가 아무것도 바꾸지 않아요."))
            return out
        }
        guard fm.fileExists(atPath: TetherPaths.helperPlistPath) else {
            add(t("Helper", "도우미"), .failed, t("Not installed. Install it from Tether in the menu bar.",
                                                 "설치되지 않았어요. 메뉴바의 Tether에서 설치해 주세요."))
            return out
        }
        let age = status.map { now.timeIntervalSince1970 - $0.updatedAt }
        if let age, age < 90, let status {
            add(t("Helper", "도우미"), .ok, t("Running, v\(status.version), checked \(Int(age)) s ago",
                                             "실행 중, v\(status.version), \(Int(age))초 전 확인"))
            add(t("Helper version", "도우미 버전"), status.version == TetherPaths.version ? .ok : .warning,
                status.version == TetherPaths.version ? "v\(status.version)"
                    : t("v\(status.version), this build is v\(TetherPaths.version): reinstall the helper",
                        "v\(status.version), 이 빌드는 v\(TetherPaths.version): 도우미를 다시 설치해 주세요"))
        } else {
            add(t("Helper", "도우미"), .failed, t("Not responding. Reinstall it from Settings › System.",
                                                 "응답하지 않아요. 설정 › 시스템에서 다시 설치해 주세요."))
        }
        let watchdog = fm.fileExists(atPath: TetherPaths.watchdogPlistPath) && fm.fileExists(atPath: TetherPaths.watchdogPath)
        add(t("Watchdog", "감시 장치"), watchdog ? .ok : .warning,
            watchdog ? t("Installed", "설치됨") : t("Missing: reinstall the helper to add it.", "없어요: 도우미를 다시 설치하면 추가돼요."))

        // Only meaningful while the helper answers and the Mac is fully awake (see `Policy`).
        let snapshot = SystemProbe.snapshot()
        if let age, age < 90, let control, snapshot.fullWake, snapshot.power != .unknown {
            let expected = Policy.wantsClamshell(snapshot, enabled: control.enabled, sleepNowPending: false,
                                                 batteryHold: status?.batteryHoldUntil != nil)
            add(t("Sleep setting", "잠자기 설정"), snapshot.sleepDisabled == expected ? .ok : .warning,
                snapshot.sleepDisabled == expected
                    ? (expected ? t("Sleep disabled, as the rule says", "규칙대로 잠자기 금지") : t("Sleep allowed, as the rule says", "규칙대로 잠자기 허용"))
                    : t("Doesn't match the rule yet; if it stays that way, create a diagnostic report.",
                        "아직 규칙과 달라요. 계속 그러면 진단 보고서를 만들어 주세요."))
        }
        let temperature = SystemProbe.batteryTemperature()
        add(t("Battery temperature", "배터리 온도"), temperature == nil ? .warning : .ok,
            temperature.map { String(format: "%.1f °C", $0) }
                ?? t("Unreadable: battery holds would end at once.", "읽을 수 없어요: 배터리 유지가 바로 끝나요."))
        let writable = access(TetherPaths.controlPath, W_OK) == 0
        add(t("Settings file", "설정 파일"), writable ? .ok : .warning,
            writable ? t("Writable", "쓸 수 있음") : t("Not writable: reinstall the helper.", "쓸 수 없어요: 도우미를 다시 설치해 주세요."))

        let agent = NSHomeDirectory() + "/Library/LaunchAgents/local.tether.app.plist"
        if let item = NSDictionary(contentsOfFile: agent) {
            let relaunches = item["KeepAlive"] != nil
            add(t("Login item", "로그인 항목"), relaunches ? .ok : .warning,
                relaunches ? t("Opens at login and after a crash", "로그인할 때와 비정상 종료 뒤 열림")
                    : t("Older version: open Tether once to update it.", "이전 버전: Tether를 한 번 열면 갱신돼요."))
        } else {
            add(t("Login item", "로그인 항목"), .warning,
                t("Off: without the app the screen under the lid isn't dimmed. Settings › General.",
                  "꺼져 있어요: 앱이 없으면 덮개 아래 화면을 끄지 못해요. 설정 › 일반."))
        }
        if control?.debugLog == true {
            add(t("Detailed logging", "자세한 기록"), .warning,
                t("On: turn it off when you're done (Settings › System).", "켜져 있어요: 다 쓰면 꺼 주세요(설정 › 시스템)."))
        }
        return out
    }
}
