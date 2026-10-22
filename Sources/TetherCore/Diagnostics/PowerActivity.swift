import Foundation

/// Detection is informational. An installed/running utility is not evidence of a conflict.
public enum PowerAppCatalog {
    /// Exact bundle identifiers, rather than process-name guesses. Unknown apps
    /// still appear in assertion diagnostics; this list only adds installation hints.
    public static let bundleIDs = ["sh.gyorgy.keepresso", "com.if.Amphetamine",
        "info.marcel-dierkes.KeepingYouAwake", "com.apphousekitchen.aldente-pro",
        "com.intelliscapesolutions.Caffeine"]
    public static func name(bundleID: String?) -> String? {
        switch bundleID?.lowercased() {
        case "sh.gyorgy.keepresso": "Keepresso"
        case "com.if.amphetamine": "Amphetamine"
        case "info.marcel-dierkes.keepingyouawake": "KeepingYouAwake"
        case "com.apphousekitchen.aldente-pro": "AlDente"
        case "com.intelliscapesolutions.caffeine": "Caffeine"
        default: nil
        }
    }
}

public struct PowerRequestFinding: Identifiable, Equatable, Sendable {
    public var id: String { "\(pid):\(kinds.map(\.rawValue).sorted().joined(separator: ","))" }
    public let pid: Int32
    public let process: String
    public let kinds: Set<SleepBlocker.Kind>
    /// Opposing intent, not proof that the display actually failed to sleep.
    public let opposesDisplaySleep: Bool
    /// Assertion types are safe metadata. Assertion payloads may contain private work.
    public var assertionTypes: [String] = []
    public var purposes: Set<PowerRequestPurpose> = []
    public init(pid: Int32, process: String, kinds: Set<SleepBlocker.Kind>, opposesDisplaySleep: Bool,
                assertionTypes: [String] = [], purposes: Set<PowerRequestPurpose> = []) {
        self.pid = pid; self.process = process; self.kinds = kinds
        self.opposesDisplaySleep = opposesDisplaySleep; self.assertionTypes = assertionTypes
        self.purposes = purposes
    }

    public var summary: String {
        if opposesDisplaySleep { return L("May prevent the display from sleeping", "화면 끄기를 방해할 수 있음") }
        if kinds.contains(.display) { return L("Requests an awake display", "화면을 켜 두도록 요청 중") }
        if kinds.contains(.system) || kinds.contains(.network) { return L("Does not require the display to stay on", "화면을 켜 둘 필요 없음") }
        return L("Legacy sleep request observed", "이전 방식의 잠자기 방지 요청")
    }

    public var guidance: String {
        if kinds.contains(.display) {
            return opposesDisplaySleep
                ? L("Check this app's keep-screen-awake setting. If available, keep only its background-work option. Tether does not change the app's setting or end its work.", "해당 앱에서 화면을 계속 켜 두는 설정을 확인하세요. 가능하면 백그라운드 작업만 유지하도록 변경하세요.")
                : L("This app also requests a lit screen. There is no current opposing display-sleep intent; review its setting if you want the screen off.", "화면을 계속 켜 두도록 요청합니다. 화면을 끄고 싶다면 해당 앱의 설정을 확인하세요.")
        }
        if kinds.contains(.system) || kinds.contains(.network) {
            return L("This request does not require a lit screen. It can coexist with Tether's display sleep, but does not guarantee survival of lid-close or explicit system sleep.", "화면을 끄는 동작과 함께 사용할 수 있습니다. 다만 Mac 자체가 잠들면 작업이 중단될 수 있습니다.")
        }
        return L("A deprecated request was observed. Its effect on current macOS cannot be assumed; check the app's settings.", "이전 macOS용 요청입니다. 현재 효과는 확인하기 어려우므로 해당 앱의 설정을 확인하세요.")
    }

    public var overlapDescriptions: [String] {
        var result: [String] = []
        if kinds.contains(.system) {
            result.append(L("General keep-awake overlaps Tether's automatic/manual work sessions and macOS idle sleep. It can coexist; it is not a display-on or login-unlock request.",
                "일반 절전 방지는 Tether의 자동·수동 작업 유지 및 macOS의 유휴 잠자기와 겹칩니다. 함께 사용할 수 있으며 화면 켜짐이나 로그인 잠금 해제를 요청하는 기능은 아닙니다."))
        }
        if kinds.contains(.display) {
            result.append(L("Display keep-awake overlaps macOS display-off timing and can oppose Tether's closed-lid display sleep. Disable the screen-awake option in this app if screen-off is intended.",
                "화면 켜짐 유지는 macOS의 디스플레이 끄기 시간과 겹치고 Tether의 닫힌 화면 절전과 반대될 수 있습니다. 화면을 끄려면 해당 앱의 화면 유지 옵션을 확인하세요."))
        }
        if kinds.contains(.network) {
            result.append(L("Network activity overlaps macOS network-work sleep handling. It does not require a lit display and does not extend Tether's battery deadline.",
                "네트워크 활동은 macOS가 네트워크 작업을 위해 잠자기를 조정하는 기능과 겹칩니다. 화면을 켜 둘 필요는 없고 Tether의 배터리 마감도 연장하지 않습니다."))
        }
        if kinds.contains(.legacySystem) {
            result.append(L("This is a legacy system-sleep assertion. It is different from Tether's owned idle request and global lid override; its exact effect on this macOS is not established by its presence.",
                "이전 방식의 시스템 절전 방지 요청입니다. Tether의 일반 요청이나 전역 덮개 차단과는 다르며, 요청이 있다는 사실만으로 현재 macOS에서의 효과를 확정할 수 없습니다."))
        }
        result.append(L("Other apps' requests are not cancelled by Tether. A configured system Sleep on unplug can interrupt their work; approve bounded battery work before unplugging if needed.",
            "Tether는 다른 앱의 요청을 취소하지 않습니다. 설정한 전원 분리 잠자기가 실행되면 다른 앱 작업도 중단될 수 있으므로, 필요하면 분리 전에 제한된 배터리 작업을 시작하세요."))
        return result
    }
}

public enum PowerActivityPolicy {
    public static func requests(_ blockers: [SleepBlocker], displaySleepExpected: Bool) -> [PowerRequestFinding] {
        Dictionary(grouping: blockers, by: \.pid).values.map { group in
            let first = group[0]
            let kinds = Set(group.map(\.kind))
            return PowerRequestFinding(pid: first.pid, process: first.process, kinds: kinds,
                                       opposesDisplaySleep: displaySleepExpected && kinds.contains(.display),
                                       assertionTypes: Array(Set(group.compactMap(\.assertionType))).sorted(),
                                       purposes: Set(group.compactMap(\.purpose)))
        }.sorted {
            if $0.opposesDisplaySleep != $1.opposesDisplaySleep { return $0.opposesDisplaySleep }
            return ($0.process, $0.pid) < ($1.process, $1.pid)
        }
    }

    /// Unknown policy/observation is never reported as a confirmed mismatch.
    public static func globalMismatch(expected: Bool?, observed: Bool?) -> Bool {
        guard let expected, let observed else { return false }
        return expected != observed
    }
}

