import AppKit
import Foundation
import os
import SwiftUI
import TetherCore

/// The app's unified log, collected by `tether diagnose` and the diagnostic report. Events are
/// logged at notice level: info messages stay in memory and never reach `log show`.
let appLog = Logger(subsystem: TetherPaths.logSubsystem, category: "app")

/// The menu bar app's state. The power rule itself lives in the helper; the app shows what it is
/// doing, changes its settings through the control file, and owns what needs the user's session:
/// keeping the screen unlocked, dimming, turning an idle screen off, and notifications.
///
/// How the state reads is in `AppModel+Presentation`, the safety settings in `AppModel+Safety`,
/// diagnostics in `AppModel+Diagnostics`. Notifications, the update check and changes outside
/// the app bundle are `Notifier`, `UpdateChecker` and `SystemIntegration`.
@MainActor
final class AppModel: ObservableObject {
    /// The running app's model, shared with URL handling.
    static let shared = AppModel()

    // MARK: State from the helper

    @Published private(set) var snapshot = SystemProbe.snapshot()
    @Published private(set) var status: Status?
    @Published private(set) var usage: Usage?
    @Published private(set) var helperInstalled = false
    /// The helper rewrote its status within the last 90 seconds (it does so at least every 30).
    @Published private(set) var helperResponding = false

    // MARK: Settings in the control file, which the helper enforces

    /// Clamshell mode: connecting power turns it on by itself. Off leaves the lid to macOS.
    @Published private(set) var enabled = true
    /// Stricter battery-hold limits.
    @Published private(set) var limits = UserLimits()
    /// Low Power Mode during a battery hold (`Control.holdLowPower`).
    @Published private(set) var holdLowPower = true
    @Published private(set) var heatGuard = HeatGuardSettings.standard
    /// Who armed the current battery hold (see `Control.holdSource`).
    @Published private(set) var holdSource: String?
    /// The helper logs every check (see `Control.debugLog`).
    @Published private(set) var debugLogging = false

    // MARK: App settings

    @Published var idleBlankMinutes: Int {
        didSet { defaults.set(idleBlankMinutes, forKey: Key.idleBlankMinutes) }
    }
    /// Lock the screen when the lid closes, instead of keeping the session unlocked.
    @Published var lidCloseLocks: Bool {
        didSet {
            defaults.set(lidCloseLocks, forKey: Key.lidCloseLocks)
            refresh()
        }
    }
    @Published var notifyHoldEnd: Bool { didSet { defaults.set(notifyHoldEnd, forKey: Key.notifyHoldEnd) } }
    @Published var notifyHeat: Bool { didSet { defaults.set(notifyHeat, forKey: Key.notifyHeat) } }
    @Published var notifyToggle: Bool { didSet { defaults.set(notifyToggle, forKey: Key.notifyToggle) } }
    @Published var notifySleepDrain: Bool { didSet { defaults.set(notifySleepDrain, forKey: Key.notifySleepDrain) } }
    @Published var sessionNotifications: Bool {
        didSet { defaults.set(sessionNotifications, forKey: Key.sessionNotifications) }
    }
    @Published var checkUpdates: Bool {
        didSet {
            defaults.set(checkUpdates, forKey: Key.checkUpdates)
            if checkUpdates { checkForUpdates(force: true) } else { availableUpdate = nil }
        }
    }
    /// The smaller panel: the state module and one row of controls.
    @Published var panelCompact: Bool { didSet { defaults.set(panelCompact, forKey: Key.panelCompact) } }
    /// The hold countdown and the heat temperature next to the menu bar icon.
    @Published var menuBarDetails: Bool { didSet { defaults.set(menuBarDetails, forKey: Key.menuBarDetails) } }
    /// English, Korean, or whatever macOS uses. The `tether` command follows it too.
    @Published var language: LanguageChoice {
        didSet {
            defaults.set(language == .system ? nil : language.rawValue, forKey: Localization.defaultsKey)
            Localization.current = language.language
        }
    }

    // MARK: Everything else

    @Published private(set) var launchAtLogin = false
    @Published var errorText: String?
    /// A newer release on GitHub, e.g. "2.0.1".
    @Published private(set) var availableUpdate: String?
    /// A diagnostic report is being put together.
    @Published var diagnosticsBusy = false
    /// What happened to the last report ("Copied", "Saved to the Desktop").
    @Published var reportNote: String?

    /// Ticks every second while a battery hold counts down, for the menu bar and the panel.
    let clock = HoldClock()
    /// A laptop with a lid and a battery; on anything else Tether only explains itself.
    let supportedMac = SystemProbe.isSupportedMac

