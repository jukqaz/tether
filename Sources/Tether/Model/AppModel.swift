import AppKit
import Foundation
import os
import SwiftUI
import TetherCore

/// The app's unified log, collected by `tether diagnose` and the diagnostic report. Events are
/// logged at notice level: info messages stay in memory and never reach `log show`.
let appLog = Logger(subsystem: TetherPaths.logSubsystem, category: "app")

/// The transport actor checks this immediately before sending a pending sleep.
/// A newer successful GUI action invalidates it without crossing that actor's queue.
final class ExplicitSleepCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    // The lease has immutable identity/descriptor fields. Retaining it here keeps
    // the descriptor alive for its read-only lstat/fstat check on the IPC actor.
    private let lease: AppCoordinatorLease?
    private let leaseRequired: Bool
    init(lease: AppCoordinatorLease?, leaseRequired: Bool) { self.lease = lease; self.leaseRequired = leaseRequired }
    var isActive: Bool { lock.withLock { active } }
    var hasWriterAuthority: Bool { !leaseRequired || lease?.isValid == true }
    func invalidate() { lock.withLock { active = false } }
}

/// The app owns the common work policy and one native idle assertion. On a verified
/// notebook it grants a finite lid extension to the authenticated helper, which checks
/// its own observations, budgets and OS ownership before applying the extension.
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
    @Published private(set) var protection: ProtectionStatus?
    var developmentService: Bool { TetherPaths.serviceSocket != TetherPaths.productionSocket }
    @Published private(set) var usage: Usage?
    @Published private(set) var helperInstalled = false
    @Published private(set) var missingHelperFiles: [HelperInstallationFile] = []
    @Published private(set) var helperFilesChecked = false
    /// The helper rewrote its status within the last 90 seconds (it does so at least every 30).
    @Published private(set) var helperResponding = false
    /// Wire metadata is independent of the common session's protection banner.
    @Published private var helperProtocolVersion: Int?
    @Published private(set) var helperInstallInFlight = false
    @Published private(set) var helperSetupVerified = false
    @Published private(set) var helperSetupChecked = false
    /// Read-only inspection scope. A screen reconnect must not reuse old remote evidence.
    @Published private(set) var displayRevision: UInt64 = 0
    @Published private(set) var remoteInspectionSessionKey = "unavailable"
    private var remoteInspectionGeneration: UInt64 = 0

    // MARK: Settings in the control file, which the helper enforces

    /// Clamshell mode: connecting power turns it on by itself. Off leaves the lid to macOS.
    @Published private(set) var powerCondition = PowerCondition.ac
    @Published private(set) var automaticHoldMinutes = 60
    @Published private(set) var enabled = true
    /// Explicit battery-hold limits chosen by the user.
    @Published private(set) var limits = UserLimits()
    /// Who armed the current battery hold (see `Control.holdSource`).
    @Published private(set) var holdSource: String?
    /// The helper logs every check (see `Control.debugLog`).
    @Published private(set) var debugLogging = false
    @Published private(set) var debugLogUntil: Double?
    @Published var diagnosticNote: String?

    // MARK: App settings

    @Published var notifyHeat: Bool { didSet { if hasCoordinatorAuthority { defaults.set(notifyHeat, forKey: Key.notifyHeat); refreshV4ConfigurationGeneration() } } }
    @Published var notifyBatteryProtection: Bool { didSet { if hasCoordinatorAuthority { defaults.set(notifyBatteryProtection, forKey: Key.notifyBatteryProtection); refreshV4ConfigurationGeneration() } } }
    @Published var checkUpdates: Bool {
        didSet {
            guard hasCoordinatorAuthority else { return }
            defaults.set(checkUpdates, forKey: Key.checkUpdates)
            if !developmentService { updater.automaticallyChecks = checkUpdates }; refreshV4ConfigurationGeneration()
        }
    }
    /// The smaller panel: the state module and one row of controls.
    @Published var panelCompact: Bool { didSet { if hasCoordinatorAuthority { defaults.set(panelCompact, forKey: Key.panelCompact) } } }
    /// Optional remaining time for a confirmed, finite manual session only.
    @Published var menuBarDetails: Bool { didSet { if hasCoordinatorAuthority { defaults.set(menuBarDetails, forKey: Key.menuBarDetails) } } }
    /// English, Korean, or whatever macOS uses. The `tether` command follows it too.
    @Published var language: LanguageChoice {
        didSet {
            guard hasCoordinatorAuthority else { return }
            defaults.set(language == .system ? nil : language.rawValue, forKey: Localization.defaultsKey)
            Localization.current = language.language
            refreshV4ConfigurationGeneration()
        }
    }

    // MARK: Everything else

    @Published private(set) var launchAtLogin = false
    @Published var errorText: String?
    @Published private(set) var updateStatus = AppUpdateStatus()
    @Published private(set) var updateChannel: UpdateChannel
    var v4PreviousDocument: V4SettingsDocument?
    var v4ConfigurationGeneration: UInt64 = 0
    var v4ImportCandidate: (Data, V4SettingsPreview)?
    var v4ConfigurationTransaction = false
    @Published var v4ManualApprovalPending = false
    @Published var v4SettingsPresentationID = UUID()
    @Published var reviewingManualDeadline = false
    var v4ExpiryEngine = V4ExpiryNoticeEngine()
    let v4NotificationDelivery = V4NotificationDelivery()
    var v4PreviousManualID: UUID?
    var v4ChargerTrend = V4ChargerTrend()
    @Published var v4ACDrainWarning = false
    var v4ObservedTerminalJobs: Set<UUID> = []
    var availableUpdate: String? { updateStatus.availableVersion }
    /// A diagnostic report is being put together.
    @Published var diagnosticsBusy = false
    /// What happened to the last report ("Copied", "Report saved").
    @Published var reportNote: String?
    /// The page the settings window shows, kept while the app runs.
    @Published var settingsPage = SettingsPage.general
    @Published var otherAppDetailsRequested = false
    @Published var localUsageStats = StatsTracker()
    @Published var usageStatisticsIssue: String?
    @Published var closedLidDisplayState: ClosedLidDisplayState = .inactive
    @Published var closedLidDisplaySupport = ClosedLidDisplaySupport(availability: .unavailable)
    var usageStatisticsStore: UsageStatisticsStore?
    var closedLidDisplayDriver: ClosedLidDisplayDriver?
    var updatingSessionFeatures = false

    /// Ticks every second while a battery hold counts down, for the menu bar and the panel.
    let clock = HoldClock()
    let powerRequests = PowerRequestMonitor(simulated: TetherPaths.serviceSocket != TetherPaths.productionSocket)
    let systemSettings: SystemSettingsMonitor
    let notificationSettings: NotificationSettingsMonitor
    @Published private(set) var capabilities: MacCapabilities
    private let capabilitiesProbe: (() -> MacCapabilities)?
    var supportedMac: Bool { capabilities.generalIdleAvailable }
    var hasInternalBattery: Bool { capabilities.internalBattery == true }
    var availablePowerConditions: [PowerCondition] { hasInternalBattery ? PowerCondition.allCases : [.ac] }
    var batteryControlError: String? {
        if hasInternalBattery { return nil }
        return capabilities.internalBattery == false ? "notApplicable" : "batteryCapabilityUnavailable"
    }
    var usesUserSession: Bool { userSession != nil }
    var sessionAvailable: Bool { hasCoordinatorAuthority && (usesUserSession || (helperInstalled && helperResponding)) }
    @Published private(set) var userSessionStatus: UserSessionStatus?
    private var observedUserSessionSettings: IdleSessionSettings?
    private(set) var userSession: UserSessionController?
    @Published private(set) var coordinatedLidError: String?
    @Published private(set) var coordinatedLidBlockReason: String?
    private(set) var coordinatingLid = false
    private var workSessionAttached = false
    private var workSyncInFlight = false
    private var workSyncPending = false
    private var workDetachPending = false
    private var workRecoveryPending = false
    private var workRouteGeneration: UInt64 = 0
    private var rootWorkSnapshot: ServiceReply?
    private var legacyHandoffEpoch: String?
    private var legacyHandoffInFlight = false
    private var unavailableLidEventsEpoch: String?
    var userCommandService: UserSessionService?
    var userCommandLedger = UserCommandLedger()
    var userCommandBusy = false
    var userEnableSequence: UInt64 = 0
    private var userSleepIntentSequence: UInt64 = 0
    private var userSleepCancellation: ExplicitSleepCancellation?
    var userCommandOwnerProbe: (() -> GUISessionObservation)?
    var userCommandCompanion: String?
    var acceptingUserCommands: Bool { hasCoordinatorAuthority && !terminating }
    var userCommandsArePreview: Bool { renderOnly }
    var lidCommandPending: Bool { workSyncPending || workSyncInFlight || workDetachPending }
    var lidReleasePending: Bool { workDetachPending }

    let defaults: UserDefaults
    @Published private(set) var coordinatorStartFailure: String?
    private var coordinatorLease: AppCoordinatorLease?
    private var coordinatorLeaseRequired = false
    var hasCoordinatorAuthority: Bool {
        coordinatorStartFailure == nil && (!coordinatorLeaseRequired || coordinatorLease?.isValid == true)
    }
    private let connection = ServiceConnection()
    /// Preview-only transport for testing the same orchestration without the installed service.
    private var previewWorkService: ((ServiceRequest) async throws -> ServiceReply)?
    private var previewSessionBackend: IdleAssertionBackend?
    private let legacyObservationProbe: () -> Snapshot
    private var stateReadInFlight = false
    private var stateGeneration = 0
    @Published private(set) var commandPending = false
    @Published private(set) var pendingHoldMinutes: Int?
    private var registeredAppPath = false
    private var renderOnly = false
    private var terminating = false
    private var removalInProgress = false
    private var removalPreparedForTermination = false
    private var removalCompleted = false
    private let previewUpdateTermination: (() -> Bool)?
    private let previewSleepExecutor: (() async -> Bool)?
    private let previewSleepSettled: (() -> Bool)?
    private let previewSleepAuthority: (() -> GUISessionObservation)?
    private let previewHelperInstaller: (() async throws -> Void)?
    private let previewHelperReadiness: (() async throws -> ServiceReply)?
    private let previewHelperFiles: (() -> [HelperInstallationFile])?
    @Published var showActivityReview = false
    var activityReviewPresentationOrigin: SheetPresentationOrigin = .unknown

    /// UI metadata only: capture the real invocation before presenting a sheet.
    func presentActivityReview(origin: SheetPresentationOrigin? = nil) {
        guard !showActivityReview else { return }
        activityReviewPresentationOrigin = origin ?? SheetPresentationOrigin(eventType: NSApp.currentEvent?.type)
        showActivityReview = true
    }
    private let usageFile = JSONWatch(Usage.self, path: TetherPaths.usagePath)
    private let screenGuard = ScreenGuard()
    private var notifier: Notifier?
    private var observers: [Any] = []
    private var displayInspectionObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var sleepWait: Timer?
    private var preferencesMigrationFailed = false
    lazy var updater = AppUpdater { [weak self] status in
        self?.updateStatus = status
    }

    private enum Key {
        static let menuBarDetails = "menuBarDetails"
        static let panelCompact = "panelCompact"
        static let notifyHeat = "notifyHeat"
        static let notifyBatteryProtection = "notifyBatteryProtection"
        static let checkUpdates = "checkUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let onboarded = "onboarded"
        static let launchAtLoginConfigured = "launchAtLoginConfigured"
    }


    /// The app's own version; `TetherPaths.version` is the helper's.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? TetherPaths.version
    }

    static var appDisplayVersion: String {
        let beta = Bundle.main.object(forInfoDictionaryKey: "TetherReleaseChannel") as? String == "beta"
        let iteration = Bundle.main.object(forInfoDictionaryKey: "TetherBetaIteration") as? Int ?? 1
        return appVersion + (beta ? " Beta \(iteration)" : "")
    }

    static var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? String(TetherPaths.build) }

    /// `preview` reads live state once, with no timers, notifications or side effects; `sample`
    /// adds made-up usage and `holdSample` a running battery hold to check the design.
    init(preview: Bool = false, sample: Bool = false, holdSample: Bool = false, compactSample: Bool? = nil,
         manualSample: ManualSessionStatus? = nil, capabilities: MacCapabilities = SystemProbe.capabilities,
         previewSession: UserSessionController? = nil,
         previewSessionBackend: IdleAssertionBackend? = nil,
         previewLegacyObservation: (() -> Snapshot)? = nil,
         previewWorkService: ((ServiceRequest) async throws -> ServiceReply)? = nil,
         previewHelperReply: ServiceReply? = nil, previewDefaults: UserDefaults? = nil,
         previewCoordinatorPath: String? = nil, previewCommandPath: String? = nil,
         previewCapabilitiesProbe: (() -> MacCapabilities)? = nil,
         previewPreferencesMigration: (() throws -> Void)? = nil,
         previewUpdateTermination: (() -> Bool)? = nil,
         previewSleepExecutor: (() async -> Bool)? = nil,
         previewSleepSettled: (() -> Bool)? = nil,
         previewSleepAuthority: (() -> GUISessionObservation)? = nil,
         previewHelperInstaller: (() async throws -> Void)? = nil,
         previewHelperReadiness: (() async throws -> ServiceReply)? = nil,
         previewHelperFiles: (() -> [HelperInstallationFile])? = nil,
         previewSystemSettings: SystemSettingsMonitor? = nil,
         previewClosedLidDisplayDriver: ClosedLidDisplayDriver? = nil) {
        self.capabilities = capabilities
        self.systemSettings = previewSystemSettings ?? SystemSettingsMonitor(simulated: preview || TetherPaths.serviceSocket != TetherPaths.productionSocket)
        self.notificationSettings = NotificationSettingsMonitor(simulated: preview || TetherPaths.serviceSocket != TetherPaths.productionSocket)
        self.legacyObservationProbe = preview ? (previewLegacyObservation ?? { .init(power: .unknown, lidClosed: nil, sleepDisabled: nil, fullWake: nil) }) : { SystemProbe.snapshot() }
        self.previewUpdateTermination = preview ? previewUpdateTermination : nil
        self.previewSleepExecutor = preview ? previewSleepExecutor : nil
        self.previewSleepSettled = preview ? previewSleepSettled : nil
        self.previewSleepAuthority = preview ? previewSleepAuthority : nil
        self.previewHelperInstaller = preview ? previewHelperInstaller : nil
        self.previewHelperReadiness = preview ? previewHelperReadiness : nil
        self.previewHelperFiles = preview ? previewHelperFiles : nil
        self.capabilitiesProbe = preview ? previewCapabilitiesProbe : { SystemProbe.capabilities }
        self.defaults = preview ? (previewDefaults ?? .standard) : .standard
        let live = !preview && TetherPaths.serviceSocket == TetherPaths.productionSocket
        coordinatorLeaseRequired = live || (preview && (previewCoordinatorPath != nil || previewCommandPath != nil))
        var startupFailure: String?
        var startupService: UserSessionService?
        var startupCompanion: String?
        weak var destination: AppModel?
        if coordinatorLeaseRequired {
            do {
                guard live || (previewCoordinatorPath != nil && previewCoordinatorPath != AppCoordinatorLease.production
                    && previewCommandPath != UserSessionEndpoint.production) else { throw AppCoordinatorFailure.unsafeLocation }
                coordinatorLease = try AppCoordinatorLease.acquire(at: live ? AppCoordinatorLease.production : previewCoordinatorPath!)
                if let path = live ? UserSessionEndpoint.path : previewCommandPath {
                    let registration = try Self.reserveUserCommandService(path: path,
                        expectedCompanion: live ? nil : ProcessIdentity.capture(pid: getpid())?.executable) { request, peer in
                        guard let destination else {
                            return UserSessionReply(id: request.id, epoch: UUID(), revision: 0, ok: false, error: "coordinatorUnavailable")
                        }
                        return await destination.handleUserCommand(request, peer: peer)
                    }
                    startupService = registration.server; startupCompanion = registration.companion
                }
            } catch { startupFailure = error.localizedDescription }
        }
        var migrationError: String?
        if startupFailure == nil {
            do {
                if preview { try previewPreferencesMigration?() }
                else { try Self.migrateDefaults() }
            }
            catch { migrationError = L("Previous app settings could not be backed up. No settings were migrated. ", "기존 앱 설정을 백업하지 못해 이관을 중단했습니다. ") + error.localizedDescription }
        }
        defaults.register(defaults: [Key.menuBarDetails: false, Key.notifyHeat: true, Key.notifyBatteryProtection: true,
                                     Key.checkUpdates: true])
        notifyHeat = defaults.bool(forKey: Key.notifyHeat)
        notifyBatteryProtection = defaults.bool(forKey: Key.notifyBatteryProtection)
        checkUpdates = (defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool) ?? defaults.bool(forKey: Key.checkUpdates)
        updateChannel = UpdateChannel.resolve(saved: defaults.string(forKey: UpdateChannel.preferenceKey),
            bundled: Bundle.main.object(forInfoDictionaryKey: "TetherReleaseChannel") as? String)
        panelCompact = (preview ? compactSample : nil) ?? defaults.bool(forKey: Key.panelCompact)
        menuBarDetails = defaults.bool(forKey: Key.menuBarDetails)
        language = Localization.savedChoice
        launchAtLogin = SystemIntegration.launchAtLogin
        renderOnly = preview
        closedLidDisplayDriver = preview ? previewClosedLidDisplayDriver : nil
        systemSettings.onChange = { [weak self] in
            guard let self else { return }
            // Registration and macOS permission are separate. Never rewrite an
            // externally disabled item simply because an observation changed.
            self.launchAtLogin = self.systemSettings.value.loginItemConfigured
            self.objectWillChange.send()
        }
        preferencesMigrationFailed = migrationError != nil
        coordinatorStartFailure = startupFailure ?? migrationError
        if let failure = coordinatorStartFailure {
            // A failed durable backup is a failed writer startup. Do not bind a
            // controller or leave the already-reserved command endpoint active.
            startupService?.stop()
            errorText = failure
            return
        }
        userCommandService = startupService; userCommandCompanion = startupCompanion
        destination = self
        if preview { self.previewWorkService = previewWorkService; self.previewSessionBackend = previewSessionBackend }
        // General idle work never depends on privileged lid readiness. A legacy
        // handshake may migrate settings/recovery, but cannot own the general API.
        if capabilities.generalIdleAvailable,
           (!developmentService || (preview && previewSession != nil && previewWorkService != nil)),
           let controller = preview ? previewSession : UserSessionController(defaults: defaults,
                legacyControl: JSONFile.read(Control.self, from: TetherPaths.controlPath)) {
            bindUserSession(controller)
        }
        // An injected preview is self-contained; it must not query or attach to the
        // installed service even when the selected capabilities reject that route.
        if preview, previewSession == nil, previewHelperReply == nil { readState(synchronous: true) }
        if preview, self.previewWorkService != nil, let previewHelperReply { apply(previewHelperReply) }
        if preview {
            if previewHelperReply == nil && previewWorkService == nil { helperSetupChecked = true }
            if sample {
                // Screenshots show the defaults, not this Mac's own choices.
                setUsage(SampleData.usage())
                limits = UserLimits()
                debugLogging = false
                if let status { self.status = SampleData.status(status) }
            }
            if holdSample, let status {
                self.status = SampleData.holding(status)
                helperResponding = true
            }
            if let manualSample {
                var value = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
                    enabled: false, power: .ac, lidClosed: false, sleepDisabled: manualSample.holding,
                    lastEvent: nil, lastEventAt: nil, batteryTemperature: 30, thermal: 0, batteryPercent: 80)
                value.build = TetherPaths.build; value.manualSession = manualSample
                value.appConnected = true; value.ownsOverride = manualSample.holding
                value.displayTopology = DisplayTopology.none; value.externalDisplay = false
                status = value; protection = ProtectionStatus(reason: nil, error: nil, dryRun: true); enabled = false
                helperInstalled = true; helperResponding = true
                snapshot = Snapshot(power: .ac, lidClosed: false, sleepDisabled: manualSample.holding)
            }
            return
        }
        start()
    }

    /// Wiring for the running app: timers, notifications, the login item and the first checks.
    private func start() {
        if developmentService { startWorkbench(); return }
        guard hasCoordinatorAuthority, startUserCommandService() else { return }
        startDisplayInspectionObserving()
        if !renderOnly { screenGuard.update(clamshellActive: false, lidClosed: SystemProbe.snapshot().lidClosed) }
        readState()
        if let state = userSessionStatus { updateSessionFeatures(state) }
        // Login-item intent and moved-app paths apply to both common idle work
        // and the privileged-lid route. Existing explicit off survives migration.
        if supportedMac, !preferencesMigrationFailed, !defaults.bool(forKey: Key.launchAtLoginConfigured) {
            setLaunchAtLogin(true)
            defaults.set(true, forKey: Key.launchAtLoginConfigured)
        } else if !preferencesMigrationFailed, launchAtLogin, !isTranslocated {
            SystemIntegration.updateLoginItemIfNeeded()
        }
        systemSettings.refresh(force: true)
        Task { await notificationSettings.refresh() }
        if let userSession {
            notifier = Notifier(status: status, defaults: defaults)
            v4NotificationDelivery.activate { [weak self] token, action in self?.handleV4Notice(token, action: action) }
            applyUserSessionState(userSession.status)
            userSession.startObserving()
            powerRequests.refresh()
            let token = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userCommandService?.stop(); self?.userSession?.end(); self?.finishSessionFeatures(); self?.screenGuard.releaseAll() }
            }
            observers.append(token)
            observers.append(DarwinNotification(observing: TetherPaths.statusChanged) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            })
            timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            checkForUpdates(force: false)
            return
        }
        appLog.notice("started v\(Self.appVersion, privacy: .public) build \(TetherPaths.build, privacy: .public)")
        refresh()
        reportAppPath()
        // The helper posts a notification whenever it writes its status, which it does on every
        // power, lid or thermal change and at least every 30 seconds; the timer only turns an
        // idle screen off on time and notices a helper that stopped.
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1
        self.timer = timer
        observers.append(DarwinNotification(observing: TetherPaths.statusChanged) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        })
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishSessionFeatures(); self?.screenGuard.releaseAll() }
        })
        notifier = Notifier(status: status, defaults: defaults)
        checkForUpdates(force: false)
        ensureHelperUpgradeIfNeeded()
    }

    // MARK: Reading state

    func refresh() {
        guard hasCoordinatorAuthority else { userSession?.refresh(); return }
        refreshHelperInstallation()
        refreshRemoteInspectionSession()
        refreshCapabilities()
        if workDetachPending { syncWorkSession() }
        readState()
        guard !renderOnly else { return }
        powerRequests.refresh()
        if developmentService { return }
        systemSettings.refresh()
        notifier?.checkHelper(installed: helperInstalled && showsLidOptions && v3Settings.allowClosedLid,
                              responding: helperResponding)
        checkForUpdates(force: false)
    }

    private func startDisplayInspectionObserving() {
        refreshRemoteInspectionSession()
        let applicationCenter = NotificationCenter.default
        displayInspectionObservers.append((applicationCenter, applicationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemSettings.refresh(force: true)
                    Task { await self?.notificationSettings.refresh() }
                }
            }))
        displayInspectionObservers.append((applicationCenter, applicationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.displayParametersChanged() }
            }))
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            displayInspectionObservers.append((workspaceCenter, workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.remoteInspectionGeneration &+= 1
                    self.refreshRemoteInspectionSession()
                    self.systemSettings.invalidate()
                    if name == NSWorkspace.didWakeNotification || name == NSWorkspace.sessionDidBecomeActiveNotification {
                        self.systemSettings.refresh(force: true)
                    }
                }
            }))
        }
    }

    deinit {
        for (center, token) in displayInspectionObservers { center.removeObserver(token) }
    }

    func displayParametersChanged() {
        displayRevision &+= 1
        refresh()
    }

    private func refreshRemoteInspectionSession() {
        // This key is evidence scoping only, never GUI ownership or a keep-awake reason.
        if renderOnly || developmentService {
            remoteInspectionSessionKey = "preview-" + userCommandLedger.epoch.uuidString
            return
        }
        let observation = GUISessionProbe.callerObservation()
        guard let login = observation.login, observation.consoleUID == login.uid else {
            remoteInspectionSessionKey = "unavailable"; return
        }
        remoteInspectionSessionKey = "\(userCommandLedger.epoch.uuidString):\(login.uid):\(login.sessionID):\(remoteInspectionGeneration)"
    }

    /// Observation gaps affect only the privileged lid extension. Keep the same
    /// policy/controller, deadlines, suppression and consumed battery budgets.
    private func refreshCapabilities() {
        guard (!developmentService || previewWorkService != nil), !terminating,
              let next = capabilitiesProbe?(), next != capabilities else { return }
        let previous = capabilities
        let previousBatteryError = batteryControlError
        let showedBatteryError = previousBatteryError.map { errorText == UserSessionFailure($0).localizedDescription } == true
        capabilities = next
        if showedBatteryError { errorText = batteryControlError.map { UserSessionFailure($0).localizedDescription } }
        userCommandLedger.advance()
        guard next.lidControlAvailable != previous.lidControlAvailable else { return }
        stateGeneration += 1; workRouteGeneration += 1
        if !next.lidControlAvailable {
            // An in-flight root request can already have been accepted before its
            // ACK arrives. Drain it in the same serial worker before any reconnect.
            workDetachPending = workDetachPending || coordinatingLid || workSessionAttached || workSyncInFlight
                || (helperResponding && status?.appPID == getpid()) || stateReadInFlight
            coordinatingLid = false; workSessionAttached = false; workSyncPending = false
            rootWorkSnapshot = nil; coordinatedLidBlockReason = nil
            if workDetachPending {
                coordinatedLidError = L("Device observation changed; confirming release of closed-lid support.",
                    "기기 정보가 바뀌어 덮개 유지 해제를 확인하고 있습니다.")
            }
            if next.generalIdleAvailable, userSession == nil, !renderOnly {
                bindUserSession(UserSessionController(defaults: defaults,
                    legacyControl: JSONFile.read(Control.self, from: TetherPaths.controlPath)))
                userSession?.startObserving()
            }
            if !renderOnly { screenGuard.releaseAll() }
        }
    }

    /// Every entry point uses current feature evidence. A failed battery lookup
    /// refuses a new edit/extension without ending an already valid general session.
    func validateBatteryAction() -> String? {
        refreshCapabilities()
        if workDetachPending { syncWorkSession() }
        return batteryControlError
    }

    /// Reads only the files that changed and publishes only the values that changed, so an idle
    /// menu bar and panel are not redrawn on every tick.
    private func readState(synchronous: Bool = false) {
        guard hasCoordinatorAuthority else { return }
        guard !usesUserSession || capabilities.lidControlAvailable else {
            helperSetupVerified = false
            helperSetupChecked = true
            return
        }
        if synchronous {
            if let reply = try? ServiceClient().perform(ServiceRequest(.snapshot)) { apply(reply) }
            return
        }
        guard !renderOnly || previewWorkService != nil else { return }
        guard !workDetachPending else { return }
        guard !stateReadInFlight, !commandPending, !terminating else { return }
        stateReadInFlight = true
        let generation = stateGeneration
        Task {
            defer {
                stateReadInFlight = false
                if generation != stateGeneration, !terminating { readState() }
            }
            do {
                var reply = try await performWorkService(ServiceRequest(.snapshot))
                guard hasCoordinatorAuthority, generation == stateGeneration else { return }
                if !renderOnly, !terminating, reply.status?.matchesCurrentBuild == true,
                   reply.status?.workSessionCoordinatorVersion == nil,
                   (reply.status?.appPID != getpid() || reply.status?.appConnected != true) {
                    reply = try await connection.perform(ServiceRequest(.attachApp))
                }
                guard generation == stateGeneration else { return }
                apply(reply)
            } catch {
                guard generation == stateGeneration else { return }
                helperSetupVerified = false
                helperResponding = false
                refreshHelperInstallation()
                helperInstalled = helperFilesChecked && (!missingHelperFiles.contains(.helper)
                    || !missingHelperFiles.contains(.helperRegistration))
                helperSetupChecked = true
                // A fresh notebook can still use general work without an admin install.
                // Existing root records require the protected migration handshake first.
                if capabilities.generalIdleAvailable, userSession == nil, !helperInstalled,
                   !FileManager.default.fileExists(atPath: TetherPaths.controlPath), !renderOnly {
                    bindUserSession(UserSessionController(defaults: defaults))
                    userSession?.startObserving()
                }
            }
        }
    }

    private func apply(_ reply: ServiceReply) {
        guard hasCoordinatorAuthority else { return }
        refreshHelperInstallation()
        assign(\.helperSetupVerified, reply.isCurrentHelperReady() && helperInstallationComplete)
        protection = reply.protection
        helperProtocolVersion = reply.protection?.protocolVersion
        assign(\.status, reply.status)
        userSession?.acknowledgeExtensionRollback(reply.status?.workSession?.extensionRollbackID)
        assign(\.helperInstalled, true)
        assign(\.helperResponding, reply.status != nil)
        helperSetupChecked = true
        let control = reply.control
        assign(\.powerCondition, control.condition)
        assign(\.automaticHoldMinutes, control.automaticMinutes)
        assign(\.enabled, control.enabled)
        assign(\.pendingHoldMinutes, control.pendingHoldMinutes)
        assign(\.limits, control.limits ?? UserLimits())
        assign(\.holdSource, control.holdSource)
        assign(\.debugLogging, control.debugLoggingActive)
        assign(\.debugLogUntil, control.debugLogUntil)
        if let status {
            var observed = Snapshot(power: status.power, lidClosed: status.observedLidClosed,
                                    sleepDisabled: status.observedSleepDisabled, fullWake: status.fullWake,
                                    externalDisplay: status.externalDisplay ?? true)
            observed.displayTopology = status.displayTopology ?? .unknown
            observed.nativeDisplayVerified = status.nativeDisplayVerified == true
            assign(\.snapshot, observed)
        }
        clock.run(until: manualSessionUntil ?? batteryHoldUntil)
        if reply.status?.workSessionCoordinatorVersion.map({ $0 != WorkSessionLease.coordinatorVersion }) == true {
            // An old/future common coordinator is never treated as the legacy
            // autonomous helper. Existing native general work remains independent.
            coordinatingLid = false; workSessionAttached = false; workSyncPending = false
            rootWorkSnapshot = nil
            coordinatedLidError = ServiceFailure("unsupportedVersion").localizedDescription
        }
        if ((!renderOnly && !developmentService) || previewWorkService != nil), capabilities.lidControlAvailable, !workDetachPending,
           reply.status?.matchesCurrentBuild == true,
           reply.status?.workSessionCoordinatorVersion == WorkSessionLease.coordinatorVersion,
           reply.status?.systemPowerObservationAvailable != false || unavailableLidEventsEpoch != reply.epoch,
           let bridge = reply.workSessionBridge, bridge.version == 1 {
            rootWorkSnapshot = reply
            let beginning = !coordinatingLid
            coordinatingLid = true
            coordinatedLidBlockReason = reply.protection?.blockReason
            if let reason = coordinatedLidBlockReason,
               WorkSessionBridge.generalWorkBlockReason(reason) == nil {
                coordinatedLidError = protectionReason(reason)
            }
            if userSession == nil {
                // Only conservative off/limits are read before preparation. Do not
                // activate a legacy automatic choice from an uncommitted snapshot.
                bindUserSession(UserSessionController(defaults: defaults,
                    backend: previewSessionBackend ?? NativeIdleAssertionBackend(),
                    guiProbe: renderOnly ? nil : { GUISessionProbe.callerObservation() },
                    environmentProbe: renderOnly ? nil : { UserSessionEnvironment.current() },
                    legacyControl: reply.control,
                    requiresRootHandoff: !bridge.coordinated))
                userSession?.acceptBridge(bridge, protection: reply.protection)
            } else { userSession?.acceptBridge(bridge, protection: reply.protection) }
            if beginning || (!workSessionAttached && !workSyncInFlight) { syncWorkSession() }
        }
        if let userSession { applyUserSessionState(userSession.status) }
        prepareLegacyGeneralWork(from: reply)
        guard !developmentService, !renderOnly else { return }
        if usageFile.reload() { setUsage(usageFile.value) }
        screenGuard.update(clamshellActive: clamshellActive, lidClosed: snapshot.lidClosed)
        if !usesUserSession {
            notifier?.check(status: status, choices: .init(heat: notifyHeat, battery: notifyBatteryProtection))
        }
        if !registeredAppPath, !isTranslocated, let path = Bundle.main.executablePath {
            registeredAppPath = true
            if control.appPath != path { save { ControlStore.update { $0.appPath = path } } }
        }
        ensureHelperUpgradeIfNeeded()
    }

    private func setUsage(_ new: Usage?) {
        usage = new
    }

    private func applyUserSessionState(_ state: UserSessionStatus) {
        refreshV4ConfigurationGeneration()
        if let settings = userSession?.settings, observedUserSessionSettings != settings {
            // Saved choices can change without changing the active-session status.
            // Refresh their native controls only when those choices actually differ.
            observedUserSessionSettings = settings
            objectWillChange.send()
        }
        if userSessionStatus != state { userCommandLedger.advance() }
        let previousError = userSessionStatus?.error
        assign(\.userSessionStatus, state)
        assign(\.enabled, state.enabled)
        assign(\.limits, state.limits ?? UserLimits())
        assign(\.powerCondition, state.powerCondition)
        assign(\.automaticHoldMinutes, state.automaticMinutes)
        assign(\.pendingHoldMinutes, state.pendingBatteryMinutes)
        assign(\.protection, state.blockReason.map { ProtectionStatus(reason: $0, error: nil, dryRun: false) })
        if let error = state.error { errorText = error }
        else if previousError != nil && errorText == previousError { errorText = nil }
        var observed = snapshot; observed.power = state.power
        assign(\.snapshot, observed)
        clock.run(until: state.until ?? state.batteryHoldUntil)
        notifier?.checkWork(state, choices: .init(heat: notifyHeat, battery: notifyBatteryProtection))
        updateV4Runtime(state)
        updateSessionFeatures(state)
    }

    private func bindUserSession(_ controller: UserSessionController) {
        guard hasCoordinatorAuthority else { return }
        userSession = controller
        configureSessionFeaturesIfNeeded()
        controller.activityPersistenceEnabled = !renderOnly
        loadV4ConfigurationGeneration()
        controller.ownershipProbe = { [weak self] in self?.hasCoordinatorAuthority == true }
        controller.onActivityChange = { [weak self] in self?.objectWillChange.send() }
        controller.onSleepBoundary = { [weak self] in self?.v4ChargerTrend.resetAfterSleepOrWake() }
        controller.onChange = { [weak self] state in
            self?.applyUserSessionState(state)
            self?.syncWorkSession()
        }
        applyUserSessionState(controller.status)
    }

    private func prepareLegacyGeneralWork(from observed: ServiceReply) {
        guard hasCoordinatorAuthority, capabilities.generalIdleAvailable,
              (!renderOnly || previewWorkService != nil), !terminating, !workDetachPending,
              !legacyHandoffInFlight, legacyHandoffEpoch != observed.epoch,
              observed.canHandOffLegacyGeneralWork(), legacyGeneralEnvironmentAllowsHandoff else { return }
        // Never attach over another live app, even if it belongs to this user.
        guard observed.status?.appConnected != true || observed.status?.appPID == getpid() else { return }
        legacyHandoffInFlight = true; legacyHandoffEpoch = observed.epoch
        let generation = stateGeneration
        let startingController = userSession
        Task {
            defer { legacyHandoffInFlight = false }
            do {
                // Snapshot is read-only. The authenticated attach/detach pair
                // changes the legacy autonomous helper into an app-required,
                // disconnected helper before the app owns general work.
                let before = try await performWorkService(ServiceRequest(.snapshot))
                guard hasCoordinatorAuthority, !terminating, generation == stateGeneration, userSession === startingController,
                      before.epoch == observed.epoch, before.canHandOffLegacyGeneralWork(), legacyGeneralEnvironmentAllowsHandoff,
                      before.status?.appConnected != true || before.status?.appPID == getpid() else {
                    throw ServiceFailure("powerVerificationFailed")
                }
                let attached = try await performWorkService(ServiceRequest(.attachApp))
                guard hasCoordinatorAuthority, !terminating, generation == stateGeneration, userSession === startingController,
                      attached.epoch == before.epoch, attached.canHandOffLegacyGeneralWork(), legacyGeneralEnvironmentAllowsHandoff,
                      attached.status?.appConnected == true, attached.status?.appPID == getpid() else {
                    throw ServiceFailure("powerVerificationFailed")
                }
                _ = try await releaseOwnLidSession()
                let released = try await performWorkService(ServiceRequest(.snapshot))
                guard hasCoordinatorAuthority, !terminating, generation == stateGeneration, userSession === startingController,
                      released.epoch == before.epoch, legacyGeneralEnvironmentAllowsHandoff,
                      let bridge = released.legacyGeneralWorkBridge() else {
                    throw ServiceFailure("powerVerificationFailed")
                }
                let controller = startingController ?? UserSessionController(defaults: defaults,
                    backend: previewSessionBackend ?? NativeIdleAssertionBackend(),
                    guiProbe: renderOnly ? nil : { GUISessionProbe.callerObservation() },
                    environmentProbe: renderOnly ? nil : { UserSessionEnvironment.current() },
                    legacyControl: released.control, legacyBridge: bridge)
                bindUserSession(controller)
                // Adopt the confirmed configuration even if
                // the first common helper installation is canceled. Limits,
                // explicit off and safety stops are preserved; active timers aren't.
                controller.acceptBridge(bridge, protection: released.protection, preparedControl: released.control)
                if !renderOnly { controller.startObserving() }
                coordinatedLidError = L("General work is available. Update the helper to enable closed-lid support.",
                    "일반 작업 유지가 가능합니다. 덮개 유지를 사용하려면 도우미를 업데이트해 주세요.")
                apply(released)
            } catch {
                // An attach can succeed before its ACK is lost or the lid facts
                // change. Clean up only this same legacy epoch and process; a
                // replacement/common helper or another controller is untouched.
                if let current = try? await performWorkService(ServiceRequest(.snapshot)),
                   current.epoch == observed.epoch, current.status?.version == "2026.9.1", current.status?.build == 49,
                   current.status?.appPID == getpid(), current.status?.workSessionCoordinatorVersion == nil,
                   userSession === startingController {
                    _ = try? await releaseOwnLidSession()
                }
                guard hasCoordinatorAuthority, !terminating, generation == stateGeneration, userSession === startingController else { return }
                coordinatedLidError = L("The previous helper could not safely release its session. Update the helper before starting general work. ",
                    "이전 도우미의 세션을 안전하게 해제하지 못했습니다. 일반 작업 유지 전에 도우미를 업데이트해 주세요. ") + error.localizedDescription
            }
        }
    }

    private var legacyGeneralEnvironmentAllowsHandoff: Bool {
        // Build 49 did not publish observation availability/full-wake fields.
        // Read the current OS facts directly; legacy fallback Boolean fields
        // and missing values cannot authorize this transition.
        let observed = legacyObservationProbe()
        return observed.observedLidClosed == false && observed.observedFullWake == true
            && observed.observedSleepDisabled != nil && observed.power != .unknown
    }

    /// General work owns its single native assertion. This serial, finite IPC grants
    /// only the lid extension; its failure cannot turn display/remote issues into a
    /// new thermal stop or discard a healthy general session.
    private func syncWorkSession() {
        guard hasCoordinatorAuthority, (!renderOnly || previewWorkService != nil), !terminating else { return }
        // Recovery may deny reacquisition, but cannot block an already queued
        // release when device or GUI evidence changes again.
        guard workDetachPending || !workRecoveryPending || canRecoverOwnLidSession else { return }
        if coordinatingLid, capabilities.lidControlAvailable, !workDetachPending, userSession != nil { workSyncPending = true }
        guard workSyncPending || workDetachPending else { return }
        guard !workSyncInFlight else { return }
        workSyncInFlight = true
        Task {
            defer { workSyncInFlight = false }
            var preparationAttempts = 0
            while (workSyncPending || workDetachPending) && !terminating && hasCoordinatorAuthority {
                if workDetachPending {
                    do {
                        let reply = try await releaseOwnLidSession()
                        guard hasCoordinatorAuthority, !terminating else { return }
                        workDetachPending = false; workSessionAttached = false
                        coordinatedLidError = nil
                        if !capabilities.lidControlAvailable {
                            userSession?.endRootCoordination(confirmedBridge: reply.workSessionBridge, protection: reply.protection)
                        }
                        apply(reply)
                    } catch {
                        coordinatedLidError = L("Closed-lid release is not confirmed: ", "덮개 유지 해제를 확인하지 못했습니다: ") + error.localizedDescription
                        return // Retry once on the next refresh; never renew meanwhile.
                    }
                    continue
                }
                workSyncPending = false
                guard coordinatingLid, capabilities.lidControlAvailable, userSession != nil else { continue }
                let generation = workRouteGeneration
                let renewingAttachedSession = workSessionAttached
                do {
                    var preparation: WorkSessionPreparation?
                    if !workSessionAttached {
                        guard preparationAttempts < 8, let observed = rootWorkSnapshot,
                              var empty = userSession?.workLease() else { return }
                        preparationAttempts += 1
                        empty.reasons = []; empty.expiry = nil; empty.manualDeadline = nil; empty.lidPermit = nil
                        var prepare = ServiceRequest(.prepareWorkSession)
                        prepare.epoch = observed.epoch; prepare.revision = observed.revision; prepare.workSession = empty
                        let acknowledgement = try await performWorkService(prepare)
                        guard hasCoordinatorAuthority, !terminating else { return }
                        guard generation == workRouteGeneration, coordinatingLid, capabilities.lidControlAvailable else { continue }
                        guard let receipt = acknowledgement.workSessionPreparation,
                              receipt.isValid(sessionID: empty.sessionID, epoch: acknowledgement.epoch,
                                  revision: acknowledgement.revision, now: ContinuousTime.now) else { throw ServiceFailure("invalidWorkLease") }
                        // A delayed/cached preparation ACK is not current authority.
                        // Re-read the receipt before adopting settings or creating a
                        // native request. Stops/restarts/replacements invalidate it.
                        let prepared = try await performWorkService(ServiceRequest(.snapshot))
                        guard hasCoordinatorAuthority, !terminating else { return }
                        guard generation == workRouteGeneration, coordinatingLid, capabilities.lidControlAvailable else { continue }
                        guard prepared.epoch == receipt.epoch, prepared.revision == receipt.revision else {
                            throw ServiceFailure("staleRevision")
                        }
                        guard prepared.workSessionPreparation == receipt,
                              receipt.isValid(sessionID: empty.sessionID, epoch: prepared.epoch,
                                  revision: prepared.revision, now: ContinuousTime.now),
                              prepared.status?.matchesCurrentBuild == true,
                              prepared.status?.workSessionCoordinatorVersion == WorkSessionLease.coordinatorVersion,
                              let bridge = prepared.workSessionBridge, bridge.version == 1,
                              prepared.control.isSupported else { throw ServiceFailure("invalidWorkLease") }
                        preparation = receipt
                        apply(prepared)
                        if prepared.status?.systemPowerObservationAvailable == false {
                            // Registration failure blocks lid authority, not the
                            // independent native session. Preparation granted no
                            // lid work; confirm our detach and its final budget/
                            // stop state before ending root receipt dependence.
                            let released = try await releaseOwnLidSession()
                            guard hasCoordinatorAuthority, !terminating,
                                  generation == workRouteGeneration, coordinatingLid,
                                  released.epoch == receipt.epoch,
                                  released.status?.matchesCurrentBuild == true,
                                  released.status?.systemPowerObservationAvailable == false,
                                  let finalBridge = released.workSessionBridge, finalBridge.version == 1,
                                  released.control.isSupported else { throw ServiceFailure("powerVerificationFailed") }
                            unavailableLidEventsEpoch = released.epoch
                            coordinatingLid = false; workSessionAttached = false; workSyncPending = false
                            rootWorkSnapshot = nil
                            userSession?.acceptBridge(finalBridge, protection: released.protection, preparedControl: released.control)
                            userSession?.endRootCoordination(confirmedBridge: finalBridge, protection: released.protection)
                            if !renderOnly { userSession?.startObserving() }
                            coordinatedLidError = L("General work remains available. The helper could not observe sleep/wake events; restart or update it before using closed-lid support.",
                                "일반 작업 유지는 사용할 수 있습니다. 도우미가 잠자기·깨움 알림을 확인하지 못해 덮개 유지가 제한됩니다. 도우미를 재시작하거나 업데이트해 주세요.")
                            apply(released)
                            continue
                        }
                        userSession?.acceptBridge(bridge, protection: prepared.protection, preparedControl: prepared.control)
                        if !renderOnly { userSession?.startObserving() }
                    }
                    if workRecoveryPending {
                        // The preparation awaited IPC; do not reacquire from an old
                        // GUI observation or from a session that ended meanwhile.
                        userSession?.refresh()
                        guard canRecoverOwnLidSession else {
                            coordinatedLidError = canceledQuitLidNotice
                            return
                        }
                    }
                    guard var lease = userSession?.workLease() else { return }
                    if screenGuard.hasRecoveryDebt {
                        lease.lidPermit = nil
                        coordinatedLidError = L("Previous display recovery is unconfirmed. General work remains available.",
                            "이전 화면 설정의 원복을 확인하지 못했습니다. 일반 작업 유지는 사용할 수 있습니다.")
                    }
                    var request = ServiceRequest(workSessionAttached ? .syncWorkSession : .attachWorkSession)
                    request.workSession = lease
                    if let preparation { request.epoch = preparation.epoch; request.revision = preparation.revision }
                    let reply = try await performWorkService(request)
                    guard hasCoordinatorAuthority, !terminating else { return }
                    guard generation == workRouteGeneration, coordinatingLid, capabilities.lidControlAvailable else { continue }
                    workSessionAttached = reply.status?.workSession?.sessionID == lease.sessionID
                    if workSessionAttached { workRecoveryPending = false }
                    if !screenGuard.hasRecoveryDebt { coordinatedLidError = nil }
                    apply(reply)
                } catch {
                    guard generation == workRouteGeneration, coordinatingLid, capabilities.lidControlAvailable else { continue }
                    coordinatedLidError = error.localizedDescription
                    // A root-side stop/protection is authoritative even when the
                    // latest renewal was rejected. Never keep renewing past it.
                    if let reply = try? await performWorkService(ServiceRequest(.snapshot)) {
                        guard hasCoordinatorAuthority, !terminating else { return }
                        guard generation == workRouteGeneration, coordinatingLid, capabilities.lidControlAvailable else { continue }
                        if reply.status?.appConnected != true || reply.status?.workSession == nil { workSessionAttached = false }
                        apply(reply)
                        if let failure = error as? ServiceFailure,
                           !workRecoveryPending, !workSessionAttached, preparationAttempts < 8,
                           failure.code == "staleRevision" || (renewingAttachedSession
                               && ["invalidWorkLease", "coordinatorRequired"].contains(failure.code)) {
                            // A consumed grant needs a fresh handshake. Invalid
                            // preparation receipts and canceled-update recovery
                            // must not become repeated attempts to reacquire it.
                            workSyncPending = true
                        }
                    }
                }
            }
        }
    }

    /// Detach uses kernel-bound caller identity; it never stops another app's
    /// native assertion. A concurrent detach is accepted only after a fresh read
    /// proves the helper has no remaining connection, lease or owned override.
    private func releaseOwnLidSession() async throws -> ServiceReply {
        let reply: ServiceReply
        do { reply = try await performWorkService(ServiceRequest(.detachApp)) }
        catch let failure as ServiceFailure where failure.code == "notOwner" {
            reply = try await performWorkService(ServiceRequest(.snapshot))
        }
        guard let observed = reply.status, observed.appConnected == false,
              observed.workSession == nil, observed.ownsOverride == false else {
            throw ServiceFailure("powerVerificationFailed")
        }
        return reply
    }

    func performWorkService(_ request: ServiceRequest, preflight: (@Sendable () throws -> Void)? = nil) async throws -> ServiceReply {
        guard hasCoordinatorAuthority else { throw UserSessionFailure("coordinatorUnavailable") }
        if let previewWorkService { try preflight?(); return try await previewWorkService(request) }
        return try await connection.perform(request, preflight: preflight)
    }

    private func assign<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Clamshell mode is on right now (AC, or a battery hold): helper alive, switched on, sleep disabled.
    var clamshellActive: Bool {
        guard capabilities.lidControlAvailable, !workDetachPending else { return false }
        if usesUserSession {
            guard coordinatingLid, coordinatedLidBlockReason == nil, workSessionHolding, helperResponding,
                  status?.workSession?.sessionID == userSession?.sessionID,
                  status?.workSession?.expiry.map({ $0 > ContinuousTime.now }) == true else { return false }
        }
        return helperInstalled && helperResponding && (enabled || manualSessionActive) && protection?.blockReason == nil && snapshot.observedSleepDisabled == true
            && status?.ownsOverride == true && status?.appConnected != false
            && Policy.wantsClamshell(snapshot, enabled: enabled, sleepNowPending: false, batteryHold: batteryHoldUntil != nil,
                condition: powerCondition, ownsOverride: status?.ownsOverride == true, manualSession: manualSessionActive || (usesUserSession && workSessionHolding))
    }

    /// Deadline of the armed battery hold, as the helper reports it.
    var batteryHoldUntil: Date? {
        if usesUserSession { return userSessionStatus?.batteryHoldUntil }
        guard helperResponding, let until = status?.batteryHoldUntil else { return nil }
        return Date(timeIntervalSince1970: until)
    }

    var holdingOnBattery: Bool { snapshot.power == .battery && (usesUserSession ? workSessionHolding : batteryHoldUntil != nil) }
    var workSessionHolding: Bool { userSessionStatus?.holding ?? clamshellActive }

    /// Low Power Mode is on because the closed Mac ran hot on AC.
    var heatGuardActive: Bool { helperResponding && status?.heatGuard == true }



    /// The installed helper predates this app build and should be reinstalled.
    var helperOutdated: Bool {
        guard helperInstalled, let status else { return false }
        return !status.matchesCurrentBuild || helperProtocolVersion != 2
            || status.workSessionCoordinatorVersion != WorkSessionLease.coordinatorVersion
    }

    var helperInstallationComplete: Bool { helperFilesChecked && missingHelperFiles.isEmpty }
    var helperNeedsRepair: Bool {
        helperFilesChecked && !missingHelperFiles.isEmpty
            && (helperInstalled || missingHelperFiles.count < HelperInstallationFile.allCases.count)
    }
    var helperInstallationIssue: String? {
        guard helperNeedsRepair else { return nil }
        let components = missingHelperFiles.map { $0.title(language: Localization.current) }.joined(separator: ", ")
        return L("Helper repair required: \(components). The running helper can respond while its installation is incomplete.",
                 "도우미 복구가 필요합니다: \(components). 현재 도우미가 응답해도 영구 설치는 완전하지 않습니다.")
    }

    private func refreshHelperInstallation() {
        let missing: [HelperInstallationFile]
        if renderOnly {
            guard let previewHelperFiles else { return }
            missing = previewHelperFiles()
        } else {
            guard !developmentService else { return }
            missing = SystemIntegration.missingHelperFiles()
        }
        assign(\.missingHelperFiles, missing)
        assign(\.helperFilesChecked, true)
        if !missing.isEmpty { helperSetupVerified = false }
    }

    /// Automatic authorization is a production action, once per contract. A
    /// Preview/development service never inspects or repairs the host installation.
    private func ensureHelperUpgradeIfNeeded() {
        guard acceptingUserCommands, !renderOnly, !developmentService, !helperInstallInFlight,
              helperOutdated || helperNeedsRepair, HelperUpgradeAttempt.claim(in: defaults) else { return }
        installHelper(automatically: true)
    }

    // MARK: Identity and location

    /// Until 2.0 the bundle identifier was `local.tether`; carry its settings over once.
    private static func migrateDefaults() throws {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier == TetherPaths.bundleID else { return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether/migrations", isDirectory: true)
        try PreferenceMigration.apply(defaults: defaults, domain: TetherPaths.bundleID, legacyDomain: "local.tether",
                                      backupDirectory: directory, hadExistingInstall: FileManager.default.fileExists(atPath: TetherPaths.controlPath))
    }

    /// macOS runs an app opened straight from a download at a random temporary path (App
    /// Translocation). The helper and the login item must not point there.
    var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// Tells the helper where this app lives, so it can remove itself if the app is thrown away.
    private func reportAppPath() {
        guard helperInstalled, !isTranslocated, let path = Bundle.main.executablePath,
              ControlStore.read().appPath != path else { return }
        save { ControlStore.update { $0.appPath = path } }
    }

    // MARK: First run

    /// General work never needs root setup. A saved closed-lid choice still
    /// requires a current helper; an onboarding flag cannot approve it alone.
    var requiresHelperSetup: Bool { supportedMac && v3Settings.allowClosedLid }
    var helperSetupConfirmed: Bool {
        guard helperSetupVerified, helperInstallationComplete, helperInstalled, helperResponding, let status else { return false }
        let age = Date().timeIntervalSince1970 - status.updatedAt
        return age.isFinite && age >= 0 && age < 90
    }
    var canFinishOnboarding: Bool {
        canFinishOnboarding(allowClosedLid: v3Settings.allowClosedLid)
    }
    /// Draft setup choices are checked before they become saved intent. An
    /// unprepared lid option must not block ordinary work with that option off.
    func canFinishOnboarding(allowClosedLid: Bool) -> Bool {
        guard supportedMac else { return true }
        if allowClosedLid { return capabilities.lidControlAvailable && helperSetupConfirmed }
        return capabilities.generalIdleAvailable
    }
    var needsOnboarding: Bool {
        if !defaults.bool(forKey: Key.onboarded) { return true }
        // Existing notebook setup waits for its initial service observation;
        // an asynchronous startup query must not reopen the guide every launch.
        if requiresHelperSetup && !helperSetupChecked { return false }
        return !canFinishOnboarding
    }

    func finishOnboarding() {
        guard hasCoordinatorAuthority, canFinishOnboarding else { return }
        defaults.set(true, forKey: Key.onboarded)
    }

    // MARK: Commands

    func startWorkbench() {
        guard developmentService, timer == nil else { return }
        // Keep the injected preview's no-system-side-effects gate. The legacy external
        // workbench still controls only its explicitly selected dry-run helper.
        if let userSession { userSession.startObserving() }
        else { renderOnly = false }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // File-backed preview sensors do not post native power events.
                // Poll only this fake environment; production remains event-driven.
                self?.userSession?.refresh()
                self?.refresh()
            }
        }
    }

    func setPowerCondition(_ condition: PowerCondition) {
        guard acceptingUserCommands else { return }
        if condition != .ac, let error = validateBatteryAction() {
            errorText = UserSessionFailure(error).localizedDescription; return
        }
        if let userSession {
            userSession.setPowerCondition(condition)
            if userSession.status.automaticActive { acceptedUserWorkIntent() }
            return
        }
        save { ControlStore.update { $0.powerCondition = condition } }
    }
    func setAutomaticMinutes(_ minutes: Int) {
        guard acceptingUserCommands else { return }
        if let error = validateBatteryAction() {
            errorText = UserSessionFailure(error).localizedDescription; return
        }
        if let userSession { userSession.setAutomaticMinutes(minutes); return }
        save { ControlStore.update { $0.automaticHoldMinutes = minutes } }
    }

    func setEnabled(_ on: Bool) {
        guard acceptingUserCommands, !on || !v4AcquisitionBlocked else { return }
        if let userSession {
            userEnableSequence &+= 1
            let sequence = userEnableSequence
            if on && coordinatingLid && (protection?.blockReason != nil || coordinatedLidBlockReason != nil) {
                Task {
                    do {
                        try await applyUserEnabled(true, sequence: sequence)
                    } catch { errorText = error.localizedDescription }
                }
            } else if !userSession.setEnabled(on) {
                errorText = userSession.status.error ?? UserSessionFailure("safetyBlocked").localizedDescription
            } else {
                if on { acceptedUserWorkIntent() }
                if errorText == UserSessionFailure("safetyBlocked").localizedDescription { errorText = nil }
            }
            return
        }
        appLog.notice("clamshell mode switched \(on ? "on" : "off", privacy: .public)")
        send(ServiceRequest(on ? .resume : .stop))
    }

    /// A later off command wins over an earlier asynchronous protection resume.
    func applyUserEnabled(_ on: Bool, sequence: UInt64, deadline: Double? = nil) async throws {
        guard hasCoordinatorAuthority, let userSession, !terminating else { throw UserSessionFailure("coordinatorUnavailable") }
        if let deadline, ContinuousTime.now >= deadline { throw UserSessionFailure("expired") }
        if on && coordinatingLid && (protection?.blockReason != nil || coordinatedLidBlockReason != nil) {
            let reply = try await performWorkService(ServiceRequest(.resume))
            apply(reply)
        }
        guard hasCoordinatorAuthority, sequence == userEnableSequence, !terminating else { throw UserSessionFailure("superseded") }
        if let deadline, ContinuousTime.now >= deadline { throw UserSessionFailure("expired") }
        guard userSession.setEnabled(on), userSession.status.enabled == on else { throw UserSessionFailure("safetyBlocked") }
        if on { acceptedUserWorkIntent() }
        if errorText == UserSessionFailure("safetyBlocked").localizedDescription { errorText = nil }
    }

    func startBatteryHold(minutes: Int, source: String = "app") {
        guard acceptingUserCommands else { return }
        if let error = validateBatteryAction() {
            errorText = UserSessionFailure(error).localizedDescription; return
        }
        if let userSession {
            guard userSession.status.power == .battery, minutes > 0 else {
                errorText = L("Start battery manual work after disconnecting power.", "전원을 분리한 뒤 배터리 수동 유지를 시작하세요."); return
            }
            startManualSession(minutes: minutes)
            return
        }
        guard canStartHold else {
            errorText = L("A battery hold needs more charge than the floor. ", "배터리 유지는 하한선보다 충전돼 있어야 해요. ") + holdBlockedReason
            return
        }
        var request = ServiceRequest(.startHold); request.minutes = minutes; request.holdSource = source
        send(request)
    }

    func cancelBatteryHold() {
        guard acceptingUserCommands else { return }
        if let userSession { userSession.cancelBatteryHold(); return }
        save { ControlStore.cancelHold() }
    }

    /// Whether the running hold can take `minutes` more under the cap counted from its start.
    func canExtendHold(minutes: Int) -> Bool {
        guard hasInternalBattery else { return false }
        if let userSession {
            return !commandPending && userSession.canExtendBatteryHold(minutes: minutes)
        }
        guard let until = batteryHoldUntil, let since = status?.batteryHoldSince else { return false }
        return until.timeIntervalSince1970 + TimeInterval(minutes * 60) <= since + SafetyPolicy.maxHold(limits)
    }

    func extendBatteryHold(minutes: Int) {
        guard acceptingUserCommands else { return }
        if let error = validateBatteryAction() {
            errorText = UserSessionFailure(error).localizedDescription; return
        }
        guard canExtendHold(minutes: minutes) else { return }
        if userSession != nil { _ = extendCommonBatteryHold(minutes: minutes); return }
        save { ControlStore.extendHold(minutes: minutes) }
    }

    /// Fraction of the hold still left, for the progress ring and bar.
    func holdRemainingFraction(at date: Date) -> Double {
        if let userSession { return userSession.batteryRemainingFraction(at: date) }
        guard let until = batteryHoldUntil, let since = status?.batteryHoldSince else { return 1 }
        let total = until.timeIntervalSince1970 - since
        guard total > 0 else { return 1 }
        return min(1, max(0, until.timeIntervalSince(date) / total))
    }

    /// `tether://sleep`: asks for sleep once input settles (at most 3 s), so the key press that
    /// ran the shortcut does not cancel it (see `UserInput.settled`).
    func sleepNow() {
        guard acceptingUserCommands else { return }
        if let userSession {
            do {
                let intent = try beginExplicitSleep(deadline: ContinuousTime.now + UserSessionRequest.maximumLifetime)
                guard userSession.pauseForUserSleep() else {
                    throw UserSessionFailure("releaseUnconfirmed")
                }
                Task {
                    if let failure = await executeExplicitSleep(intent), failure != "superseded" {
                        errorText = UserSessionFailure(failure).localizedDescription
                    }
                }
            } catch { errorText = error.localizedDescription }
            return
        }
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

    /// A preview cannot perform an OS sleep. Regression fixtures opt in to a
    /// harmless executor explicitly; these hooks are ignored by live models.
    var explicitSleepExecutionAllowed: Bool { !renderOnly || previewSleepExecutor != nil }
    func explicitSleepInputSettled() -> Bool { previewSleepSettled?() ?? UserInput.settled() }
    func explicitSleepOwnerObservation() -> GUISessionObservation {
        previewSleepAuthority?() ?? userCommandOwnerProbe?() ?? GUISessionProbe.callerObservation()
    }
    struct ExplicitSleepIntent: Sendable {
        let sequence: UInt64
        let deadline: Double
        let owner: GUISessionIdentity
        let cancellation: ExplicitSleepCancellation
    }
    /// Only a successful explicit work action supersedes a pending user sleep.
    /// Power notifications, rejected starts and ordinary policy renewal do not.
    func acceptedUserWorkIntent() {
        cancelPendingExplicitSleep()
    }
    private func cancelPendingExplicitSleep() {
        userSleepIntentSequence &+= 1
        userSleepCancellation?.invalidate(); userSleepCancellation = nil
        sleepWait?.invalidate(); sleepWait = nil
    }
    func beginExplicitSleep(deadline: Double, expectedOwner: GUISessionIdentity? = nil) throws -> ExplicitSleepIntent {
        guard explicitSleepExecutionAllowed else { throw UserSessionFailure("sleepUnavailable") }
        guard acceptingUserCommands else { throw UserSessionFailure("coordinatorUnavailable") }
        guard deadline.isFinite, deadline > ContinuousTime.now else { throw UserSessionFailure("expired") }
        let observation = explicitSleepOwnerObservation()
        guard let owner = observation.login, owner.isValid, owner.uid == getuid(), observation.consoleUID == owner.uid,
              expectedOwner == nil || expectedOwner == owner else { throw UserSessionFailure("guiSessionUnavailable") }
        userSleepIntentSequence &+= 1
        userSleepCancellation?.invalidate()
        let cancellation = ExplicitSleepCancellation(lease: coordinatorLease, leaseRequired: coordinatorLeaseRequired)
        userSleepCancellation = cancellation
        return ExplicitSleepIntent(sequence: userSleepIntentSequence, deadline: deadline, owner: owner, cancellation: cancellation)
    }
    private func pendingExplicitSleepError(_ intent: ExplicitSleepIntent) -> String? {
        guard acceptingUserCommands, intent.sequence == userSleepIntentSequence, !Task.isCancelled else { return "superseded" }
        guard ContinuousTime.now < intent.deadline else { return "expired" }
        let current = explicitSleepOwnerObservation()
        guard current.login == intent.owner, current.consoleUID == intent.owner.uid else { return "guiSessionUnavailable" }
        return nil
    }
    func executeExplicitSleep(_ intent: ExplicitSleepIntent) async -> String? {
        let settlesBy = min(intent.deadline, ContinuousTime.now + 3)
        while !explicitSleepInputSettled(), ContinuousTime.now < settlesBy {
            if let failure = pendingExplicitSleepError(intent) { return failure }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if let failure = pendingExplicitSleepError(intent) { return failure }
        return await performExplicitSleepEffect(intent)
    }
    /// The helper RPC can wait behind another IPC. Recheck on the transport actor
    /// before sending, without relying on an old observation from the UI actor.
    func queuedExplicitSleepPreflight(_ intent: ExplicitSleepIntent,
        observation: @escaping @Sendable () -> GUISessionObservation = { GUISessionProbe.callerObservation() }) -> @Sendable () throws -> Void {
        return {
            guard intent.cancellation.isActive, !Task.isCancelled else { throw UserSessionFailure("superseded") }
            guard ContinuousTime.now < intent.deadline else { throw UserSessionFailure("expired") }
            guard intent.cancellation.hasWriterAuthority else { throw UserSessionFailure("coordinatorUnavailable") }
            let current = observation()
            guard current.login == intent.owner, current.consoleUID == intent.owner.uid else { throw UserSessionFailure("guiSessionUnavailable") }
        }
    }
    func performExplicitSleepEffect(_ intent: ExplicitSleepIntent) async -> String? {
        // This harmless preview executor acknowledges acceptance. Once an OS or
        // helper has actually received a request, later work cannot retract it.
        if let previewSleepExecutor { return await previewSleepExecutor() ? nil : "pmsetFailed" }
        if coordinatingLid {
            do { _ = try await performWorkService(ServiceRequest(.sleep), preflight: queuedExplicitSleepPreflight(intent)); return nil }
            catch let failure as ServiceFailure { return failure.code }
            catch let failure as UserSessionFailure { return failure.code }
            catch { return "failed" }
        }
        return Shell.run("/usr/bin/pmset", ["sleepnow"], timeout: 2).status == 0 ? nil : "pmsetFailed"
    }

    /// `tether://…` URLs from Shortcuts, scripts or a browser.
    func handle(url: URL) {
        guard acceptingUserCommands else { return }
        guard let command = TetherCommand.parse(url: url) else { return }
        appLog.notice("accepted URL command")
        switch command {
        case .status: break
        case .on, .off, .toggle:
            // The menu bar icon shows the result; Shortcuts can announce it if wanted.
            setEnabled(command == .toggle ? !enabled : command == .on)
        case .sleep: sleepNow()
        case .hold(let minutes): startBatteryHold(minutes: minutes, source: "url")
        case .extendHold(let minutes): extendBatteryHold(minutes: minutes)
        case .cancelHold: cancelBatteryHold()
        case .manual(let minutes): startManualSession(minutes: minutes)
        case .endManual: endManualSession()
        case .extendManual(let minutes): extendManualSession(by: minutes)
        case .automatic(let enabled): setTriggerEnabled(enabled)
        case .condition(let condition): setPowerCondition(condition)
        }
    }

    func setUserAutomatic(_ enabled: Bool) { setTriggerEnabled(enabled) }
    func setUserSessionLimits(_ limits: UserLimits) { if acceptingUserCommands { userSession?.setLimits(limits) } }
    func setTriggerEnabled(_ enabled: Bool) {
        guard acceptingUserCommands, !enabled || !v4AcquisitionBlocked else { return }
        if let userSession {
            userSession.setAutomatic(enabled)
            if enabled && userSession.status.automaticActive { acceptedUserWorkIntent() }
            return
        }
        save { ControlStore.update { $0.enabled = enabled } }
    }
    func startManualSession(minutes: Int?) {
        guard acceptingUserCommands else { return }
        if let userSession {
            guard !v4ManualApprovalPending, canAcquireManualFeatures,
                  userSession.start(duration: minutes.map { Double($0) * 60 }) else {
                errorText = userSession.status.error ?? L("This manual session cannot start with the current power or protection state.", "현재 전원·보호 상태에서는 수동 세션을 시작할 수 없습니다.")
                return
            }
            acceptedUserWorkIntent()
            if manualFeaturesNeedHelper, let requestID = userSession.manualRequestID {
                v4ManualApprovalPending = true
                Task { _ = await verifyManualStart(requestID: requestID) }
            }
            return
        }
        var request = ServiceRequest(.startManualSession); request.minutes = minutes
        send(request)
    }
    @discardableResult
    func extendCommonManualSession(minutes: Int) -> Bool {
        guard acceptingUserCommands, !v4AcquisitionBlocked, !v4ManualApprovalPending, let userSession,
              !manualFeaturesNeedHelper, userSession.extend(duration: Double(minutes) * 60) else { return false }
        acceptedUserWorkIntent(); return true
    }
    @discardableResult
    func extendCommonBatteryHold(minutes: Int) -> Bool {
        guard acceptingUserCommands, let userSession, userSession.canExtendBatteryHold(minutes: minutes),
              let before = userSession.status.batteryHoldUntil else { return false }
        userSession.extendBatteryHold(minutes: minutes)
        guard let after = userSession.status.batteryHoldUntil, after > before else { return false }
        acceptedUserWorkIntent(); return true
    }
    func endManualSession() {
        guard acceptingUserCommands else { return }
        if let userSession { userSession.endManual(); return }
        send(ServiceRequest(.endManualSession))
    }
    func startUntimedSession() {
        startManualSession(minutes: nil)
    }

    /// A serial connection owns blocking IPC; only confirmed replies update the UI.
    func save(_ write: @escaping @Sendable () -> Bool) {
        guard acceptingUserCommands, !commandPending else { return }
        commandPending = true; stateGeneration += 1
        Task {
            defer { commandPending = false }
            do { let reply = try await connection.write(write); errorText = nil; apply(reply) }
            catch { errorText = error.localizedDescription; readState() }
        }
    }

    func markDiagnostic() {
        diagnosticNote = nil
        if let userSession {
            if userSession.markActivity() { diagnosticNote = L("Marked \(Texts.time(Date()))", "\(Texts.time(Date()))에 표시했어요") }
            return
        }
        send(ServiceRequest(.markDiagnostic))
    }

    private func send(_ request: ServiceRequest) {
        guard acceptingUserCommands, !commandPending else { return }
        commandPending = true; stateGeneration += 1
        Task {
            defer { commandPending = false }
            do {
                let reply = try await connection.perform(request); errorText = nil; apply(reply)
                if request.action == .markDiagnostic {
                    diagnosticNote = L("Marked \(Texts.time(Date())) · \(request.id.uuidString.prefix(8))", "\(Texts.time(Date()))에 표시했어요 · \(request.id.uuidString.prefix(8))")
                }
            }
            catch { errorText = error.localizedDescription }
        }
    }

    private var updateAllowsTermination: Bool {
        if let previewUpdateTermination { return previewUpdateTermination() }
        if renderOnly || developmentService { return true }
        guard updater.canTerminateForUpdate else { return false }
        guard updater.installationRequested else { return true }
        userSession?.refresh()
        // Actual Sparkle preparation retains the same fresh power/owner/recovery
        // checks even though automatic after-work reservations were removed.
        return v4ReplacementBoundaryValid
    }

    private var canceledQuitLidNotice: String {
        L("The update was paused. Closed-lid support is not confirmed; check the current work session and device state.",
          "업데이트를 보류했습니다. 덮개 유지는 확인되지 않았습니다. 현재 작업 세션과 기기 상태를 확인해 주세요.")
    }

    private var canRecoverOwnLidSession: Bool {
        guard hasCoordinatorAuthority, capabilities.lidControlAvailable, coordinatingLid,
              !workDetachPending, coordinatedLidBlockReason == nil,
              snapshot.lidControlObservationAvailable, snapshot.observedFullWake == true,
              let state = userSession?.status, state.canStart, state.holding,
              state.manualActive || state.automaticActive else { return false }
        return true
    }

    /// A rejected update quit already released the helper, but never ended the
    /// common session. Reuse its finite handshake only while its authority and
    /// original policy remain valid; an observation gap leaves a visible pause.
    private func recoverOwnLidAfterCanceledQuit() async {
        workRecoveryPending = true
        userSession?.refresh() // Keep normal renewal suppressed until the fresh read.
        if hasCoordinatorAuthority, userSession?.status.canStart == true, userSession?.status.holding == true {
            do {
                let current = try await performWorkService(ServiceRequest(.snapshot))
                apply(current)
                userSession?.refresh()
                guard current.status?.appConnected == false, current.status?.workSession == nil,
                      current.status?.ownsOverride == false else {
                    terminating = false; coordinatedLidError = canceledQuitLidNotice
                    return
                }
            } catch {
                terminating = false; coordinatedLidError = canceledQuitLidNotice + " " + error.localizedDescription
                return
            }
        }
        terminating = false
        refreshCapabilities()
        guard canRecoverOwnLidSession else {
            coordinatedLidError = coordinatedLidBlockReason.map(protectionReason) ?? lidObservationNotice ?? canceledQuitLidNotice
            return
        }
        coordinatedLidError = canceledQuitLidNotice
        syncWorkSession()
    }

    /// Preserve saved preferences, but end this app session and its temporary work.
    func prepareToQuit() async -> Bool {
        // Full removal already verified both releases before deleting the helper.
        // Its final NSApp.terminate callback must not contact the removed socket.
        if removalCompleted { return true }
        guard updateAllowsTermination else {
            errorText = L("Open the MacBook before finishing the update.", "업데이트를 마무리하려면 MacBook을 열어 주세요.")
            return false
        }
        if !hasCoordinatorAuthority {
            cancelPendingExplicitSleep()
            guard userSession?.end() != false else { errorText = userSession?.status.error; return false }
            userCommandService?.stop()
            terminating = true
            return true
        }
        if removalPreparedForTermination { return !removalInProgress }
        guard !terminating else { return false }
        cancelPendingExplicitSleep()
        terminating = true; stateGeneration += 1
        if let userSession {
            var releasedOwnLid = false
            if coordinatingLid || workDetachPending || workSyncInFlight {
                // A failed/canceled app termination must not permanently end healthy
                // general work. Drain our serial lid connection first, invalidating
                // earlier preparation/renewal replies without releasing the app lease.
                workRouteGeneration &+= 1
                workSyncPending = false; workDetachPending = true
                do {
                    let reply = try await releaseOwnLidSession()
                    workDetachPending = false; workSessionAttached = false
                    apply(reply)
                    guard reply.status?.ownsOverride != true else { throw ServiceFailure("powerVerificationFailed") }
                    releasedOwnLid = true
                } catch {
                    terminating = false; errorText = error.localizedDescription; return false
                }
            }
            // IPC yielded to power/lid events. Sparkle may now be unsafe even if
            // the initial check passed. Keep the same controller, deadline and budget.
            guard updateAllowsTermination else {
                if releasedOwnLid { await recoverOwnLidAfterCanceledQuit() }
                else { terminating = false }
                errorText = L("Open the MacBook before finishing the update.", "업데이트를 마무리하려면 MacBook을 열어 주세요.")
                return false
            }
            guard userSession.end() else {
                terminating = false; errorText = userSession.status.error; return false
            }
            finishSessionFeatures()
            if !renderOnly { screenGuard.releaseAll() }
            userCommandService?.stop()
            return true
        }
        guard helperInstalled else { return true }
        do {
            let current = try await performWorkService(ServiceRequest(.snapshot))
            // Even an already-detached reply awaited IPC and can race a lid change.
            guard updateAllowsTermination else {
                terminating = false
                errorText = L("Open the MacBook before finishing the update.", "업데이트를 마무리하려면 MacBook을 열어 주세요.")
                return false
            }
            if current.status?.appConnected == false, current.status?.ownsOverride == false {
                screenGuard.releaseAll()
                return true
            }
            let reply = try await performWorkService(ServiceRequest(.detachApp))
            apply(reply)
            guard reply.status?.ownsOverride != true else { throw ServiceFailure("powerVerificationFailed") }
            guard updateAllowsTermination else {
                terminating = false
                errorText = L("Open the MacBook before finishing the update.", "업데이트를 마무리하려면 MacBook을 열어 주세요.")
                return false
            }
            screenGuard.releaseAll()
            return true
        } catch {
            terminating = false
            errorText = error.localizedDescription
            readState()
            return false
        }
    }

    // MARK: Updates

    /// Sparkle schedules signed-feed checks; manual checks also present a pending update.
    func checkForUpdates(force: Bool) {
        guard hasCoordinatorAuthority, !developmentService, !preferencesMigrationFailed else { return }
        updater.installationPreflight = { [weak self] in
            guard let self else { return false }
            self.userSession?.refresh()
            return self.v4CanReplaceNow
        }
        updater.start(automatically: checkUpdates, channel: updateChannel)
        if force { updater.check() }
    }

    var canSelectUpdateChannel: Bool {
        acceptingUserCommands && !preferencesMigrationFailed && !developmentService
            && (renderOnly || updater.engine?.sessionInProgress != true)
    }
    @discardableResult
    func setUpdateChannel(_ channel: UpdateChannel) -> Bool {
        guard canSelectUpdateChannel else { return false }
        if !renderOnly, !updater.select(channel) { return false }
        updateChannel = channel
        defaults.set(channel.rawValue, forKey: UpdateChannel.preferenceKey)
        refreshV4ConfigurationGeneration()
        return true
    }

    func resumeUpdateInstallation() { if acceptingUserCommands, !developmentService { updater.resumeInstallation() } }

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
        guard acceptingUserCommands, !developmentService else { return }
        if attempt({ try SystemIntegration.setLaunchAtLogin(on) }) {
            launchAtLogin = on
            refreshV4ConfigurationGeneration()
            systemSettings.invalidate()
            systemSettings.refresh(force: true)
        }
    }

    var cliLocation: String? { SystemIntegration.cliLocation }
    var cliInstalled: Bool { cliLocation != nil }

    func setCLIInstalled(_ on: Bool) {
        guard acceptingUserCommands, !developmentService else { return }
        attempt { try SystemIntegration.setCLIInstalled(on) }
        objectWillChange.send()
    }

    /// Existing buttons remain synchronous entry points. Reserve the slot before
    /// yielding, so a second click or automatic request cannot prompt twice.
    func installHelper(automatically: Bool = false) {
        guard acceptingUserCommands, !helperInstallInFlight else { return }
        guard !developmentService || renderOnly else { return }
        // Rendering a Preview must never authorize a real install. Its tests need
        // explicit effects, including wire and durable-file readiness observations.
        guard !renderOnly || (previewHelperInstaller != nil && previewHelperReadiness != nil && previewHelperFiles != nil) else { return }
        if !renderOnly, !developmentService { _ = HelperUpgradeAttempt.claim(in: defaults) }
        helperInstallInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { helperInstallInFlight = false }
            if automatically, let reply = try? await currentHelperInstallationReply(), helperInstallationIsReady(reply) {
                guard acceptingUserCommands else { return }
                // A separate authenticated installer may already have completed.
                // Apply its verified metadata instead of asking for a new password.
                apply(reply)
                defaults.removeObject(forKey: "helperUpgradePending")
                return
            }
            guard acceptingUserCommands, helperInstallationAllowed() else { return }
            do {
                if let previewHelperInstaller { try await previewHelperInstaller() }
                else { try await SystemIntegration.installHelper() }
                guard acceptingUserCommands else { return }
                errorText = nil
                refresh()
                guard let reply = try? await currentHelperInstallationReply(), helperInstallationIsReady(reply) else {
                    guard acceptingUserCommands else { return }
                    errorText = helperInstallationIssue ?? L("The helper update could not be verified. Finish the update in App Settings.",
                                  "도우미 업데이트를 확인하지 못했습니다. 앱 설정에서 업데이트를 마무리해 주세요.")
                    return
                }
                guard acceptingUserCommands else { return }
                apply(reply)
                defaults.removeObject(forKey: "helperUpgradePending")
                appLog.notice("helper installation completed")
                if !renderOnly { reportAppPath() }
            } catch SystemIntegration.Failure.cancelled {
                // macOS canceled authorization. Keep settings and pending state.
            } catch SystemIntegration.Failure.message(let text) {
                guard acceptingUserCommands else { return }
                errorText = text
                appLog.error("\(text, privacy: .public)")
            } catch {
                guard acceptingUserCommands else { return }
                errorText = error.localizedDescription
            }
        }
    }

    private func currentHelperInstallationReply() async throws -> ServiceReply {
        if let previewHelperReadiness { return try await previewHelperReadiness() }
        return try await connection.perform(ServiceRequest(.snapshot))
    }

    private func helperInstallationIsReady(_ reply: ServiceReply) -> Bool {
        refreshHelperInstallation()
        return helperInstallationComplete && reply.isCurrentHelperReady()
    }

    private func helperInstallationAllowed() -> Bool {
        switch (renderOnly ? capabilities : SystemProbe.capabilities).helperInstallTarget {
        case .portable: break
        case .desktop:
            errorText = L("This Mac keeps work running without an administrator helper.",
                          "이 Mac은 관리자 도우미 없이 작업을 유지합니다.")
            return false
        case .unavailable:
            errorText = L("The internal battery and lid could not be verified. Try again before installing the helper.",
                          "내장 배터리와 덮개를 확인하지 못했습니다. 도우미를 설치하기 전에 다시 확인해 주세요.")
            return false
        case .unsupported:
            errorText = L("Tether requires an Apple Silicon Mac running macOS 26 or later.",
                          "Tether는 macOS 26 이상의 Apple Silicon Mac을 지원합니다.")
            return false
        }
        let lidClosed = renderOnly ? legacyObservationProbe().observedLidClosed : SystemProbe.observedLidClosed
        guard UpdateInstallPolicy.allowsInstallation(lidClosed: lidClosed) else {
            errorText = L("Open the MacBook before installing the power management helper.", "전원 관리 도우미를 설치하려면 MacBook을 열어 주세요.")
            return false
        }
        guard !isTranslocated else {
            errorText = Problem.translocated.message
            return false
        }
        return true
    }

    func uninstallHelper() {
        guard acceptingUserCommands, !helperInstallInFlight else { return }
        guard !developmentService else { return }
        let before = try? ServiceClient().perform(ServiceRequest(.snapshot))
        let removed = attempt { try SystemIntegration.runScript("uninstall-helper.sh") }
        if removed, !FileManager.default.fileExists(atPath: TetherPaths.helperPlistPath),
           !FileManager.default.fileExists(atPath: TetherPaths.serviceSocket),
           !FileManager.default.fileExists(atPath: TetherPaths.controlPath) {
            // Only confirmed removal ends root receipt dependence. A canceled
            // authorization, version mismatch or temporary read failure doesn't.
            workRouteGeneration &+= 1; workSyncPending = false; workDetachPending = false
            coordinatingLid = false; workSessionAttached = false; rootWorkSnapshot = nil
            coordinatedLidError = nil; coordinatedLidBlockReason = nil
            userSession?.endRootCoordination(confirmedBridge: before?.workSessionBridge, protection: before?.protection)
            userSession?.refresh()
        }
        refresh()
    }

    /// Removes everything Tether put on this Mac: the helper and its watchdog (restoring normal
    /// sleep), their files, the login item, the `tether` link, preferences, and finally the app
    /// itself (to the Trash).
    func uninstallEverything() {
        guard hasCoordinatorAuthority, !helperInstallInFlight, !developmentService, !renderOnly else { return }
        let appURL = Bundle.main.bundleURL
        let domain = Bundle.main.bundleIdentifier ?? TetherPaths.bundleID
        let effects = RemovalEffects(
            removeHelper: { try SystemIntegration.runScript("uninstall-helper.sh") },
            removeLoginItem: { try SystemIntegration.setLaunchAtLogin(false) },
            removeUserCLI: {
                if SystemIntegration.cliLocation == SystemIntegration.userCLIPath {
                    try FileManager.default.removeItem(atPath: SystemIntegration.userCLIPath)
                }
            },
            recycleApp: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.recycle([appURL]) { moved, error in
                        if let error { continuation.resume(throwing: error) }
                        else if moved[appURL] != nil { continuation.resume(returning: ()) }
                        else {
                            continuation.resume(throwing: SystemIntegration.Failure.message(
                                L("The app was not moved to the Trash.", "앱을 휴지통으로 옮기지 못했습니다.")))
                        }
                    }
                }
            },
            removePreferences: { self.defaults.removePersistentDomain(forName: domain) },
            terminate: { NSApp.terminate(nil) })
        Task { await uninstallEverything(using: effects) }
    }

    /// Keep filesystem and administrator effects injectable so removal ordering
    /// and failures can be verified without deleting the installed app or helper.
    struct RemovalEffects {
        var removeHelper: @MainActor () throws -> Void
        var removeLoginItem: @MainActor () throws -> Void
        var removeUserCLI: @MainActor () throws -> Void
        var recycleApp: @MainActor () async throws -> Void
        var removePreferences: @MainActor () -> Void
        var terminate: @MainActor () -> Void
    }

    @discardableResult
    func uninstallEverything(using effects: RemovalEffects) async -> Bool {
        guard hasCoordinatorAuthority, acceptingUserCommands || removalPreparedForTermination,
              !helperInstallInFlight, !removalInProgress, !removalCompleted else { return false }
        removalInProgress = true
        defer { removalInProgress = false }
        // No administrator, filesystem or preference removal happens until the
        // existing quit path has confirmed both the helper and native releases.
        if removalPreparedForTermination {
            guard updateAllowsTermination else {
                errorText = L("Open the MacBook before finishing the update.", "업데이트를 마무리하려면 MacBook을 열어 주세요.")
                return false
            }
        } else {
            guard await prepareToQuit() else { return false }
        }
        removalPreparedForTermination = true
        errorText = nil
        do {
            try effects.removeHelper()
            try effects.removeLoginItem()
            launchAtLogin = false
            try effects.removeUserCLI()
            try await effects.recycleApp()
            effects.removePreferences()
            removalCompleted = true
            effects.terminate()
            return true
        } catch SystemIntegration.Failure.cancelled {
            errorText = L("Removal was canceled. Settings and the app were kept. Work requests have ended; restart Tether to use it again.",
                          "제거를 취소했습니다. 설정과 앱은 보존했습니다. 작업 유지는 종료됐으며 다시 사용하려면 Tether를 재시작해 주세요.")
        } catch {
            let detail: String
            if case SystemIntegration.Failure.message(let text) = error { detail = text }
            else { detail = error.localizedDescription }
            errorText = L("Removal is incomplete. Settings were kept. Retry removal or quit and restart Tether. ",
                          "제거를 완료하지 못해 설정을 보존했습니다. 제거를 다시 시도하거나 Tether를 종료하고 재시작해 주세요. ") + detail
        }
        return false
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
    /// Warning text needs darker ink on light cards than the system orange.
    static let tetherWarning = Color(nsColor: NSColor(name: "TetherWarning") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 202 / 255.0, blue: 88 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0.55, green: 0.25, blue: 0.03, alpha: 1)
    })

    /// SecondaryLabelColor is only 3.95:1 on this host's light control surface. Keep small
    /// explanatory text above the 4.5:1 goal and respond to increased-contrast appearances.
    static let tetherSecondary = Color(nsColor: NSColor(name: "TetherSecondary") { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let value: CGFloat
        switch appearance.name {
        case .accessibilityHighContrastDarkAqua: value = 0.82
        case .accessibilityHighContrastAqua: value = 0.28
        default:
            if dark {
                return NSColor(srgbRed: 189 / 255.0, green: 199 / 255.0, blue: 214 / 255.0, alpha: 1)
            }
            return NSColor(srgbRed: 78 / 255.0, green: 94 / 255.0, blue: 114 / 255.0, alpha: 1)
        }
        return NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
    })

    /// #1552A0 has 7.65:1 contrast against white on an opaque filled action.
    /// Keep filled actions distinct from the brighter accent used for text and switches.
    static let tetherAction = Color(nsColor: NSColor(name: "TetherAction") { appearance in
        switch appearance.name {
        case .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua:
            NSColor(srgbRed: 18 / 255.0, green: 75 / 255.0, blue: 145 / 255.0, alpha: 1)
        default:
            NSColor(srgbRed: 21 / 255.0, green: 82 / 255.0, blue: 160 / 255.0, alpha: 1)
        }
    })

    /// Secondary commands stay neutral instead of inheriting the window's blue accent.
    static let tetherControl = Color(nsColor: .systemGray)

    /// A blue accent for active work, selection, links and timer text.
    /// Native reading surfaces and secondary commands stay neutral.
    static let tetherAccent = Color(nsColor: NSColor(name: "TetherAccent") { appearance in
        switch appearance.name {
        case .accessibilityHighContrastDarkAqua:
            NSColor(srgbRed: 154 / 255.0, green: 195 / 255.0, blue: 1, alpha: 1)
        case .accessibilityHighContrastAqua:
            NSColor(srgbRed: 18 / 255.0, green: 75 / 255.0, blue: 145 / 255.0, alpha: 1)
        default:
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 155 / 255.0, green: 200 / 255.0, blue: 1, alpha: 1)
                : NSColor(srgbRed: 21 / 255.0, green: 82 / 255.0, blue: 160 / 255.0, alpha: 1)
        }
    })

    /// Confirmed checks have a separate semantic color from ongoing work and controls.
    static let tetherSuccess = Color(nsColor: NSColor(name: "TetherSuccess") { appearance in
        switch appearance.name {
        case .accessibilityHighContrastDarkAqua:
            NSColor(srgbRed: 161 / 255.0, green: 228 / 255.0, blue: 179 / 255.0, alpha: 1)
        case .accessibilityHighContrastAqua:
            NSColor(srgbRed: 21 / 255.0, green: 81 / 255.0, blue: 40 / 255.0, alpha: 1)
        default:
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 130 / 255.0, green: 217 / 255.0, blue: 154 / 255.0, alpha: 1)
                : NSColor(srgbRed: 33 / 255.0, green: 110 / 255.0, blue: 57 / 255.0, alpha: 1)
        }
    })
}
