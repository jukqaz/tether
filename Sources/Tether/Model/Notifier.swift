import Foundation
import TetherCore

/// Current-session edges are kept in memory; legacy helper timestamps use defaults.
/// Both routes seed current state without replay, and consume disabled events.
@MainActor
final class Notifier {
    /// What Settings › Notifications allows.
    struct Choices {
        var heat: Bool
        var battery: Bool
    }

    private let defaults: UserDefaults
    private let delivery: (String, String) -> Void
    private var helperDownSince: Date?
    private var helperDownNotified = false
    private var sessionEvents = SessionNotificationEvents()

    private enum Key {
        static let holdEnd = "lastNotifiedHoldEnd"
        static let heat = "lastNotifiedThermalAlert"
        static let overheat = "lastNotifiedOverheatSleep"
        static let weakCharger = "lastNotifiedWeakChargerSleep"
    }

    /// Starts from what is already recorded, so only what happens from now on is reported.
    init(status: Status?, defaults: UserDefaults = .standard, deliver: ((String, String) -> Void)? = nil) {
        self.defaults = defaults
        self.delivery = deliver ?? { NotificationSettingsMonitor.deliver(title: $0, body: $1) }
        for (key, value) in [(Key.holdEnd, status?.lastHoldEndAt),
                             (Key.heat, status?.thermalAlertAt), (Key.overheat, status?.overheatSleepAt),
                             (Key.weakCharger, status?.weakChargerSleepAt)] {
            if let value, value.isFinite, value > defaults.double(forKey: key) {
                defaults.set(value, forKey: key)
            } else if defaults.object(forKey: key) == nil {
                defaults.set(Date().timeIntervalSince1970, forKey: key)
            }
        }
    }

    func check(status: Status?, choices: Choices) {
        let thermalNotified = overheated(status, allowed: choices.heat)
        let batteryNotified = chargerTooWeak(status, allowed: choices.battery)
        holdProtection(status, choices: choices, thermalNotified: thermalNotified, batteryNotified: batteryNotified)
    }

    func checkWork(_ status: UserSessionStatus, choices: Choices, now: Double = ContinuousTime.now) {
        let events = sessionEvents.observe(status, choices: .init(thermal: choices.heat, battery: choices.battery), now: now)
        for case .protection(let reason) in events {
            let title = reason == "thermal" ? L("Stopped for thermal protection", "열 보호로 유지를 중단했습니다")
                : reason == "sensor" ? L("Stopped because observations are unavailable", "관측값을 확인할 수 없어 유지를 중단했습니다")
                : L("Stopped for battery protection", "배터리 보호로 유지를 중단했습니다")
            post(title: title,
                 body: protectionReason(reason) + " " + L("Review Protection in Tether settings. Recovery does not restart ended manual sessions.",
                     "Tether 설정의 기기 보호를 확인하세요. 회복되어도 끝난 수동 세션은 다시 켜지지 않습니다."))
        }
    }

    /// Legacy helpers retain the end reason for protection feedback after wake.
    private func holdProtection(_ status: Status?, choices: Choices, thermalNotified: Bool, batteryNotified: Bool) {
        guard let status, let reason = status.lastHoldEnd,
              let at = status.lastHoldEndAt, isNew(at, Key.holdEnd) else { return }
        let allowed: Bool
        switch reason {
        case .heat, .thermal, .sensor: allowed = choices.heat && !thermalNotified
        case .battery: allowed = choices.battery && !batteryNotified
        case .time, .cancelled: return
        }
        guard allowed else { return }
        let time = Texts.time(Date(timeIntervalSince1970: at))
        post(title: L("Tether stopped for protection", "기기 보호로 Tether 유지를 중단했습니다"),
             body: L("\(time) · \(reason.displayReason). Sleep was requested if the lid was closed.",
                     "\(time) · \(reason.displayReason). 덮개가 닫혀 있었다면 잠자기를 요청했습니다."))
    }

    /// One notification per protection decision. Own release is distinct from system Sleep.
    private func overheated(_ status: Status?, allowed: Bool) -> Bool {
        let newCritical = status?.thermalAlertAt.map { isNew($0, Key.heat) } ?? false
        let newSleep = status?.overheatSleepAt.map { isNew($0, Key.overheat) } ?? false
        guard allowed else { return false }
        if newSleep, let at = status?.overheatSleepAt {
            let time = Texts.time(Date(timeIntervalSince1970: at))
            post(title: L("Tether stopped for thermal protection", "발열 보호로 Tether 유지를 중단했습니다"),
                 body: L("\(time) · macOS thermal pressure ended Tether's closed-lid session. Other apps' work requests remain unchanged. Let it cool before resuming.",
                         "\(time) · macOS 발열 상태에 따라 Tether의 덮개 유지를 종료했습니다. 다른 앱의 작업 요청은 유지합니다. 식힌 뒤 다시 켜 주세요."))
        } else if newCritical {
            post(title: L("Critical thermal pressure", "시스템 발열 위험"),
                 body: L("macOS reported critical thermal pressure. Tether ends managed closed-lid operation without an added grace period.",
                         "macOS가 시스템 발열 위험을 보고했습니다. Tether는 별도의 대기 없이 관리 중인 닫힌 덮개 유지를 종료합니다."))
        } else { return false }
        return true
    }

    /// The weak-charger decision ended Tether's own session, regardless of actual OS Sleep.
    private func chargerTooWeak(_ status: Status?, allowed: Bool) -> Bool {
        guard let at = status?.weakChargerSleepAt, isNew(at, Key.weakCharger), allowed else { return false }
        let time = Texts.time(Date(timeIntervalSince1970: at))
        post(title: L("Tether stopped to protect the battery", "배터리 보호로 Tether 유지를 중단했습니다"),
             body: L("\(time) · The battery reached its floor and continued draining on power with the lid closed. Check the power adapter, cable and workload.",
                     "\(time) · 전원이 연결되어 있지만 닫힌 덮개에서 배터리 잔량이 하한까지 계속 줄었습니다. 어댑터·케이블과 작업 부하를 확인하세요."))
        return true
    }

    /// A helper disabled in Login Items, or broken by an OS update, would otherwise fail silently.
    func checkHelper(installed: Bool, responding: Bool) {
        guard installed, !responding else {
            helperDownSince = nil
            helperDownNotified = false
            return
        }
        let since = helperDownSince ?? Date()
        helperDownSince = since
        guard !helperDownNotified, Date().timeIntervalSince(since) > 120 else { return }
        helperDownNotified = true
        post(title: L("Tether's helper stopped", "Tether 도우미가 멈췄습니다"),
             body: L("Closed-lid control cannot be confirmed. Check the helper in Tether's settings.",
                     "덮개 제어를 확인할 수 없습니다. Tether 설정에서 도우미를 점검해 주세요."))
    }

    func post(title: String, body: String) {
        delivery(title, body)
    }

    /// Records `timestamp` as handled; true when it is newer than the last one handled.
    private func isNew(_ timestamp: Double, _ key: String) -> Bool {
        guard timestamp > defaults.double(forKey: key) else { return false }
        defaults.set(timestamp, forKey: key)
        return true
    }
}
