import Foundation
import IOKit
import IOKit.pwr_mgt
import TetherCore

/// Root LaunchDaemon that owns the selected power condition and bounded battery holds.
/// A closed lid is put to sleep when an override is released. The
/// decisions live here; events, the battery hold, the heat guard, usage records, readings and
/// output are in the `Helper+…` files.
final class Helper {
    let dryRun: Bool
    let controlPath: String
    let statusPath: String

    var control = Control(enabled: false)
    var protection = ProtectionState()
    var manualSession = ManualSessionPolicy()
    var workLeaseGate = WorkSessionLeaseGate()
    /// Preparation is process-local. Restart/exit cannot recreate its authority.
    var workSessionPreparation: WorkSessionPreparation?
    var workExtensionPreparationReceipt: WorkSessionExtensionPreparationReceipt?
    var workExtensionRollback: (committedID: UUID, previous: WorkSessionLease)?
    /// Same-boot OS consumption receipt; no active job is restored from it.
    var workSleepConsumption: WorkSessionSleepConsumption?
    var lidLeaseTimer: DispatchSourceTimer?
    var lidRestoreRetryTimer: DispatchSourceTimer?
    var lastLidLeasePower: PowerSource?
    var lidRestoreFailure: (key: String, error: String, retryAt: Double)?
    var lidRestoreAttemptCount = 0
    var lidManagedSessionID: UUID?
    /// Process-local end-only authority. None of it survives a helper restart.
    var lidEndAuthority: (id: UUID, lease: WorkSessionLease, deadline: Double)?
    var batteryEndPreparation: (lease: WorkSessionLease, deadline: Double)?
    var legacyRestoreFailures: [Bool: (key: String, error: String)] = [:]
    var automaticHoldGate = AutomaticHoldGate()
    var savedProtection: ProtectionState?
    var service: LocalService?
    var revision: UInt64 = 0
    let epoch = UUID().uuidString
    var replyCache: [(UInt32, ServiceRequest, ServiceReply)] = []
    var lastApplyError: String?
    var latestStatus: Status?
    var ownership = PowerOwnership()
    /// An accepted write with a temporarily unreadable effect is verified on the next
    /// fresh read, tied to the exact recovery entry rather than to a later owner's work.
    var pendingOverrideVerification: (enabled: Bool, ownership: PowerOwnership)?
    var recoveryLockDepth = 0
    var activeRecoveryLock: RecoveryLock?
    var writerTerminationConfirmed = true
    var displayGate = DisplaySleepGate()
    var nativeDisplayCache = NativeDisplayProbeCache()
    var nativeDisplayReadInFlight = false
    var nativeHandoffGate = NativeClamshellHandoffGate()
    var powerGate = StablePowerGate()
    var appExitObserver: DispatchSourceProcess?
    var guiAuthority = GUISessionAuthority()
    var guiSessionObserver: DarwinNotification?
    var effectiveEnabled: Bool {
        state.userSessionCoordinated != true && control.enabled && protection.blockReason == nil
            && !sessionSuspended && !systemSleepTransition && systemPowerObservationAvailable
            && (workSessionPreparation == nil || (ownsOverride && currentSnapshot().sleepDisabled))
    }
    var protectionPath: String { URL(fileURLWithPath: statusPath).deletingLastPathComponent().appendingPathComponent("protection-state.json").path }
    var seenSleepNowRequest: Double?
    var sleepNowUntil = Date.distantPast
    var sleepNowIntent = SleepIntent.user
    var sleepRetryIntent = SleepIntent.closedLid
    var systemSleepTransition = false
    var sleepRetryGeneration: UInt64 = 0
    var sleepRetryActive = false {
        didSet { sleepRetryGeneration &+= 1 }
    }
    var sleepDeferralReason: String?
    var closedLidSleep = ClosedLidSleepTracker()
    var pendingTriggers: Set<Trigger> = []
    var pendingWork: DispatchWorkItem?
    var lastEvent: EventKind?
    var lastEventAt: Double?
    var lastLidClosed: Bool?
    var sleepAttempt = 0
    /// What the next forced sleep is logged as: a "sleep now" request, or overheating.
    var sleepNowReason = EventKind.sleepNow

