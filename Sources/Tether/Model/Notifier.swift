import Foundation
import TetherCore
import UserNotifications

/// macOS notifications. Each item is reported once: the timestamp of the last one reported is
/// remembered, so a relaunch or an unchanged status never repeats a notification. Items are
/// marked as seen even while their notification is off, so turning it on doesn't dig up old ones.
@MainActor
final class Notifier {
    /// What Settings › Notifications allows.
    struct Choices {
        var holdEnd: Bool
        var heat: Bool
        var sleepDrain: Bool
    }

    private let defaults = UserDefaults.standard
    private var helperDownSince: Date?
    private var helperDownNotified = false

    private enum Key {
        static let holdEnd = "lastNotifiedHoldEnd"
        static let heat = "lastNotifiedThermalAlert"
        static let overheat = "lastNotifiedOverheatSleep"
        static let weakCharger = "lastNotifiedWeakChargerSleep"
        static let sleep = "lastNotifiedSleep"
    }

    /// Starts from what is already recorded, so only what happens from now on is reported.
    init(status: Status?, usage: Usage?) {
        for (key, value) in [(Key.holdEnd, status?.lastHoldEndAt),
                             (Key.heat, status?.thermalAlertAt), (Key.overheat, status?.overheatSleepAt),
                             (Key.weakCharger, status?.weakChargerSleepAt),
                             (Key.sleep, usage?.sleeps.recent.last?.wokeAt)]
        where defaults.object(forKey: key) == nil {
            defaults.set(value ?? Date().timeIntervalSince1970, forKey: key)
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(status: Status?, usage: Usage?, lidClosed: Bool, choices: Choices) {
        holdEnded(status, allowed: choices.holdEnd)
        overheated(status, allowed: choices.heat)
        chargerTooWeak(status)
        sleepDrained(usage?.sleeps.recent.last, allowed: choices.sleepDrain)
    }

    /// After a hold ended (and a closed Mac was put to sleep), say why once the Mac is back.
    private func holdEnded(_ status: Status?, allowed: Bool) {
        guard let status, let reason = status.lastHoldEnd, reason != .cancelled,
              let at = status.lastHoldEndAt, isNew(at, Key.holdEnd), allowed else { return }
        let time = Date(timeIntervalSince1970: at).formatted(date: .omitted, time: .shortened)
        post(title: L("Battery hold ended", "배터리 유지를 끝냈습니다"),
             body: L("\(time) · \(reason.displayReason). If the lid was closed, the Mac was put to sleep.",
                     "\(time) · \(reason.displayReason). 덮개가 닫혀 있었다면 Mac을 잠재웠습니다."))
    }

    /// Critical heat with the lid closed on AC: worth interrupting a remote session for; and,
    /// after wake, that overheating put the Mac to sleep.
    private func overheated(_ status: Status?, allowed: Bool) {
        if let at = status?.thermalAlertAt, isNew(at, Key.heat), allowed {
            post(title: L("Your Mac is very hot", "Mac이 매우 뜨겁습니다"),
                 body: L("Heat has been critical for over 3 minutes with the lid closed. Low Power Mode is on; open the lid or ease the workload.",
                         "덮개를 닫은 채 발열 '위험' 단계가 3분 넘게 이어지고 있어요. 저전력 모드를 켰지만, 덮개를 열거나 작업을 줄여 주세요."))
        }
        if let at = status?.overheatSleepAt, isNew(at, Key.overheat), allowed {
            let time = Date(timeIntervalSince1970: at).formatted(date: .omitted, time: .shortened)
            post(title: L("Tether put your Mac to sleep", "Tether가 Mac을 잠재웠습니다"),
                 body: L("\(time) · It was overheating with the lid closed on power and no display attached, as in a bag with a power bank.",
                         "\(time) · 전원이 연결된 채 덮개가 닫혀 있고 모니터도 없이 과열됐어요. 보조배터리를 꽂고 가방에 넣은 경우 등이에요."))
        }
    }

    /// A charger that couldn't keep up let the battery reach the floor, and the Mac was put to sleep.
    /// Always reported: it explains a Mac that slept on power.
    private func chargerTooWeak(_ status: Status?) {
        guard let at = status?.weakChargerSleepAt, isNew(at, Key.weakCharger) else { return }
        let time = Date(timeIntervalSince1970: at).formatted(date: .omitted, time: .shortened)
        post(title: L("Tether put your Mac to sleep", "Tether가 Mac을 잠재웠습니다"),
             body: L("\(time) · The charger couldn't keep up and the battery reached its floor with the lid closed. Use a stronger charger to keep it awake.",
                     "\(time) · 충전기 출력이 부족해 덮개를 닫은 채 배터리가 하한선까지 줄었어요. 계속 깨워 두려면 더 센 충전기를 쓰세요."))
    }

    /// Sleep that cost more than it should (1–2 %/h is typical): say how much and what woke it.
    private func sleepDrained(_ last: SleepRecord?, allowed: Bool) {
        guard let last, let woke = last.wokeAt, isNew(woke, Key.sleep), allowed,
              let drain = last.drainPerHour, drain >= SleepLog.highDrain else { return }
        let span = Texts.duration(last.duration ?? 0)
        let before = last.percentBefore ?? 0, after = last.percentAfter ?? 0
        let wakes = last.darkWakes
        post(title: L("Sleep used a lot of battery", "잠자는 동안 배터리를 많이 썼어요"),
             body: L(String(format: "%.1f%%/h over %@ (%d%% → %d%%). Woken by: %@%@.", drain, span, before, after,
                            Texts.wakeCause(last), wakes > 0 ? ", \(wakes) wakes in between" : ""),
                     String(format: "%@ 동안 시간당 %.1f%% (%d%% → %d%%). 깨운 원인: %@%@.", span, drain, before, after,
                            Texts.wakeCause(last), wakes > 0 ? ", 중간에 \(wakes)번 깸" : "")))
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
             body: L("The power rules aren't being applied. Reinstall the helper from Tether's settings.",
                     "전원 규칙이 적용되지 않고 있습니다. Tether 설정에서 도우미를 다시 설치해 주세요."))
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Records `timestamp` as handled; true when it is newer than the last one handled.
    private func isNew(_ timestamp: Double, _ key: String) -> Bool {
        guard timestamp > defaults.double(forKey: key) else { return false }
        defaults.set(timestamp, forKey: key)
        return true
    }
}