    let defaults = UserDefaults.standard
    private let statusFile = JSONWatch(Status.self, path: TetherPaths.statusPath)
    private let usageFile = JSONWatch(Usage.self, path: TetherPaths.usagePath)
    private let controlFile = JSONWatch(Control.self, path: TetherPaths.controlPath)
    private let screenGuard = ScreenGuard()
    private var notifier: Notifier?
    private var observers: [Any] = []
    private var timer: Timer?
    private var sleepWait: Timer?

    private enum Key {
        static let idleBlankMinutes = "idleBlankMinutes"
        static let sessionNotifications = "sessionNotifications"
        static let menuBarDetails = "menuBarDetails"
        static let panelCompact = "panelCompact"
        static let lidCloseLocks = "lidCloseLocks"
        static let notifyHoldEnd = "notifyHoldEnd"
        static let notifyHeat = "notifyHeat"
        static let notifyToggle = "notifyToggle"
        static let notifySleepDrain = "notifySleepDrain"
        static let checkUpdates = "checkUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let onboarded = "onboarded"
        static let launchAtLoginConfigured = "launchAtLoginConfigured"
    }

    static let idleChoices = [0, 5, 10, 20, 30]

    /// The app's own version; `TetherPaths.version` is the helper's.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? TetherPaths.version
    }

    /// `preview` reads live state once, with no timers, notifications or side effects; `sample`
    /// adds made-up usage and `holdSample` a running battery hold, to check the design.
    init(preview: Bool = false, sample: Bool = false, holdSample: Bool = false) {
        if !preview { Self.migrateDefaults() }
        defaults.register(defaults: [Key.idleBlankMinutes: 10, Key.sessionNotifications: true, Key.menuBarDetails: true,
                                     Key.lidCloseLocks: false, Key.notifyHoldEnd: true, Key.notifyHeat: true,
                                     Key.notifyToggle: true, Key.notifySleepDrain: true, Key.checkUpdates: true])
        idleBlankMinutes = defaults.integer(forKey: Key.idleBlankMinutes)
        lidCloseLocks = defaults.bool(forKey: Key.lidCloseLocks)
        notifyHoldEnd = defaults.bool(forKey: Key.notifyHoldEnd)
        notifyHeat = defaults.bool(forKey: Key.notifyHeat)
        notifyToggle = defaults.bool(forKey: Key.notifyToggle)
        notifySleepDrain = defaults.bool(forKey: Key.notifySleepDrain)
        sessionNotifications = defaults.bool(forKey: Key.sessionNotifications)
        checkUpdates = defaults.bool(forKey: Key.checkUpdates)
        panelCompact = defaults.bool(forKey: Key.panelCompact)
        menuBarDetails = defaults.bool(forKey: Key.menuBarDetails)
        language = Localization.savedChoice
        launchAtLogin = SystemIntegration.launchAtLogin
        readState()
        if preview {
            if sample {
                // Screenshots show the defaults, not this Mac's own choices.
                usage = SampleData.usage()
                limits = UserLimits()
                heatGuard = .standard
                holdLowPower = true
                debugLogging = false
            }
            if holdSample, let status {
                self.status = SampleData.holding(status)
                helperResponding = true
            }
            return
        }
        start()
    }

    /// Wiring for the running app: timers, notifications, the login item and the first checks.
    private func start() {
        appLog.notice("started v\(Self.appVersion, privacy: .public) at \(Bundle.main.bundlePath, privacy: .public)")
        refresh()
        reportAppPath()
        // Keeping the screen unlocked and dimming live in this app, so it comes back after every login.
        if supportedMac, !defaults.bool(forKey: Key.launchAtLoginConfigured) {
            setLaunchAtLogin(true)
            defaults.set(true, forKey: Key.launchAtLoginConfigured)
        } else if launchAtLogin, !isTranslocated {
            SystemIntegration.updateLoginItemIfNeeded()
        }
        // The helper posts a notification whenever it writes its status, which it does on every
        // power, lid or thermal change and at least every 30 seconds; the timer only turns an
        // idle screen off on time and notices a helper that stopped.
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1
        self.timer = timer
        observers.append(DarwinNotification(observing: TetherPaths.statusChanged) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        })
        let center = NotificationCenter.default
        // A display plugged in or out changes whether the built-in screen is dimmed.
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenGuard.releaseAll() }
        })
        screenGuard.onBlankChange = { [weak self] in self?.objectWillChange.send() }
        notifier = Notifier(status: status, usage: usage)
        checkForUpdates(force: false)
    }

    // MARK: Reading state

    func refresh() {
        readState()
        screenGuard.update(clamshellActive: clamshellActive, lidClosed: snapshot.lidClosed,
                           idleBlankMinutes: idleBlankMinutes, lockOnLidClose: lidCloseLocks)
        notifier?.check(status: status, usage: usage, lidClosed: snapshot.lidClosed,
                        choices: .init(holdEnd: notifyHoldEnd, heat: notifyHeat, sleepDrain: notifySleepDrain,
                                       sessions: sessionNotifications))
        notifier?.checkHelper(installed: helperInstalled, responding: helperResponding)
        checkForUpdates(force: false)
    }

    /// Reads only the files that changed and publishes only the values that changed, so an idle
    /// menu bar and panel are not redrawn on every tick.
    private func readState() {
        assign(\.snapshot, SystemProbe.snapshot())
        if statusFile.reload() { status = statusFile.value }
        if usageFile.reload() { usage = usageFile.value }
        assign(\.helperInstalled, FileManager.default.fileExists(atPath: TetherPaths.helperPlistPath))
        assign(\.helperResponding, status.map { Date().timeIntervalSince1970 - $0.updatedAt < 90 } ?? false)
        if controlFile.reload(), let control = controlFile.value {
            assign(\.enabled, control.enabled)
            assign(\.limits, control.limits ?? UserLimits())
            assign(\.holdLowPower, control.holdLowPower ?? true)
            assign(\.heatGuard, control.heatGuard ?? .standard)
            assign(\.holdSource, control.batteryHoldUntil == nil ? nil : control.holdSource)
            assign(\.debugLogging, control.debugLog == true)
        }
        clock.run(until: batteryHoldUntil)
    }

    private func assign<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Clamshell mode is on right now (AC, or a battery hold): helper alive, switched on, sleep disabled.
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

    /// The installed helper predates this app build and should be reinstalled.
    var helperOutdated: Bool {
        guard helperInstalled, let status else { return false }
        return status.version != TetherPaths.version
    }

    /// Other apps' power assertions, e.g. an AI app's "prevent sleep" setting.
    func sleepBlockers() -> [SleepBlocker] {
        SystemProbe.sleepBlockers(excluding: [getpid()]).filter { $0.process != "Tether" && !$0.process.hasPrefix("local.tether") }
    }

    // MARK: Identity and location

    /// Until 2.0 the bundle identifier was `local.tether`; carry its settings over once.
    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != "local.tether", !defaults.bool(forKey: "migratedFromLocalTether") else { return }
        if let old = defaults.persistentDomain(forName: "local.tether") {
            for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: "local.tether")
        }
        defaults.set(true, forKey: "migratedFromLocalTether")
    }

    /// macOS runs an app opened straight from a download at a random temporary path (App
    /// Translocation). The helper and the login item must not point there.
    var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// Tells the helper where this app lives, so it can remove itself if the app is thrown away.
    private func reportAppPath() {
        guard helperInstalled, !isTranslocated, let path = Bundle.main.executablePath,
              ControlStore.read().appPath != path else { return }
        ControlStore.update { $0.appPath = path }
    }

    // MARK: First run

    /// The welcome window is due: it has never been shown.
    var needsOnboarding: Bool { !defaults.bool(forKey: Key.onboarded) }

    func finishOnboarding() { defaults.set(true, forKey: Key.onboarded) }

    // MARK: Commands

    func setEnabled(_ on: Bool) {
        appLog.notice("clamshell mode switched \(on ? "on" : "off", privacy: .public)")
        save { ControlStore.setEnabled(on) }
    }

    func startBatteryHold(minutes: Int, source: String = "app") {
        guard canStartHold else {
            errorText = L("A battery hold needs more charge than the floor. ", "배터리 유지는 하한선보다 충전돼 있어야 해요. ") + holdBlockedReason
            return
        }
        save { ControlStore.startHold(minutes: minutes, source: source) }
    }

    func cancelBatteryHold() {
        save { ControlStore.cancelHold() }
    }

    /// Fraction of the hold still left, for the progress ring and bar.
    func holdRemainingFraction(at date: Date) -> Double {
        guard let until = batteryHoldUntil, let since = status?.batteryHoldSince else { return 1 }
        let total = until.timeIntervalSince1970 - since
        guard total > 0 else { return 1 }
        return min(1, max(0, until.timeIntervalSince(date) / total))
    }

    /// `tether://sleep`: asks for sleep once input settles (at most 3 s), so the key press that
    /// ran the shortcut does not cancel it (see `UserInput.settled`).
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

    /// `tether://…` URLs from Shortcuts, scripts or a browser.
    func handle(url: URL) {
        appLog.notice("url \(url.absoluteString, privacy: .public)")
        guard let command = TetherCommand.parse(url: url) else { return }
        switch command {
        case .status: break
        case .on, .off, .toggle:
            let on = command == .toggle ? !enabled : command == .on
            setEnabled(on)
            if notifyToggle, errorText == nil {
                notifier?.post(title: on ? L("Clamshell mode is on", "클램쉘 모드를 켰습니다") : L("Clamshell mode is off", "클램쉘 모드를 껐습니다"),
                               body: on ? L("On power, closing the lid won't sleep the Mac.", "전원이 연결돼 있으면 덮개를 닫아도 잠들지 않아요.")
                                        : L("Closing the lid will sleep the Mac.", "이제 덮개를 닫으면 잠들어요."))
            }
        case .sleep: sleepNow()
        case .hold(let minutes): startBatteryHold(minutes: minutes, source: "url")
        case .cancelHold: cancelBatteryHold()
        }
    }

    /// Writes the control file, then reads the state back.
    func save(_ write: () -> Bool) {
        guard write() else {
            errorText = L("Couldn't save the setting. Try reinstalling the helper.", "설정을 저장하지 못했습니다. 도우미를 다시 설치해 보세요.")
            return
        }
        errorText = nil
        readState()
    }

    // MARK: Updates

    /// Asks GitHub for the latest release at most once a day, or now when forced.
    func checkForUpdates(force: Bool) {
        guard checkUpdates else { return }
        let last = defaults.double(forKey: Key.lastUpdateCheck)
        guard force || Date().timeIntervalSince1970 - last > 86_400 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: Key.lastUpdateCheck)
        Task {
            guard let latest = await UpdateChecker.latestVersion() else { return }
            availableUpdate = Version.isNewer(latest, than: Self.appVersion) ? latest : nil
        }
    }

    func openReleases() {
        NSWorkspace.shared.open(UpdateChecker.releasesURL)
    }

    // MARK: Outside the app

    func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: TetherPaths.helperLog))
    }

    /// System Settings panes Tether's settings point to.
    enum MacSettings: String {
        case notifications = "com.apple.Notifications-Settings.extension?id="
        case loginItems = "com.apple.LoginItems-Settings.extension"
        case battery = "com.apple.Battery-Settings.extension"
        case lockScreen = "com.apple.Lock-Screen-Settings.extension"
    }

    func open(_ page: MacSettings) {
        let suffix = page == .notifications ? (Bundle.main.bundleIdentifier ?? "") : ""
        guard let url = URL(string: "x-apple.systempreferences:" + page.rawValue + suffix) else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLogin(_ on: Bool) {
        if attempt({ try SystemIntegration.setLaunchAtLogin(on) }) { launchAtLogin = on }
    }

    var cliLocation: String? { SystemIntegration.cliLocation }
    var cliInstalled: Bool { cliLocation != nil }

    func setCLIInstalled(_ on: Bool) {
        attempt { try SystemIntegration.setCLIInstalled(on) }
        objectWillChange.send()
    }

    func installHelper() {
        guard !isTranslocated else {
            errorText = Problem.translocated.message
            return
        }
        let installed = attempt { try SystemIntegration.runScript("install-helper.sh") }
        refresh()
        guard installed else { return }
        appLog.notice("helper installed from \(Bundle.main.bundlePath, privacy: .public)")
        reportAppPath()
    }

    func uninstallHelper() {
        attempt { try SystemIntegration.runScript("uninstall-helper.sh") }
        refresh()
    }

    /// Removes everything Tether put on this Mac: the helper and its watchdog (restoring normal
    /// sleep), their files, the login item, the `tether` link, preferences, and finally the app
    /// itself (to the Trash).
    func uninstallEverything() {
        guard attempt({ try SystemIntegration.runScript("uninstall-helper.sh") }) else { return }
        screenGuard.releaseAll()
        setLaunchAtLogin(false)
        if cliLocation == SystemIntegration.userCLIPath { try? FileManager.default.removeItem(atPath: SystemIntegration.userCLIPath) }
        defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? TetherPaths.bundleID)
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// Runs a change outside the app and shows its failure in the panel; a cancelled password
    /// prompt is not a failure.
    @discardableResult
    private func attempt(_ change: () throws -> Void) -> Bool {
        do {
            try change()
            errorText = nil
            return true
        } catch SystemIntegration.Failure.cancelled {
            return false
        } catch SystemIntegration.Failure.message(let text) {
            errorText = text
            appLog.error("\(text, privacy: .public)")
            return false
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }
}

extension Color {
    /// The icon's mint, used for the "clamshell on" state.
    static let tetherMint = Color(red: 0.20, green: 0.78, blue: 0.62)
}