    // Battery hold
    let statePath: String
    var state = HelperState()
    var stateJournalUnreadable = false
    var holdWasActive = false
    var holdingOnBattery = false
    var fastTimer: DispatchSourceTimer?
    var thermalObserver: NSObjectProtocol?
    var lastHoldEnd: HoldEnd?
    var lastHoldEndAt: Double?

    // AC heat guard and the last-resort sleeps on power
    var criticalAlerted = false
    var thermalAlertAt: Double?
    var safetyNet = SafetyNetTracker()
    var overheatSleepAt: Double?
    var weakChargerSleepAt: Double?

    // Usage stats and lid sessions
    let usagePath: String
    var usage = Usage()
    var usageSavedAt = Date.distantPast

    /// The explicit battery-hold limits, refreshed on every check.
    var limits: UserLimits?
    /// The settings line last logged, to log again only when something in it changes.
    var loggedSettings: String?
    var loggedRecordingActive: Bool?
    var loggedObservation: String?
    var logArchiveFailed = false
    var logPath: String { dryRun ? URL(fileURLWithPath: statusPath).deletingLastPathComponent().appendingPathComponent("helper.log").path : TetherPaths.helperLog }

    // Sleep log
    var lastSleepRequestAt = Date.distantPast
    var justWoke = false
    var sleepLogReadInFlight = false
    var sleepLogReadQueued = false

    /// Tracks whether the menu bar app still exists (see `retireIfAppIsGone`).
    var appPresence = AppPresence()

    var rootPort: io_connect_t = 0
    var powerNotifyPort: IONotificationPortRef?
    var powerNotifier: io_object_t = 0
    var systemPowerNotificationsRegistered = false
    var powerSourceNotificationsRegistered = false
    var lidNotificationsRegistered = false
    var interestPort: IONotificationPortRef?
    var clamshellNotifier: io_object_t = 0
    var timer: DispatchSourceTimer?
    var termSource: DispatchSourceSignal?
    var controlObserver: DarwinNotification?

    let fakePath: String?
    /// A laptop with a lid and a battery. On a desktop "always on AC" would mean never sleeping,
    /// so there the helper only reports and never touches sleep settings.
    var supported: Bool { (dryRun && fakePath != nil) || SystemProbe.capabilities.lidControlAvailable }
    var simulatedSleepDisabled: Bool?
    var simulatedPowerModes: [Bool: Int] = [:]

    init(dryRun: Bool, controlPath: String, statusPath: String, fakePath: String? = nil) {
        self.dryRun = dryRun
        self.controlPath = controlPath
        self.statusPath = statusPath
        self.fakePath = fakePath
        let folder = URL(fileURLWithPath: statusPath).deletingLastPathComponent()
        statePath = folder.appendingPathComponent("helper-state.json").path
        usagePath = folder.appendingPathComponent("usage.json").path
    }

