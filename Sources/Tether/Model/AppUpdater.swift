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
    var candidateBuild: String?
    var packageIdentity: String?
    var packageVerified = false
    var readyToInstall = false
    var authenticationRequired = false
}

/// Sparkle owns signed downloads, replacement and UI. Tether supplies channel selection,
/// quiet reminders and a fresh lid check before giving up its power-management session.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private(set) var engine: SPUUpdater?
    private(set) var userDriver: UpdateUserDriver?
    private var observation: NSKeyValueObservation?
    private var channel = UpdateChannel.stable
    private var status = AppUpdateStatus()
    private let changed: (AppUpdateStatus) -> Void
    private let gate: UpdateRelaunchGate
    private let hostBundle: Bundle
    private let defaults: UserDefaults
    private let requiresAuthentication: () -> Bool
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var preparationReply: ((SPUUserUpdateChoice) -> Void)?
    private var reservedPackageIdentity: String?
    private var readyPackageIdentity: String?
    var deferUntilWorkEnds = false
    var installationPreflight: (() -> Bool)?
    init(hostBundle: Bundle = .main, defaults: UserDefaults = .standard, lidClosed: @escaping () -> Bool? = {
        // A confirmed desktop has no lid. Unknown hardware/read failure is still unknown.
        SystemProbe.capabilities.hardware == .desktop ? false : SystemProbe.observedLidClosed
    }, requiresAuthentication: (() -> Bool)? = nil, changed: @escaping (AppUpdateStatus) -> Void) {
        self.gate = UpdateRelaunchGate(lidClosed: lidClosed)
        self.hostBundle = hostBundle
        self.defaults = defaults
        self.requiresAuthentication = requiresAuthentication ?? {
            !FileManager.default.isWritableFile(atPath: hostBundle.bundlePath)
                || SystemProbe.capabilities.hardware == .portable
        }
        self.changed = changed
    }
    var canTerminateForUpdate: Bool { gate.canTerminateForUpdate }
    var automaticallyChecks: Bool {
        get { engine?.automaticallyChecksForUpdates ?? false }
        set { engine?.automaticallyChecksForUpdates = newValue }
    }
    func start(automatically: Bool, channel: UpdateChannel) {
        guard engine == nil else { return }
        if hostBundle == .main {
            guard hostBundle.bundleIdentifier == TetherPaths.bundleID,
                  TetherPaths.serviceSocket == TetherPaths.productionSocket else { return }
        }
        self.channel = channel
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
            accepts: { [weak self] in self?.channel.accepts(candidateChannel: $0) == true },
            rejected: { [weak self] in
                guard let self else { return }
                self.status.availableVersion = nil
                self.status.checking = false
                self.status.error = L("A pending update from another channel was canceled. Check again for your selected channel.",
                                      "선택한 채널과 다른 대기 중인 업데이트를 취소했습니다. 업데이트를 다시 확인해 주세요.")
                self.publish()
            }, preparingInstallation: { [weak self] in self?.gate.markInstallationRequested() },
            deferReady: { [weak self] reply in
                self?.holdReadyInstallation(reply) ?? false
            }, deferCandidate: { [weak self] item, state, reply in
                self?.prepareReservedCandidate(item, state: state, reply: reply) ?? false
            }, observedCandidate: { [weak self] item in self?.observeCandidate(item) },
            mayInstall: { [weak self] in
                guard let self else { return false }
                return self.installationPreflight?() ?? true
            })
    }

    /// Never change channel underneath a candidate Sparkle already selected.
    func select(_ channel: UpdateChannel) -> Bool {
        guard engine?.sessionInProgress != true else { return false }
        cancelDeferredInstallation()
        self.channel = channel
        status = AppUpdateStatus(); publish()
        engine?.resetUpdateCycleAfterShortDelay()
        return true
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
    func cancelDeferredInstallation() {
        disableAutomaticDownloads()
        guard deferUntilWorkEnds || readyReply != nil || preparationReply != nil else { return }
        deferUntilWorkEnds = false
        let reply = readyReply, preparation = preparationReply
        readyReply = nil; preparationReply = nil
        reservedPackageIdentity = nil; readyPackageIdentity = nil
        status.readyToInstall = false; status.packageVerified = false
        status.authenticationRequired = false
        gate.finish()
        reply?(.skip)
        preparation?(.skip)
        publish()
    }
    func downloadReservedUpdate() {
        disableAutomaticDownloads()
        guard deferUntilWorkEnds, let identity = status.packageIdentity else { return }
        reservedPackageIdentity = identity
        if readyReply != nil || preparationReply != nil || userDriver?.prepareDeferredCandidate() == true { return }
        guard let engine, engine.canCheckForUpdates, !engine.sessionInProgress else { return }
        // The automatic driver bypasses showReady and leaves install-on-quit
        // armed. A UI-based cycle keeps our exact-candidate/ready replies in control.
        engine.checkForUpdates()
    }
    @discardableResult
    func installVerifiedDeferredUpdate() -> Bool {
        guard let reply = readyReply, status.packageVerified, status.readyToInstall,
              readyPackageIdentity == status.packageIdentity,
              installationPreflight?() == true else { return false }
        readyReply = nil; deferUntilWorkEnds = false
        preparationReply = nil; reservedPackageIdentity = nil; readyPackageIdentity = nil
        status.readyToInstall = false
        disableAutomaticDownloads()
        reply(.install)
        publish()
        return true
    }
    /// Only the separate, explicit Install now confirmation may start a
    /// preparation that could ask for authentication. This is not a ready ACK.
    @discardableResult
    func beginExplicitReservedPreparation() -> Bool {
        guard let reply = preparationReply, reservedPackageIdentity == status.packageIdentity,
              installationPreflight?() == true else { return false }
        preparationReply = nil; reservedPackageIdentity = nil
        deferUntilWorkEnds = false
        disableAutomaticDownloads()
        reply(.install)
        publish()
        return true
    }

    private func disableAutomaticDownloads() {
        // Sparkle's setter is ignored while checks are disabled. Clear the
        // persisted flag as well so cancel/re-enable cannot revive this mode.
        defaults.set(false, forKey: "SUAutomaticallyUpdate")
        engine?.automaticallyDownloadsUpdates = false
    }

    private func prepareReservedCandidate(_ item: SUAppcastItem, state: SPUUserUpdateState,
                                          reply: @escaping (SPUUserUpdateChoice) -> Void) -> Bool {
        guard deferUntilWorkEnds, reservedPackageIdentity == Self.packageIdentity(for: item) else { return false }
        if state.stage == .installing { return holdReadyInstallation(reply) }
        if requiresAuthentication() {
            // Extraction can prompt before showReady. Do not start that prompt
            // from an automatic reservation, or mislabel this candidate verified.
            preparationReply = reply
            status.authenticationRequired = true
            status.packageVerified = false; status.readyToInstall = false
            publish()
        } else { reply(.install) }
        return true
    }

    private func holdReadyInstallation(_ reply: @escaping (SPUUserUpdateChoice) -> Void) -> Bool {
        guard deferUntilWorkEnds, let identity = status.packageIdentity,
              reservedPackageIdentity == identity else { return false }
        preparationReply = nil; readyReply = reply; readyPackageIdentity = identity
        status.packageVerified = true; status.readyToInstall = true
        status.authenticationRequired = requiresAuthentication()
        publish()
        return true
    }

    static func packageIdentity(for item: SUAppcastItem) -> String {
        let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any]
        let signature = enclosure?["sparkle:edSignature"] as? String ?? ""
        return "\(item.versionString)|\(item.fileURL?.absoluteString ?? "")|\(item.contentLength)|\(signature)"
    }

    private func observeCandidate(_ item: SUAppcastItem) {
        let identity = Self.packageIdentity(for: item)
        if status.packageIdentity != identity {
            cancelDeferredInstallation()
            status.packageVerified = false; status.readyToInstall = false
        }
        status.checking = false; status.error = nil
        status.lastChecked = Date(); status.availableVersion = item.displayVersionString
        status.candidateBuild = item.versionString; status.packageIdentity = identity
        publish()
    }
    private func publish() { status.waitingForOpenLid = gate.waiting; changed(status) }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { channel.allowedChannels }
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        status.availableVersion = update.displayVersionString; publish()
    }
    func standardUserDriverWillFinishUpdateSession() {
        if !deferUntilWorkEnds { status.availableVersion = nil }
        publish()
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        observeCandidate(item)
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        cancelDeferredInstallation()
        status.candidateBuild = nil; status.packageIdentity = nil
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
        readyReply = nil; preparationReply = nil
        readyPackageIdentity = nil; reservedPackageIdentity = nil
        deferUntilWorkEnds = false
        status.packageVerified = false; status.readyToInstall = false
        status.authenticationRequired = false
        status.checking = false
        if let error, !((error as NSError).domain == SUSparkleErrorDomain && (error as NSError).code == SUError.noUpdateError.rawValue) {
            status.error = error.localizedDescription
            appLog.error("Update cycle failed: \(error.localizedDescription, privacy: .public)")
        }
        gate.finish(); publish()
    }
}
