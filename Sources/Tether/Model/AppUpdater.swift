import AppKit
import Sparkle
import TetherCore

struct AppUpdateStatus {
    var availableVersion: String?
    var checking = false
    var sessionInProgress = false
    var waitingForOpenLid = false
    var lastChecked: Date?
    var error: String?
}

/// Sparkle owns signed downloads, replacement and UI. Tether accepts stable releases,
/// quiet reminders and a fresh lid check before giving up its power-management session.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private(set) var engine: SPUUpdater?
    private(set) var userDriver: UpdateUserDriver?
    private var observation: NSKeyValueObservation?
    private var status = AppUpdateStatus()
    private let changed: (AppUpdateStatus) -> Void
    private let gate: UpdateRelaunchGate
    private let hostBundle: Bundle
    private let defaults: UserDefaults
    var installationPreflight: (() -> Bool)?
    init(hostBundle: Bundle = .main, defaults: UserDefaults = .standard, lidClosed: @escaping () -> Bool? = {
        // A confirmed desktop has no lid. Unknown hardware/read failure is still unknown.
        SystemProbe.capabilities.hardware == .desktop ? false : SystemProbe.observedLidClosed
    }, changed: @escaping (AppUpdateStatus) -> Void) {
        self.gate = UpdateRelaunchGate(lidClosed: lidClosed)
        self.hostBundle = hostBundle
        self.defaults = defaults
        self.changed = changed
    }
    var canTerminateForUpdate: Bool { gate.canTerminateForUpdate }
    var installationRequested: Bool { gate.installationRequested }
    var automaticallyChecks: Bool {
        get { engine?.automaticallyChecksForUpdates ?? false }
        set { engine?.automaticallyChecksForUpdates = newValue }
    }
    func start(automatically: Bool) {
        guard engine == nil else { return }
        if hostBundle == .main {
            guard hostBundle.bundleIdentifier == TetherPaths.bundleID,
                  TetherPaths.serviceSocket == TetherPaths.productionSocket else { return }
        }
        defaults.removeObject(forKey: "updateChannel")
        // Sparkle ignores the download setter while automatic checks are disabled.
        // Clear the persisted choice before initialization so enabling checks later
        // cannot silently restore an old install-on-quit preference.
        defaults.set(false, forKey: "SUAutomaticallyUpdate")
        let driver = makeUserDriver()
        userDriver = driver
        let value = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle, userDriver: driver, delegate: self)
        engine = value
        // Remove legacy preferences pinned to a single beta release.
        value.clearFeedURLFromUserDefaults()
        value.automaticallyChecksForUpdates = automatically
        value.automaticallyDownloadsUpdates = false
        observation = value.observe(\.sessionInProgress, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status.sessionInProgress = updater.sessionInProgress
                self.publish()
            }
        }
        do { try value.start() }
        catch { status.error = error.localizedDescription; publish(); return }
        status.lastChecked = value.lastUpdateCheckDate
        publish()
    }
    /// Building the adapter alone neither starts Sparkle nor touches an updater session.
    func makeUserDriver() -> UpdateUserDriver {
        return UpdateUserDriver(hostBundle: hostBundle, delegate: self,
            accepts: { UpdateReleasePolicy.accepts(candidateChannel: $0) },
            rejected: { [weak self] in
                guard let self else { return }
                self.status.availableVersion = nil
                self.status.checking = false
                self.status.error = L("The pending update was canceled. Check again for a stable release.",
                                      "대기 중인 업데이트를 취소했습니다. 정식 업데이트를 다시 확인해 주세요.")
                self.publish()
            }, preparingInstallation: { [weak self] in self?.gate.markInstallationRequested() },
            observedCandidate: { [weak self] item in self?.observeCandidate(item) },
            mayInstall: { [weak self] in
                guard let self else { return false }
                return self.installationPreflight?() ?? true
            })
    }

    func check() {
        guard let engine, engine.canCheckForUpdates else { return }
        status.error = nil; status.checking = !engine.sessionInProgress; publish()
        engine.checkForUpdates()
    }
    func resumeInstallation() {
        guard installationPreflight?() ?? true else { return }
        _ = gate.resume(); publish()
    }
    private func disableAutomaticDownloads() {
        // Sparkle's setter is ignored while checks are disabled. Clear the
        // persisted flag as well so cancel/re-enable cannot revive this mode.
        defaults.set(false, forKey: "SUAutomaticallyUpdate")
        engine?.automaticallyDownloadsUpdates = false
    }

    private func observeCandidate(_ item: SUAppcastItem) {
        status.checking = false; status.error = nil
        status.lastChecked = Date(); status.availableVersion = item.displayVersionString
        publish()
    }
    private func publish() { status.waitingForOpenLid = gate.waiting; changed(status) }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        status.availableVersion = update.displayVersionString; publish()
    }
    func standardUserDriverWillFinishUpdateSession() {
        status.availableVersion = nil
        publish()
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        observeCandidate(item)
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        disableAutomaticDownloads()
        status.availableVersion = nil; status.error = nil; status.lastChecked = Date(); publish()
    }
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        // From extraction onwards Sparkle may have an installer watching for app termination.
        gate.markInstallationRequested()
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        gate.markInstallationRequested()
        if FileManager.default.fileExists(atPath: TetherPaths.helperPlistPath) {
            defaults.set(true, forKey: "helperUpgradePending")
        }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let postponed = gate.postpone(installHandler); publish(); return postponed
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        disableAutomaticDownloads()
        updater.automaticallyDownloadsUpdates = false
        status.checking = false
        if let error, !((error as NSError).domain == SUSparkleErrorDomain && (error as NSError).code == SUError.noUpdateError.rawValue) {
            status.error = error.localizedDescription
            appLog.error("Update cycle failed: \(error.localizedDescription, privacy: .public)")
        }
        gate.finish(); publish()
    }
}