    func start() {
        log("started v\(TetherPaths.version)\(dryRun ? " (dry-run)" : "")")
        note(.started)
        if !supported {
            log("no built-in battery or lid: this Mac is not a laptop, so Tether leaves sleep settings alone")
        }
        // A battery hold depends on these; an unreadable sensor makes every hold end at once.
        let readings = currentReadings()
        if let t = readings.temperature {
            log(String(format: "sensors: battery %.1f°C, thermal %d, charge %@%%", t, readings.thermal,
                       readings.batteryPercent.map(String.init) ?? "?"))
        } else {
            log("battery temperature unavailable; optional diagnostic only; OS thermal pressure remains active")
        }
        secureSupportFolder()
        if let saved = JSONFile.read(HelperState.self, from: statePath) { state = saved }
        else if FileManager.default.fileExists(atPath: statePath) {
            stateJournalUnreadable = true
            protection.block("stateUnreadable")
            log("helper execution journal unreadable: original retained; new grants refused")
        } else {
            // A new installation has no legacy execution authority to restore.
            // An old Control(enabled: true) must never create a root-owned
            // maintenance session before the GUI grants a finite v3 lease.
            state.lidExecutionVersion = 3
            state.userSessionCoordinated = true
            saveState()
        }
        // A saved event is evidence, never authority to replay a Sleep call.
        // Recovery after an interrupted executor only restores our own setting.
        if usesV3LidExecution, var receipt = state.lidEndReceipt, receipt.phase != .consumed {
            receipt.phase = .consumed; receipt.outcome = "executorInterrupted"
            state.lidEndReceipt = receipt
            _ = saveState()
        }
        if usesV3LidExecution {
            // A restarted executor has no live app decision. Revoke its saved
            // native exec permission before any recovery/new service handshake.
            state.workSessionLease = nil
            _ = saveState()
        }
        if let consumed = state.workSleepConsumption,
           consumed.isValid(sessionID: consumed.sessionID, sequence: consumed.sequence, now: manualClock, boot: currentBootID) {
            workSleepConsumption = consumed
        }
        if enforcesGUIAuthority {
            state.controllerUID = state.controllerUID ?? state.appUID
            if let owner = state.guiOwner { guiAuthority.bind(owner.login) }
        }
        manualSession = ManualSessionPolicy(batteryBudget: state.manualBatteryBudget, boot: currentBootID)
        if let saved = JSONFile.read(PowerOwnership.self, from: ownershipPath), saved.isValid(for: currentBootID) { ownership = saved }
        else if FileManager.default.fileExists(atPath: ownershipPath),
                JSONFile.read(PowerOwnership.self, from: ownershipPath) == nil { protection.block("ownershipUnreadable") }
        watchAppExit()
        usage = JSONFile.read(Usage.self, from: usagePath) ?? Usage()
        var migrationFailed = protection.blockReason != nil
        var migrationRequiresResume = false
        do {
            if let report = try SettingsMigration.migrate(controlPath: controlPath, usage: usage) {
                migrationRequiresResume = report.cleared.contains("temperaturePolicyRequiresResume")
                log("settings migrated: schema \(report.fromSchema) -> \(report.toSchema), original retained")
            }
        } catch {
            migrationFailed = true
            log("settings migration failed: \(error.localizedDescription)")
        }
        // Seed the lid state so only real opens/closes get logged. The clamshell message also
        // fires when AppleClamshellCausesSleep flips on a power change, with the lid unchanged.
        lastLidClosed = currentSnapshot().lidClosed
        lastLidLeasePower = currentSnapshot().power
        loadControl(initial: true)
        let legacyPath = URL(fileURLWithPath: statusPath).deletingLastPathComponent().appendingPathComponent("suite-state.json").path
        let savedPath = FileManager.default.fileExists(atPath: protectionPath) ? protectionPath : legacyPath
        if let saved = JSONFile.read(ProtectionState.self, from: savedPath) { protection = saved }
        else if FileManager.default.fileExists(atPath: savedPath) {
            protection.block("stateUnreadable")
            log("protection state unreadable: stopped until explicit resume")
        }
        protection.restart(boot: currentBootID)
        if protection.retireDisplayBlock() {
            displayGate.stop()
            log("legacy display limitation retained separately; work selection and battery budget preserved")
        }
        if migrationFailed { protection.block("migrationFailed"); control.enabled = false }
        if migrationRequiresResume { protection.block("settingsChanged") }
        if control.pendingHoldMinutes != nil {
            var next = control; next.pendingHoldMinutes = nil; next.holdSource = nil
            if !commitControl(next) { protection.block("stateWriteFailed") }
        }
        // A helper restart on battery must not silently renew a timer.
        automaticHoldGate.reset(eligible: control.enabled && control.condition.includesBattery && currentSnapshot().power == .battery)
        startService()
        guiSessionObserver = DarwinNotification(observing: "com.apple.coregraphics.GUIConsoleSessionChanged") { [weak self] in
            self?.schedule(.settings)
        }
        refreshSettings()
        watchPowerSource()
        watchSystemPower()
        watchClamshell()
        watchDisplays()
        controlObserver = DarwinNotification(observing: TetherPaths.controlChanged) { [weak self] in
            self?.schedule(.settings)
        }
        // Foundation requires reading thermalState before registering for changes.
        _ = ProcessInfo.processInfo.thermalState
        // Public Foundation notification; reread thermalState for the current value.
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.schedule(.thermal)
        }

