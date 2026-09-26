import AppKit
import Foundation
import SwiftUI
import TetherCore
import UserNotifications

/// Menu bar state. The rule itself lives in the helper; the app shows it, edits settings, and
/// owns everything that needs the user's session: no-lock, dimming, blanking, hotkeys, alerts.
@MainActor
final class AppModel: ObservableObject {
    /// The running app's model, shared with URL handling.
    static let shared = AppModel()

    @Published private(set) var snapshot = SystemProbe.snapshot()
    @Published private(set) var status: Status?
    @Published private(set) var usage: Usage?
    @Published private(set) var enabled = true
    @Published private(set) var helperInstalled = false
    @Published private(set) var launchAtLogin = false
    @Published var errorText: String?
    /// A newer release on GitHub, e.g. "2.0.1".
    @Published private(set) var availableUpdate: String?

    @Published var idleBlankMinutes: Int {
        didSet { UserDefaults.standard.set(idleBlankMinutes, forKey: Key.idleBlankMinutes) }
    }
    @Published var hotkeysEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hotkeysEnabled, forKey: Key.hotkeysEnabled)
            applyHotkeys()
        }
    }
    /// Custom shortcuts; actions left out use their defaults.
    @Published private(set) var hotkeyCombos: [HotKeys.Action: KeyCombo]
    /// Lock the screen when the lid closes, instead of keeping the session unlocked.
    @Published var lidCloseLocks: Bool {
        didSet {
            UserDefaults.standard.set(lidCloseLocks, forKey: Key.lidCloseLocks)
            refresh()
        }
    }
    @Published var notifyHoldEnd: Bool {
        didSet { UserDefaults.standard.set(notifyHoldEnd, forKey: Key.notifyHoldEnd) }
    }
    @Published var notifyHeat: Bool {
        didSet { UserDefaults.standard.set(notifyHeat, forKey: Key.notifyHeat) }
    }
    @Published var notifyToggle: Bool {
        didSet { UserDefaults.standard.set(notifyToggle, forKey: Key.notifyToggle) }
    }
    @Published var notifySleepDrain: Bool {
        didSet { UserDefaults.standard.set(notifySleepDrain, forKey: Key.notifySleepDrain) }
    }
    @Published var checkUpdates: Bool {
        didSet {
            UserDefaults.standard.set(checkUpdates, forKey: Key.checkUpdates)
            if checkUpdates { checkForUpdates(force: true) } else { availableUpdate = nil }
        }
    }
    /// Stricter battery-hold limits and the heat guard live in the control file, since the
    /// helper enforces them.
    @Published private(set) var limits = UserLimits()
    @Published private(set) var heatGuard = HeatGuardSettings.standard
    @Published var sessionNotifications: Bool {
        didSet { UserDefaults.standard.set(sessionNotifications, forKey: Key.sessionNotifications) }
    }
    /// The smaller panel: state and one row of round buttons.
    @Published var panelCompact: Bool {
        didSet { UserDefaults.standard.set(panelCompact, forKey: Key.panelCompact) }
    }
    /// Hold countdown and heat-guard temperature next to the menu bar symbol.
    @Published var menuBarDetails: Bool {
        didSet { UserDefaults.standard.set(menuBarDetails, forKey: Key.menuBarDetails) }
    }
    @Published private var dismissedSessionEnd: Double {
        didSet { UserDefaults.standard.set(dismissedSessionEnd, forKey: Key.dismissedSessionEnd) }
    }

    private var timer: Timer?
    private var statusObserver: DarwinNotification?
    private var terminateObserver: NSObjectProtocol?
    private let screenGuard = ScreenGuard()
    private var hotKeys: HotKeys?
    private var helperDownSince: Date?
    private var helperDownNotified = false
    private var sleepWait: Timer?

    private enum Key {
        static let idleBlankMinutes = "idleBlankMinutes"
        static let hotkeysEnabled = "hotkeysEnabled"
        static let sessionNotifications = "sessionNotifications"
        static let menuBarDetails = "menuBarDetails"
        static let panelCompact = "panelCompact"
        static let hotkeyCombos = "hotkeyCombos"
        static let lidCloseLocks = "lidCloseLocks"
        static let notifyHoldEnd = "notifyHoldEnd"
        static let notifyHeat = "notifyHeat"
        static let notifyToggle = "notifyToggle"
        static let notifySleepDrain = "notifySleepDrain"
        static let checkUpdates = "checkUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let onboarded = "onboarded"
        static let lastNotifiedSleep = "lastNotifiedSleep"
        static let dismissedSessionEnd = "dismissedSessionEnd"
        static let lastNotifiedHoldEnd = "lastNotifiedHoldEnd"
        static let lastNotifiedSessionEnd = "lastNotifiedSessionEnd"
        static let lastNotifiedThermalAlert = "lastNotifiedThermalAlert"
        static let launchAtLoginConfigured = "launchAtLoginConfigured"
    }

    static let idleChoices = [0, 5, 10, 20, 30]
    static let repository = "jukqaz/tether"
    static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    static let projectURL = URL(string: "https://github.com/\(repository)")!

    /// The app's own version; `TetherPaths.version` is the helper's, used for the update check.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? TetherPaths.version
    }

    static let launchAgentLabel = "local.tether.app"
    static var launchAgentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    /// A laptop with a lid and a battery; on anything else Tether only explains itself.
    let supportedMac = SystemProbe.isSupportedMac

    /// `preview` reads live state once without timers, notifications or side effects; `sample`
    /// adds made-up usage (a recent lid session, a week of bars) to check the design.
    init(preview: Bool = false, sample: Bool = false) {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Key.idleBlankMinutes: 10, Key.hotkeysEnabled: true,
                                     Key.sessionNotifications: true, Key.menuBarDetails: true,
                                     Key.lidCloseLocks: false, Key.notifyHoldEnd: true, Key.notifyHeat: true,
                                     Key.notifyToggle: true, Key.notifySleepDrain: true, Key.checkUpdates: true])
        idleBlankMinutes = defaults.integer(forKey: Key.idleBlankMinutes)
        hotkeysEnabled = defaults.bool(forKey: Key.hotkeysEnabled)
        sessionNotifications = defaults.bool(forKey: Key.sessionNotifications)
        menuBarDetails = defaults.bool(forKey: Key.menuBarDetails)
        panelCompact = defaults.bool(forKey: Key.panelCompact)
        lidCloseLocks = defaults.bool(forKey: Key.lidCloseLocks)
        notifyHoldEnd = defaults.bool(forKey: Key.notifyHoldEnd)
        notifyHeat = defaults.bool(forKey: Key.notifyHeat)
        notifyToggle = defaults.bool(forKey: Key.notifyToggle)
        notifySleepDrain = defaults.bool(forKey: Key.notifySleepDrain)
        checkUpdates = defaults.bool(forKey: Key.checkUpdates)
        hotkeyCombos = Self.loadCombos()
        dismissedSessionEnd = defaults.double(forKey: Key.dismissedSessionEnd)
        if preview {
            readState()
            launchAtLogin = FileManager.default.fileExists(atPath: Self.launchAgentPath)
            if sample { usage = Self.sampleUsage() }
            return
        }

        refresh()
        launchAtLogin = FileManager.default.fileExists(atPath: Self.launchAgentPath)
        // No-lock and dimming live in this app, so it should come back after every login.
        if supportedMac, !defaults.bool(forKey: Key.launchAtLoginConfigured) {
            setLaunchAtLogin(true)
            defaults.set(true, forKey: Key.launchAtLoginConfigured)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        statusObserver = DarwinNotification(observing: TetherPaths.statusChanged) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenGuard.releaseAll() }
        }
        screenGuard.onBlankChange = { [weak self] in self?.objectWillChange.send() }

        hotKeys = HotKeys { [weak self] action in self?.perform(action) }
        applyHotkeys()

        // Report only what happens from now on, not old items found at first launch.
        for (key, value) in [(Key.lastNotifiedHoldEnd, status?.lastHoldEndAt),
                             (Key.lastNotifiedSessionEnd, usage?.recentSessions.last?.end),
                             (Key.lastNotifiedThermalAlert, status?.thermalAlertAt),
                             (Key.lastNotifiedSleep, usage?.sleeps.recent.last?.wokeAt)]
        where defaults.object(forKey: key) == nil {
            defaults.set(value ?? Date().timeIntervalSince1970, forKey: key)
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        checkForUpdates(force: false)
    }

    private static func sampleUsage() -> Usage {
        let now = Date()
        var stats = StatsTracker()
        let hours = [3.2, 0, 5.5, 1.1, 7.8, 2.4, 4.6]
        let closedPeaks = [34.8, 0, 36.1, 33.2, 37.4, 34.0, 35.2]
        let openPeaks = [37.9, 36.4, 39.2, 35.8, 38.6, 37.1, 36.8]
        for offset in 0..<7 {
            let day = now.addingTimeInterval(Double(offset - 6) * 86_400)
            var closed = TempStats()
            if hours[offset] > 0 {
                closed.add(closedPeaks[offset] - 3, seconds: hours[offset] * 3000)
                closed.add(closedPeaks[offset], seconds: hours[offset] * 600)
            }
            var open = TempStats()
            open.add(openPeaks[offset] - 5, seconds: 5 * 3600)
            open.add(openPeaks[offset], seconds: 1800)
            stats.days.append(DayStats(day: StatsTracker.dayKey(day), lidClosedSeconds: hours[offset] * 3600,
                                       forcedSleeps: offset == 6 ? 2 : 0, heatGuards: offset == 4 ? 1 : 0,
                                       closedTemps: hours[offset] > 0 ? closed : nil, openTemps: open,
                                       holdSeconds: offset == 3 ? 5400 : nil, holdDrain: offset == 3 ? 18 : nil,
                                       closedMaxThermal: offset == 4 ? 2 : 1))
        }
        let end = now.addingTimeInterval(-600).timeIntervalSince1970
        let sessions = [
            LidSession(start: end - 86_400 * 2 - 7200, end: end - 86_400 * 2, lastSeen: end - 86_400 * 2,
                       maxTemperature: 36.1, maxThermal: 1, batteryStart: 80, batteryEnd: 80, lowPower: false,
                       onBattery: false),
            LidSession(start: end - 86_400 - 5400, end: end - 86_400, lastSeen: end - 86_400, maxTemperature: 33.2,
                       maxThermal: 0, batteryStart: 80, batteryEnd: 62, lowPower: true, onBattery: true),
            LidSession(start: end - 83 * 60, end: end, lastSeen: end, maxTemperature: 38.2, maxThermal: 1,
                       batteryStart: 80, batteryEnd: 80, lowPower: true, onBattery: false),
        ]
        var sleeps = SleepLog()
        for (daysAgo, hours, before, after, reason, tether, wake) in [
            (2.0, 7.5, 84, 81, "Clamshell Sleep", false, "EC.LidOpen"),
            (1.0, 3.2, 80, 69, "Software Sleep", true, "smc.sysState.Wake wifibt"),
            (0.4, 8.1, 80, 77, "Clamshell Sleep", false, "UserActivity Assertion"),
        ] as [(Double, Double, Int, Int, String, Bool, String)] {
            let sleptAt = now.timeIntervalSince1970 - daysAgo * 86_400 - hours * 3600
            var record = SleepRecord(sleptAt: sleptAt, percentBefore: before, onBatteryBefore: true, byTether: tether)
            record.wokeAt = sleptAt + hours * 3600
            record.percentAfter = after
            record.onBatteryAfter = true
            record.sleepReason = reason
            record.wakeReason = wake
            record.darkWakes = tether ? 4 : 1
            sleeps.recent.append(record)
        }
        return Usage(stats: stats, recentSessions: sessions, sleepLog: sleeps)
    }

    private func readState() {
        snapshot = SystemProbe.snapshot()
        status = JSONFile.read(Status.self, from: TetherPaths.statusPath)
        usage = JSONFile.read(Usage.self, from: TetherPaths.usagePath)
        helperInstalled = FileManager.default.fileExists(atPath: TetherPaths.helperPlistPath)
        if let control = JSONFile.read(Control.self, from: TetherPaths.controlPath) {
            enabled = control.enabled
            limits = control.limits ?? UserLimits()
            heatGuard = control.heatGuard ?? .standard
        }
    }

    func refresh() {
        readState()
        screenGuard.update(clamshellActive: clamshellActive, lidClosed: snapshot.lidClosed,
                           idleBlankMinutes: idleBlankMinutes, lockOnLidClose: lidCloseLocks)
        notifyHoldEndIfNeeded()
        notifySessionIfNeeded()
        notifyHeatIfNeeded()
        notifySleepDrainIfNeeded()
        checkHelperHealth()
        checkForUpdates(force: false)
    }

    // MARK: First run

    /// The welcome window is due: never shown, or the helper still missing on a laptop.
    var needsOnboarding: Bool {
        !UserDefaults.standard.bool(forKey: Key.onboarded)
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Key.onboarded)
    }

    // MARK: Notifications

    /// After a hold ended (and a closed Mac was put to sleep), say why once the Mac is back.
    private func notifyHoldEndIfNeeded() {
        guard let status, let reason = status.lastHoldEnd, reason != .cancelled,
              let at = status.lastHoldEndAt, isNew(at, Key.lastNotifiedHoldEnd), notifyHoldEnd else { return }
        let time = Date(timeIntervalSince1970: at).formatted(date: .omitted, time: .shortened)
        post(title: L("Battery hold ended", "배터리 유지를 끝냈습니다"),
             body: L("\(time) · \(reason.displayReason). If the lid was closed, the Mac was put to sleep.",
                     "\(time) · \(reason.displayReason). 덮개가 닫혀 있었다면 Mac을 잠재웠습니다."))
    }

    /// When the lid opens after a long closed stretch, summarise it.
    private func notifySessionIfNeeded() {
        guard !snapshot.lidClosed, let session = usage?.recentSessions.last, let end = session.end,
              isNew(end, Key.lastNotifiedSessionEnd), sessionNotifications else { return }
        post(title: L("While the lid was closed", "덮개를 닫아 둔 동안"), body: Texts.session(session))
    }

    /// Critical thermal pressure for minutes with the lid closed on AC: worth interrupting for,
    /// e.g. over a remote desktop session.
    private func notifyHeatIfNeeded() {
        guard let at = status?.thermalAlertAt, isNew(at, Key.lastNotifiedThermalAlert), notifyHeat else { return }
        post(title: L("Your Mac is very hot", "Mac이 매우 뜨겁습니다"),
             body: L("Heat has been critical for over 3 minutes with the lid closed. Low Power Mode is on; open the lid or ease the workload.",
                     "덮개를 닫은 채 발열 '위험' 단계가 3분 넘게 이어지고 있어요. 저전력 모드를 켰지만, 덮개를 열거나 작업을 줄여 주세요."))
    }

    /// Sleep that cost more than it should (1–2 %/h is typical): say how much and what woke it.
    private func notifySleepDrainIfNeeded() {
        guard let last = lastSleep, let woke = last.wokeAt, isNew(woke, Key.lastNotifiedSleep), notifySleepDrain,
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

    /// Records `timestamp` as handled; true when it is newer than the last one handled.
    private func isNew(_ timestamp: Double, _ key: String) -> Bool {
        guard timestamp > UserDefaults.standard.double(forKey: key) else { return false }
        UserDefaults.standard.set(timestamp, forKey: key)
        return true
    }

    /// A helper disabled in Login Items, or broken by an OS update, would otherwise fail silently.
    private func checkHelperHealth() {
        guard helperInstalled, !helperResponding else {
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

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Updates

    /// Asks GitHub for the latest release at most once a day (or now, when forced).
    func checkForUpdates(force: Bool) {
        guard checkUpdates else { return }
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: Key.lastUpdateCheck)
        guard force || Date().timeIntervalSince1970 - last > 86_400 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: Key.lastUpdateCheck)
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        Task {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            availableUpdate = Version.isNewer(latest, than: Self.appVersion) ? latest : nil
        }
    }

    func openReleases() {
        NSWorkspace.shared.open(Self.releasesURL)
    }

    // MARK: State

    /// Clamshell mode is on right now (AC, or a battery hold): helper alive, Tether on, sleep disabled.
    var clamshellActive: Bool {
        helperInstalled && helperResponding && enabled && snapshot.sleepDisabled
    }

    /// Deadline of the armed battery hold, as the helper reports it.
    var batteryHoldUntil: Date? {
        guard helperResponding, let until = status?.batteryHoldUntil else { return nil }
        return Date(timeIntervalSince1970: until)
    }

    var holdingOnBattery: Bool { batteryHoldUntil != nil && snapshot.power == .battery }

    /// Low Power Mode is on because the closed Mac ran hot on AC.
    var heatGuardActive: Bool { helperResponding && status?.heatGuard == true }

    var screenBlank: Bool { screenGuard.isBlank }

    var holdsDisplayAwake: Bool { screenGuard.holdsDisplayAwake }

    /// One line for the settings window: is the helper there, alive, current?
    var helperStatus: (text: String, color: Color) {
        if !helperInstalled { return (L("not installed", "설치되지 않음"), .orange) }
        guard helperResponding, let status else { return (L("not responding", "응답 없음"), .red) }
        if helperOutdated { return (L("needs an update · v\(status.version)", "업데이트 필요 · v\(status.version)"), .orange) }
        return (L("running · v\(status.version)", "실행 중 · v\(status.version)"), .green)
    }

    /// Other apps' power assertions, e.g. an AI app's "prevent sleep" setting.
    func sleepBlockers() -> [SleepBlocker] {
        SystemProbe.sleepBlockers(excluding: [getpid()]).filter { $0.process != "Tether" && !$0.process.hasPrefix("local.tether") }
    }

    /// "Screen off" makes sense only while clamshell mode keeps a visible screen from locking.
    var canBlank: Bool {
        clamshellActive && !lidCloseLocks
            && ScreenPolicy.screenVisible(lidClosed: snapshot.lidClosed, externalDisplay: Displays.hasExternal)
    }

    /// The installed helper predates this app build and should be reinstalled.
    var helperOutdated: Bool {
        guard helperInstalled, let status else { return false }
        return status.version != TetherPaths.version
    }

    /// The helper rewrites its status at least every 30 seconds.
    var helperResponding: Bool {
        guard let status else { return false }
        return Date().timeIntervalSince1970 - status.updatedAt < 90
    }

    // MARK: Display

    /// The Tether mark for the clamshell states, an SF Symbol where a symbol says it better.
    enum Icon: Equatable {
        case mark(TetherGlyph.Style)
        case symbol(String)
    }

    /// What the panel's main module shows: one state, its colour and icon.
    struct Presentation {
        let title: String
        let subtitle: String
        let icon: Icon
        let color: Color
        let menuBarIcon: Icon
    }

    var presentation: Presentation {
        if !supportedMac {
            return Presentation(title: L("Not a MacBook", "MacBook이 아님"),
                                subtitle: L("Tether needs a lid and a battery; this Mac's sleep is left alone",
                                            "덮개와 배터리가 있어야 해요. 이 Mac의 잠자기는 건드리지 않아요"),
                                icon: .mark(.disabled), color: .gray, menuBarIcon: .mark(.disabled))
        }
        if !helperInstalled {
            return Presentation(title: L("Helper needed", "도우미 설치 필요"),
                                subtitle: L("Install it once to apply the power rules", "전원 규칙을 적용하려면 한 번 설치해 주세요"),
                                icon: .symbol("wrench.and.screwdriver.fill"), color: .gray,
                                menuBarIcon: .symbol("exclamationmark.triangle"))
        }
        if !helperResponding {
            return Presentation(title: L("Helper not responding", "도우미 응답 없음"),
                                subtitle: L("The power rules aren't being applied right now", "지금은 전원 규칙이 적용되지 않아요"),
                                icon: .symbol("exclamationmark.triangle.fill"), color: .red,
                                menuBarIcon: .symbol("exclamationmark.triangle"))
        }
        if !enabled {
            return Presentation(title: L("Tether off", "Tether 꺼짐"),
                                subtitle: L("macOS default · closing the lid sleeps", "macOS 기본 동작 · 덮개를 닫으면 잠들어요"),
                                icon: .mark(.disabled), color: .gray, menuBarIcon: .mark(.disabled))
        }
        if holdingOnBattery {
            return Presentation(title: L("Holding on battery", "배터리로 유지 중"),
                                subtitle: L("Sleeps on its own if it gets hot or time runs out", "뜨거워지거나 시간이 끝나면 알아서 잠들어요"),
                                icon: .symbol("bag.fill"), color: .orange, menuBarIcon: .symbol("bag.fill"))
        }
        if snapshot.sleepDisabled, heatGuardActive {
            let critical = thermalLevel >= 3
            return Presentation(title: critical ? L("Critical heat", "발열 위험") : L("Heat guard on", "발열 보호 중"),
                                subtitle: L("Running hot with the lid closed, cooling with Low Power Mode",
                                            "덮개가 닫힌 채 뜨거워져 저전력 모드로 식히는 중이에요"),
                                icon: .symbol(critical ? "flame.fill" : "thermometer.high"),
                                color: critical ? .red : .orange, menuBarIcon: .symbol("thermometer.high"))
        }
        if snapshot.sleepDisabled {
            return Presentation(title: L("Clamshell on", "클램쉘 켜짐"),
                                subtitle: L("Close the lid: no sleep, no lock", "덮개를 닫아도 잠들지도, 잠기지도 않아요"),
                                icon: .mark(.on), color: .tetherMint,
                                menuBarIcon: batteryHoldUntil == nil ? .mark(.on) : .symbol("bag"))
        }
        return Presentation(title: L("Clamshell off", "클램쉘 꺼짐"),
                            subtitle: L("On battery · closing the lid sleeps", "배터리 사용 중 · 덮개를 닫으면 잠들어요"),
                            icon: .mark(.off), color: .blue, menuBarIcon: .mark(.off))
    }

    /// The status item: an icon, plus a short text when something is worth watching.
    struct MenuBarItem: Equatable {
        let icon: Icon
        let text: String?
    }

    var menuBarItem: MenuBarItem {
        guard menuBarDetails else { return MenuBarItem(icon: presentation.menuBarIcon, text: nil) }
        if holdingOnBattery, let until = batteryHoldUntil {
            return MenuBarItem(icon: .symbol("bag.fill"), text: Texts.countdown(until.timeIntervalSinceNow))
        }
        if clamshellActive, snapshot.lidClosed, heatGuardActive || thermalLevel >= 2 {
            let text = status?.batteryTemperature.map { "\(Int($0.rounded()))°" } ?? Texts.thermal(thermalLevel)
            return MenuBarItem(icon: .symbol(thermalLevel >= 3 ? "flame.fill" : "thermometer.high"), text: text)
        }
        return MenuBarItem(icon: presentation.menuBarIcon, text: nil)
    }

    /// Something the user has to act on, shown as a banner above everything else.
    enum Problem {
        case missing, down, outdated, error(String)

        var title: String {
            switch self {
            case .missing: L("The helper isn't installed", "도우미가 설치되지 않았어요")
            case .down: L("The helper isn't responding", "도우미가 응답하지 않아요")
            case .outdated: L("The helper needs an update", "도우미 업데이트가 필요해요")
            case .error: L("That didn't work", "작업을 마치지 못했어요")
            }
        }

        var message: String {
            switch self {
            case .missing: L("It installs with your administrator password, once.", "관리자 비밀번호를 한 번 입력하면 설치돼요.")
            case .down: L("It may be off in Login Items, or stopped after a macOS update.", "로그인 항목에서 꺼졌거나 macOS 업데이트 뒤 멈췄을 수 있어요.")
            case .outdated: L("An older helper than this app is running.", "앱보다 오래된 도우미가 실행 중이에요.")
            case .error(let text): text
            }
        }

        var action: String? {
            switch self {
            case .missing: L("Install Helper…", "도우미 설치…")
            case .down: L("Reinstall…", "다시 설치…")
            case .outdated: L("Update…", "업데이트…")
            case .error: nil
            }
        }

        var color: Color {
            switch self {
            case .down, .error: .red
            case .missing, .outdated: .orange
            }
        }
    }

    var problem: Problem? {
        if let errorText { return .error(errorText) }
        guard supportedMac else { return nil }
        if !helperInstalled { return .missing }
        if !helperResponding { return .down }
        if helperOutdated { return .outdated }
        return nil
    }

    // MARK: Tiles

    var powerValue: String {
        switch snapshot.power {
        case .ac: L("Power", "연결됨")
        case .battery: L("Battery", "배터리")
        case .unknown: L("Checking", "확인 중")
        }
    }

    var powerSymbol: String { snapshot.power == .ac ? "powerplug.fill" : "battery.75percent" }

    var percentText: String {
        (status?.batteryPercent ?? SystemProbe.batteryPercent()).map { "\($0)%" } ?? "–"
    }

    var lidDetail: String {
        if !snapshot.lidClosed { return screenBlank ? L("screen off", "화면 꺼짐") : L("screen on", "화면 켜짐") }
        if Displays.hasExternal { return L("external display", "외장 모니터") }
        return clamshellActive ? L("dimmed", "화면 어둡게") : L("asleep", "잠자는 중")
    }

    var temperatureValue: String {
        guard let t = status?.batteryTemperature ?? SystemProbe.batteryTemperature() else { return "–" }
        return String(format: "%.1f°", t)
    }

    var thermalLevel: Int { status?.thermal ?? ProcessInfo.processInfo.thermalState.rawValue }

    var thermalLabel: String {
        heatGuardActive ? L("Low Power Mode", "저전력 모드") : L("heat ", "발열 ") + Texts.thermal(thermalLevel)
    }

    /// The same in as few characters as possible, for the status module's narrow rows.
    var thermalShort: String {
        heatGuardActive ? L("Low Power", "저전력 모드") : L(Texts.thermal(thermalLevel), "발열 " + Texts.thermal(thermalLevel))
    }

    var thermalColor: Color {
        switch thermalLevel {
        case 0: .green
        case 1: .yellow
        case 2: .orange
        default: .red
        }
    }

    // MARK: Sessions and stats

    /// The last lid session, shown for an hour after it ended unless dismissed.
    var visibleSession: LidSession? {
        guard let session = usage?.recentSessions.last, let end = session.end,
              end > dismissedSessionEnd, Date().timeIntervalSince1970 - end < 3600,
              !snapshot.lidClosed else { return nil }
        return session
    }

    func dismissSession() {
        dismissedSessionEnd = usage?.recentSessions.last?.end ?? Date().timeIntervalSince1970
    }

    var today: DayStats { (usage?.stats ?? StatsTracker()).today(now: Date()) }
    var sleepLog: SleepLog { usage?.sleeps ?? SleepLog() }
    var lastSleep: SleepRecord? { sleepLog.recent.last }
    var week: [DayStats] { (usage?.stats ?? StatsTracker()).week(now: Date()) }

    // MARK: Battery hold

    func startBatteryHold(minutes: Int) {
        save { ControlStore.startHold(minutes: minutes) }
    }

    func cancelBatteryHold() {
        save { ControlStore.cancelHold() }
    }

    /// Fraction of the hold still left, for the progress ring.
    func holdRemainingFraction(at date: Date) -> Double {
        guard let until = batteryHoldUntil, let since = status?.batteryHoldSince else { return 1 }
        let total = until.timeIntervalSince1970 - since
        guard total > 0 else { return 1 }
        return min(1, max(0, until.timeIntervalSince(date) / total))
    }

    var lastEventText: String? {
        guard let status, let event = status.lastEvent, let at = status.lastEventAt else { return nil }
        let time = Date(timeIntervalSince1970: at).formatted(date: .omitted, time: .shortened)
        return "\(time) · \(event.displayText)"
    }

    func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: TetherPaths.helperLog))
    }

    /// System Settings panes Tether's settings point to.
    enum MacSettings: String {
        case notifications = "com.apple.Notifications-Settings.extension?id=local.tether"
        case loginItems = "com.apple.LoginItems-Settings.extension"
        case battery = "com.apple.Battery-Settings.extension"
        case lockScreen = "com.apple.Lock-Screen-Settings.extension"
    }

    func open(_ page: MacSettings) {
        guard let url = URL(string: "x-apple.systempreferences:" + page.rawValue) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Commands

    func setEnabled(_ on: Bool) {
        save { ControlStore.setEnabled(on) }
    }

    /// Asks for sleep once input settles (at most 3 s), so the click or hotkey that asked does
    /// not cancel it (see `UserInput.settled`).
    func sleepNow() {
        guard sleepWait == nil else { return }
        let asked = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                guard UserInput.settled() || Date().timeIntervalSince(asked) > 3 else { return }
                timer.invalidate()
                self.sleepWait = nil
                self.save { ControlStore.sleepNow() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepWait = timer
    }

    func blankScreen() {
        guard screenGuard.blankNow() else { return }
        objectWillChange.send()
    }

    private func save(_ write: () -> Bool) {
        guard write() else {
            errorText = L("Couldn't save the setting. Try reinstalling the helper.", "설정을 저장하지 못했습니다. 도우미를 다시 설치해 보세요.")
            return
        }
        errorText = nil
        readState()
    }

    /// Hotkeys: the panel is closed, so a toggle confirms itself with a notification.
    private func perform(_ action: HotKeys.Action) {
        switch action {
        case .sleepNow: sleepNow()
        case .blank: blankScreen()
        case .toggle: run(enabled ? .off : .on, confirm: true)
        }
    }

    /// `tether://…` URLs from Shortcuts, scripts, the `tether blank` command or a browser.
    func handle(url: URL) {
        guard let command = TetherCommand.parse(url: url) else { return }
        run(command, confirm: true)
    }

    private func run(_ command: TetherCommand, confirm: Bool) {
        switch command {
        case .status: break
        case .on, .off, .toggle:
            let on = command == .toggle ? !enabled : command == .on
            setEnabled(on)
            if confirm, notifyToggle, errorText == nil {
                post(title: on ? L("Tether is on", "Tether를 켰습니다") : L("Tether is off", "Tether를 껐습니다"),
                     body: on ? L("On power, closing the lid won't sleep the Mac.", "전원이 연결돼 있으면 덮개를 닫아도 잠들지 않아요.")
                              : L("Closing the lid will sleep the Mac.", "이제 덮개를 닫으면 잠들어요."))
            }
        case .sleep: sleepNow()
        case .blank: blankScreen()
        case .hold(let minutes): startBatteryHold(minutes: minutes)
        case .cancelHold: cancelBatteryHold()
        }
    }

    var hotkeysUnavailable: [HotKeys.Action] { hotKeys?.unavailable ?? [] }

    func combo(for action: HotKeys.Action) -> KeyCombo { hotkeyCombos[action] ?? action.defaultCombo }

    /// Returns false when another Tether action already uses the combination.
    @discardableResult
    func setCombo(_ combo: KeyCombo, for action: HotKeys.Action) -> Bool {
        let taken = HotKeys.Action.allCases.contains { other in
            other != action && self.combo(for: other).keyCode == combo.keyCode
                && self.combo(for: other).modifiers == combo.modifiers
        }
        guard !taken else { return false }
        hotkeyCombos[action] = combo == action.defaultCombo ? nil : combo
        saveCombos()
        applyHotkeys()
        return true
    }

    func resetCombos() {
        hotkeyCombos = [:]
        saveCombos()
        applyHotkeys()
    }

    /// While a new shortcut is being recorded, so pressing a current one does not fire it.
    func suspendHotkeys(_ suspended: Bool) {
        hotKeys?.apply(hotkeyCombos, enabled: hotkeysEnabled && !suspended)
        objectWillChange.send()
    }

    private func applyHotkeys() {
        hotKeys?.apply(hotkeyCombos, enabled: hotkeysEnabled)
        objectWillChange.send()
    }

    private static func loadCombos() -> [HotKeys.Action: KeyCombo] {
        guard let data = UserDefaults.standard.data(forKey: Key.hotkeyCombos),
              let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, combo in
            HotKeys.Action(rawValue: key).map { ($0, combo) }
        })
    }

    private func saveCombos() {
        let stored = Dictionary(uniqueKeysWithValues: hotkeyCombos.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Key.hotkeyCombos)
    }

    // MARK: Safety settings

    var batteryFloor: Int { SafetyPolicy.floor(limits) }
    var maxHoldMinutes: Int { Int(SafetyPolicy.maxHold(limits) / 60) }

    /// 30 min, 1 h, 2 h under the maximum set in Settings, then the maximum itself.
    var holdChoices: [Int] {
        let longest = maxHoldMinutes
        return [30, 60, 120].filter { $0 < longest } + [longest]
    }

    func safetyLimits(lidClosed: Bool) -> SafetyLimits { SafetyPolicy.limits(lidClosed: lidClosed, user: limits) }

    func setLimits(_ new: UserLimits) {
        save { ControlStore.update { $0.limits = new.isDefault ? nil : new } }
    }

    func setHeatGuard(_ new: HeatGuardSettings) {
        save { ControlStore.update { $0.heatGuard = new == .standard ? nil : new } }
    }

    func resetSafety() {
        save {
            ControlStore.update {
                $0.limits = nil
                $0.heatGuard = nil
            }
        }
    }

    // MARK: Data-based settings

    /// The last seven days of measurements.
    var summary: UsageSummary { UsageSummary(week: week, sessions: usage?.recentSessions ?? []) }

    struct Recommendations: Equatable {
        var closedLid: Advice<Double>?
        var openLid: Advice<Double>?
        var maxHold: Advice<Double>?
        var heatLevel: Advice<Int>?

        var isEmpty: Bool { closedLid == nil && openLid == nil && maxHold == nil && heatLevel == nil }
    }

    var recommendations: Recommendations {
        let s = summary
        return Recommendations(closedLid: Advisor.closedLidLimit(s), openLid: Advisor.openLidLimit(s),
                               maxHold: Advisor.maxHold(s, floor: batteryFloor), heatLevel: Advisor.heatGuardLevel(s))
    }

    /// Whether applying the recommendations would change anything.
    var recommendationsDiffer: Bool {
        let r = recommendations
        let closed = safetyLimits(lidClosed: true).hardTemperature
        let open = safetyLimits(lidClosed: false).hardTemperature
        return (r.closedLid.map { $0.value != closed } ?? false)
            || (r.openLid.map { $0.value != open } ?? false)
            || (r.maxHold.map { $0.value != SafetyPolicy.maxHold(limits) / 3600 } ?? false)
            || (r.heatLevel.map { heatGuard.enabled && $0.value != heatGuard.threshold } ?? false)
    }

    func applyRecommendations() {
        let r = recommendations
        var new = limits
        if let a = r.closedLid { new.closedLidMaxTemperature = a.value == SafetyPolicy.closedLid.hardTemperature ? nil : a.value }
        if let a = r.openLid { new.openLidMaxTemperature = a.value == SafetyPolicy.openLid.hardTemperature ? nil : a.value }
        if let a = r.maxHold { new.maxHoldHours = a.value == SafetyPolicy.maxHold / 3600 ? nil : a.value }
        var guardSettings = heatGuard
        if let a = r.heatLevel { guardSettings.level = a.value }
        save {
            ControlStore.update {
                $0.limits = new.isDefault ? nil : new
                $0.heatGuard = guardSettings == .standard ? nil : guardSettings
            }
        }
    }

    // MARK: Settings

    /// A per-user LaunchAgent works without a Developer ID signature, unlike SMAppService.
    func setLaunchAtLogin(_ on: Bool) {
        let url = URL(fileURLWithPath: Self.launchAgentPath)
        if on {
            let plist: [String: Any] = [
                "Label": Self.launchAgentLabel,
                "ProgramArguments": [Bundle.main.executablePath ?? "/Applications/Tether.app/Contents/MacOS/Tether"],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    .write(to: url, options: .atomic)
            } catch {
                errorText = L("Couldn't create the login item: \(error.localizedDescription)",
                              "로그인 항목을 만들지 못했습니다: \(error.localizedDescription)")
                return
            }
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        launchAtLogin = on
    }

    // MARK: Terminal command

    /// Per-user `~/.local/bin` needs no password; `/usr/local/bin` is on every PATH but needs one.
    static let userCLIPath = NSHomeDirectory() + "/.local/bin/tether"
    static let systemCLIPath = "/usr/local/bin/tether"
    private var cliBinaryPath: String { Bundle.main.bundlePath + "/Contents/Helpers/tether" }

    /// Where the `tether` link points into this app, if anywhere.
    var cliLocation: String? {
        [Self.userCLIPath, Self.systemCLIPath].first { path in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: path))?.hasSuffix("Tether.app/Contents/Helpers/tether") == true
        }
    }

    var cliInstalled: Bool { cliLocation != nil }

    /// Links `tether` into `~/.local/bin` when that folder exists (it is on PATH for many
    /// developers), otherwise into `/usr/local/bin` with an administrator prompt.
    func setCLIInstalled(_ on: Bool) {
        let fm = FileManager.default
        errorText = nil
        if !on {
            if cliLocation == Self.userCLIPath { try? fm.removeItem(atPath: Self.userCLIPath) }
            if cliLocation == Self.systemCLIPath { runPrivileged(command: "rm -f " + Self.shellQuoted(Self.systemCLIPath)) }
            objectWillChange.send()
            return
        }
        guard fm.fileExists(atPath: cliBinaryPath) else {
            errorText = L("The tether command isn't in this app. Run a Tether.app built with scripts/build.sh.",
                          "앱 안에 tether 명령이 없습니다. build.sh로 만든 Tether.app에서 실행하세요.")
            return
        }
        let userBin = (Self.userCLIPath as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: userBin, isDirectory: &isDirectory), isDirectory.boolValue {
            let existing = try? fm.destinationOfSymbolicLink(atPath: Self.userCLIPath)
            if existing == nil, fm.fileExists(atPath: Self.userCLIPath) {
                errorText = L("\(Self.userCLIPath) already exists and wasn't touched.", "\(Self.userCLIPath) 파일이 이미 있어 건드리지 않았습니다.")
                return
            }
            do {
                if existing != nil { try fm.removeItem(atPath: Self.userCLIPath) }
                try fm.createSymbolicLink(atPath: Self.userCLIPath, withDestinationPath: cliBinaryPath)
            } catch {
                errorText = L("Couldn't install the command: \(error.localizedDescription)", "터미널 명령을 설치하지 못했습니다: \(error.localizedDescription)")
            }
        } else {
            runPrivileged(command: "mkdir -p /usr/local/bin && ln -sf " + Self.shellQuoted(cliBinaryPath) + " "
                          + Self.shellQuoted(Self.systemCLIPath))
        }
        objectWillChange.send()
    }

    // MARK: Helper install and removal

    func installHelper() { runPrivileged(script: "install-helper.sh") }
    func uninstallHelper() { runPrivileged(script: "uninstall-helper.sh") }

    /// Removes everything Tether put on this Mac: the helper (restoring normal sleep), its files,
    /// the login item, the `tether` link, preferences, and finally the app itself (to the Trash).
    func uninstallEverything() {
        guard runPrivileged(script: "uninstall-helper.sh") else { return }
        screenGuard.releaseAll()
        setLaunchAtLogin(false)
        if cliLocation == Self.userCLIPath { try? FileManager.default.removeItem(atPath: Self.userCLIPath) }
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "local.tether")
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// Runs a bundled script as root after the standard administrator password prompt.
    @discardableResult
    private func runPrivileged(script: String) -> Bool {
        guard let path = Bundle.main.path(forResource: script, ofType: nil) else {
            errorText = L("\(script) is missing. Run a Tether.app built with scripts/build.sh.",
                          "\(script)을 찾을 수 없습니다. build.sh로 만든 Tether.app에서 실행하세요.")
            return false
        }
        return runPrivileged(command: "/bin/sh " + Self.shellQuoted(path))
    }

    @discardableResult
    private func runPrivileged(command: String) -> Bool {
        let source = "do shell script \(Self.appleScriptQuoted(command)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        defer { refresh() }
        guard let error else {
            errorText = nil
            return true
        }
        if (error[NSAppleScript.errorNumber] as? Int) != -128 {  // -128: the user cancelled
            errorText = (error[NSAppleScript.errorMessage] as? String) ?? L("The helper task failed.", "도우미 작업에 실패했습니다.")
        }
        return false
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension Color {
    /// The icon's mint, used for the "clamshell on" state.
    static let tetherMint = Color(red: 0.20, green: 0.78, blue: 0.62)
}