        // Safety net in case a notification is ever missed.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.trimLogIfNeeded()
            self?.schedule(.timer)
        }
        timer.resume()
        self.timer = timer

        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in self?.stop() }
        term.resume()
        termSource = term

        schedule(.start)
        reconcileSleepLog()
    }

    /// Plugging in fires several notifications; fold a burst into one pass.
    func schedule(_ trigger: Trigger) {
        if trigger == .display || trigger == .wake {
            nativeDisplayCache.invalidate()
            nativeHandoffGate.reset()
        }
        pendingTriggers.insert(trigger)
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    func evaluate() {
        lastApplyError = nil
        var triggers = pendingTriggers
        pendingTriggers = []
        if loadControl(initial: false) { triggers.insert(.sleepNow) }
        refreshSettings()

        if retireIfAppIsGone() { return }
        simulateSystemPowerTransition()
        // A root manual hold cannot keep running without the notification that
        // consumes it on OS Sleep. Its spent battery budget remains unchanged.
        if !systemPowerObservationAvailable { manualSession.end(.observationUnavailable) }
        // IOKit has announced sleep but the ordinary snapshot can still say Full Wake.
        // Do not let a queued settings/power/timer event re-acquire an override meanwhile.
        if systemSleepTransition { writeStatus(readings: currentReadings()); return }
        refreshGUIAuthority()
        refreshNativeDisplayEvidence()
        var snapshot = currentSnapshot()
        let readings = currentReadings()
        if usesV3LidExecution {
            evaluateLidLease(snapshot: snapshot, readings: readings, triggers: triggers)
            return
        }
        if sleepNowIntent == .protection,
           !snapshot.lidClosed || !snapshot.fullWake || snapshot.power == .unknown || !control.enabled || sessionSuspended ||
            (snapshot.power == .ac && !control.condition.includesAC) {
            sleepNowUntil = .distantPast
            sleepRetryActive = false
        }
        if state.appPID != nil, !appProcessAlive { disconnectApp(reason: "process no longer alive") }
        if powerGate.observe(snapshot.power, now: dryRun ? (fake["powerClock"] as? Double ?? ProcessInfo.processInfo.systemUptime) : ProcessInfo.processInfo.systemUptime) {
            protection.confirmPowerReturn()
            if state.userSessionCoordinated == true, state.manualBatteryBudget != nil {
                state.manualBatteryBudget = nil
                if !saveState() { protection.block("stateWriteFailed") }
            }
        }
        guard supported else {
            writeStatus(readings: readings)
            return
        }
        if triggers.contains(.lid), let lidClosed = snapshot.observedLidClosed, lidClosed != lastLidClosed {
            lastLidClosed = lidClosed
            // Log only: clamshell mode itself does nothing on a lid change.
            log("lid \(snapshot.lidClosed ? "closed" : "opened") on \(snapshot.power.rawValue)"
                + (snapshot.sleepDisabled ? ", clamshell holds" : ""))
        }
        restoreLegacyPowerModes()
        if state.userSessionCoordinated == true { updateCoordinatedWork(snapshot, readings: readings) }
        else { updateManualSession(snapshot, readings: readings) }
        let managing = snapshot.fullWake && Policy.wantsClamshell(snapshot, enabled: effectiveEnabled,
            sleepNowPending: Date() < sleepNowUntil, batteryHold: holdWasActive, condition: control.condition,
            ownsOverride: ownsOverride, manualSession: manualSessionAllowed)
        if managing, !readings.isValid {
            protection.block("sensor")
            if snapshot.lidClosed {
                sleepNowIntent = .protection
                sleepNowUntil = Date().addingTimeInterval(20)
                triggers.insert(.sleepNow)
            }
        } else if managing, !snapshot.lidClosed, readings.thermal >= 2 {
            protection.block("thermal")
        }
        observeOwnership(snapshot)
        var holdActive = false
        if state.userSessionCoordinated != true {
            updatePendingHold(snapshot)
            updateAutomaticHold(snapshot)
            holdActive = updateBatteryHold(snapshot, readings: readings)
        }
        // Resolve protection for Tether's AC hold before enabling an override.
        // Physical-monitor native clamshell remains macOS's responsibility.
        updateSafetyNet(snapshot, clamshellOn: ((effectiveEnabled && control.condition.includesAC) || manualSessionAllowed) && snapshot.fullWake && !snapshot.defersToDisplaySetup,
                        readings: readings)
        if Date() < sleepNowUntil, protection.blockReason != nil { triggers.insert(.sleepNow) }
        // Persist the protection state before applying any keep-awake override.
        if !saveProtection() {
            protection.block("stateWriteFailed")
            if holdWasActive { consumeHold() }
        }
        if protection.blockReason != nil { manualSession.end(.protection) }
        updateNativeClamshellHandoff(snapshot)
        snapshot = currentSnapshot()
        if ownsOverride, snapshot.observedSleepDisabled == nil,
           !Policy.wantsClamshell(snapshot, enabled: effectiveEnabled,
                sleepNowPending: Date() < sleepNowUntil, batteryHold: holdWasActive,
                condition: control.condition, ownsOverride: ownsOverride, manualSession: manualSessionAllowed) {
            lastApplyError = "powerObservationUnavailable"
        }
        let workRequested = manualSessionAllowed || (effectiveEnabled &&
            ((snapshot.power == .ac && control.condition.includesAC) || (snapshot.power == .battery && holdWasActive)))
        let sleepAuthorityConfirmed = systemPowerObservationAvailable && (!enforcesGUIAuthority || guiControlConfirmed)
        if !sleepAuthorityConfirmed { closedLidSleep.reset() }
        let releaseNeedsSleep = sleepAuthorityConfirmed && closedLidSleep.update(snapshot: snapshot, ownsOverride: ownsOverride,
            workRequested: workRequested, now: sleepRequestClock)
        if !releaseNeedsSleep, sleepRetryIntent == .closedLid { sleepRetryActive = false }
        if !releaseNeedsSleep, !(sleepNowIntent == .protection && Date() < sleepNowUntil) { sleepDeferralReason = nil }
        let actions = Policy.actions(for: snapshot, triggers: triggers, enabled: effectiveEnabled,
                                     sleepNowPending: Date() < sleepNowUntil, batteryHold: holdWasActive, condition: control.condition,
                                     ownsOverride: ownsOverride, releaseNeedsSleep: releaseNeedsSleep, manualSession: manualSessionAllowed)
        if control.debugLoggingActive {
            log(String(format: "check [%@]: power=%@ lid=%@ sleepDisabled=%d fullWake=%d external=%d battery=%@%% %@ thermal=%d enabled=%d hold=%d -> %@",
                       triggers.map(\.rawValue).sorted().joined(separator: ","), snapshot.power.rawValue,
                       snapshot.lidClosed ? "closed" : "open", snapshot.sleepDisabled ? 1 : 0, snapshot.fullWake ? 1 : 0,
                       snapshot.externalDisplay ? 1 : 0, readings.batteryPercent.map(String.init) ?? "?",
                       readings.temperature.map { String(format: "%.1fC", $0) } ?? "temp?", readings.thermal,
                       control.enabled ? 1 : 0, holdActive ? 1 : 0,
                       actions.isEmpty ? "no action" : actions.map { "\($0)" }.joined(separator: ", ")))
        }
        for action in actions { perform(action, snapshot: snapshot, triggers: triggers) }

        // Whether clamshell mode is on once this pass's actions have landed.
        let clamshellOn = ownsOverride && currentSnapshot().observedSleepDisabled == true && (effectiveEnabled || manualSessionAllowed)
        if sleepAuthorityConfirmed {
            closedLidSleep.recordManagedWork(snapshot: currentSnapshot(), ownsOverride: ownsOverride, workRequested: workRequested)
        }
        if clamshellOn { sleepDeferralReason = nil }
        updateDisplay(snapshot, clamshellOn: clamshellOn)
        updateMonitoring()
        updateUsage(snapshot, clamshellOn: clamshellOn, readings: readings)
        saveProtection()
        writeStatus(readings: readings)
    }

    private func updateMonitoring() {
        guard state.appPID != nil || manualSession.active || holdWasActive || safetyNet.isWatching || displayGate.pending || ownsOverride || (control.enabled && !powerGate.confirmedAC) else {
            fastTimer?.cancel(); fastTimer = nil; return
        }
        guard fastTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.schedule(.timer) }
        timer.resume(); fastTimer = timer
    }

    /// Returns true when the file carries a new "sleep now" request.
    @discardableResult
    func loadControl(initial: Bool) -> Bool {
        guard let loaded = JSONFile.read(Control.self, from: controlPath), loaded.isSupported else {
            lastApplyError = "configurationUnreadable"
            protection.block("stateUnreadable")
            return false
        }
        if loaded != control { revision &+= 1 }
        control = loaded
        if let hold = loaded.batteryHoldUntil, hold != state.holdValue {
            // A later deadline for the running hold extends it: the 4-hour cap keeps counting from
            // when the hold was first seen, so extending can't get round it.
            let extending = holdWasActive && state.holdSeenAt != nil
            let clock = ContinuousTime.now
            if !extending { state.holdContinuousStart = clock }
            state.holdContinuousDeadline = min(clock + max(0, hold - Date().timeIntervalSince1970),
                                               (state.holdContinuousStart ?? clock) + SafetyPolicy.maxHold(limits))
            state.holdValue = hold
            if !extending { state.holdSeenAt = Date().timeIntervalSince1970 }
            saveState()
            if !initial { log(extending ? "battery hold extended" : "battery hold armed") }
        }
        // A hold never survives a helper restart or reboot: ending it is the safe side.
        if initial, let hold = loaded.batteryHoldUntil, hold != state.consumedHold {
            state.consumedHold = hold
            saveState()
        }
        guard let request = loaded.sleepNowRequest, request != seenSleepNowRequest else { return false }
        seenSleepNowRequest = request
        // A request left in the file across a restart is stale.
        guard !initial, Date().timeIntervalSince1970 - request < 60 else { return false }
        sleepNowUntil = Date().addingTimeInterval(20)
        sleepNowIntent = .user
        sleepRetryActive = false
        if holdWasActive { endHold(.cancelled, readings: nil) }
        return true
    }

    /// Picks up the limits in force and logs them, after clamping to the defaults (they can only
    /// be stricter), whenever a setting changes.
    func refreshSettings() {
        let recording = control.debugLoggingActive
        if loggedRecordingActive != recording {
            loggedRecordingActive = recording
            log("detailed logging \(recording ? "on" : "off")\(recording ? control.debugLogUntil.map { " until \(Self.stampFormat.string(from: Date(timeIntervalSince1970: $0)))" } ?? " (legacy manual stop)" : "")")
        }
        limits = control.limits
        let line = String(format: "limits: floor %d%%, max %.1f h; OS serious/critical stops own hold; Celsius diagnostic only; energy modes managed by macOS",
                          SafetyPolicy.floor(limits), SafetyPolicy.maxHold(limits) / 3600)
        guard line != loggedSettings else { return }
        loggedSettings = line
        log(line)
    }

    func perform(_ action: Action, snapshot: Snapshot, triggers: Set<Trigger>) {
        switch action {
        case .setSleepDisabled(true):
            guard applyOverride(true) else { return }
            if snapshot.power == .battery {
                log("battery hold: clamshell on")  // the hold's own event stays the last one
            } else {
                note(.clamshellOn)
            }
        case .setSleepDisabled(false):
            guard applyOverride(false) else { return }
            // Releasing an override is not a sleep request. App exit, native-display
            // handoff and protection stops all reach this path as well.
            if triggers.contains(.sleepNow), sleepNowIntent == .user { note(.clamshellOffSleepNow) }
            else if !control.enabled { note(.clamshellOffDisabled) }
            else { note(.clamshellReleased) }
        case .sleepSystem:
            guard !sleepRetryActive else { return }
            let intent: SleepIntent = triggers.contains(.sleepNow) ? sleepNowIntent : .closedLid
            guard allowsSleepRequest(intent) else { return }
            sleepRetryIntent = intent
            let event = triggers.contains(.sleepNow) ? sleepNowReason : .lidSleep
            sleepNowReason = .sleepNow
            note(event)
            if event == .overheatSleep || event == .weakChargerSleep { logReadings(currentReadings()) }
            lastSleepRequestAt = Date()
            sleepRetryActive = true
            sleepAttempt = 0
            requestSleep(attemptsLeft: 20)
        }
    }

    /// The kernel refuses sleep until powerd has passed it the cleared flag, so retry briefly.
    private var sleepRequestClock: Double {
        dryRun ? (fake["sleepRequestClock"] as? Double ?? ContinuousTime.now) : ContinuousTime.now
    }

    /// Retry callbacks can see a changed lid/user before the next evaluation.
    /// Cancel at that observation boundary; only foreign-work deferrals retain
    /// the same finite request. Never extend its deadline by trying again.
    private func confirmsClosedLidSleep(_ snapshot: Snapshot) -> Bool {
        guard !systemSleepTransition, systemPowerObservationAvailable,
              !enforcesGUIAuthority || guiControlConfirmed else {
            closedLidSleep.reset(); sleepDeferralReason = nil
            return false
        }
        let workRequested = manualSessionAllowed || (effectiveEnabled &&
            ((snapshot.power == .ac && control.condition.includesAC) || (snapshot.power == .battery && holdWasActive)))
        let confirmed = closedLidSleep.update(snapshot: snapshot, ownsOverride: ownsOverride,
            workRequested: workRequested, now: sleepRequestClock)
        if !confirmed { sleepDeferralReason = nil }
        return confirmed
    }

    func requestSleep(attemptsLeft: Int, generation: UInt64? = nil) {
        let generation = generation ?? sleepRetryGeneration
        guard sleepRetryActive, generation == sleepRetryGeneration else { return }
        guard allowsSleepRequest(sleepRetryIntent) else {
            sleepRetryActive = false
            writeStatus(readings: currentReadings())
            return
        }
        sleepAttempt += 1
        usage.stats.recordSleepRequestAttempt(now: Date())
        let result: IOReturn
        if dryRun {
            log("[dry-run] IOPMSleepSystem")
            result = fake["sleepFailure"] as? Bool == true ? -1 : kIOReturnSuccess
        } else {
            let pm = IOPMFindPowerManagement(kIOMainPortDefault)
            result = pm != 0 ? IOPMSleepSystem(pm) : -1
            if pm != 0 { IOServiceClose(pm) }
        }
        if result == kIOReturnSuccess {
            if sleepAttempt > 1 { log("sleep accepted on attempt \(sleepAttempt)") }
            closedLidSleep.reset()
            sleepDeferralReason = nil
            sleepRetryActive = false
            return
        }
        guard attemptsLeft > 1 else {
            note(.sleepRefused)
            if allowsSleepRequest(sleepRetryIntent) {
                usage.stats.recordSleepRequestAttempt(now: Date())
                pmset(["sleepnow"])
            }
            closedLidSleep.reset()
            sleepRetryActive = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.sleepRetryActive, self.sleepRetryGeneration == generation else { return }
            self.requestSleep(attemptsLeft: attemptsLeft - 1, generation: generation)
        }
    }

    func allowsSleepRequest(_ intent: SleepIntent) -> Bool {
        let snapshot = currentSnapshot()
        if intent == .closedLid, !confirmsClosedLidSleep(snapshot) { return false }
        guard !systemSleepTransition else { return false }
        // Losing GUI control never forces the newly active user's whole Mac to sleep.
        if enforcesGUIAuthority, !guiControlConfirmed { return false }
        if intent == .protection, !control.enabled || sessionSuspended { return false }
        guard SleepRequestPolicy.allows(intent, snapshot: snapshot, requestPending: Date() < sleepNowUntil,
            enabled: effectiveEnabled, batteryHold: holdWasActive, condition: control.condition, foreignKeepAwake: false,
            manualSession: manualSessionAllowed)
        else { return false }
        let foreign: Bool?
        if intent == .user { foreign = nil }
        else if dryRun {
            foreign = fake["sleepRequestsUnavailable"] as? Bool == true ? nil
                : fake["foreignKeepAwake"] as? Bool == true
        } else {
            let ownPIDs = [getpid(), state.appPID].compactMap { $0 }
            foreign = SystemProbe.closedLidSleepBlockerSnapshot(excluding: ownPIDs).map { !$0.isEmpty }
        }
        let reason = intent == .user || foreign == false ? nil
            : foreign == true ? "otherRequests" : "observationUnavailable"
        if sleepDeferralReason != reason {
            sleepDeferralReason = reason
            if let reason { log("automatic sleep deferred: \(reason); foreign requests preserved") }
        }
        let latest = currentSnapshot()
        if intent == .closedLid, !confirmsClosedLidSleep(latest) { return false }
        return SleepRequestPolicy.allows(intent, snapshot: latest, requestPending: Date() < sleepNowUntil,
            enabled: effectiveEnabled, batteryHold: holdWasActive, condition: control.condition, foreignKeepAwake: foreign,
            manualSession: manualSessionAllowed)
    }

    func stop() {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        saveProtection()
        service?.stop()
        // An unmanaged SleepDisabled would keep a closed Mac awake on battery.
        appExitObserver?.cancel()
        if ownsOverride {
            note(.stopping)
            _ = applyOverride(false)
        }
        restoreLegacyPowerModes()
        JSONFile.write(usage, to: usagePath, permissions: 0o644)
        log("stopped")
        exit(0)
    }
}
