import AppKit
import Foundation
import IOKit.ps
import OSLog
import TetherCore

struct UserSessionEnvironment {
    var power: PowerSource
    var thermal: Int?
    var fullWake: Bool?
    var batteryPercent: Int?
    var lowPowerWarning: Bool? = false
    var lowPowerMode: Bool? = false

    static func current() -> Self {
        Self(power: SystemProbe.powerSource(), thermal: ProcessInfo.processInfo.thermalState.rawValue,
             fullWake: SystemProbe.observedFullWake, batteryPercent: SystemProbe.batteryPercent(),
             lowPowerWarning: currentBatteryWarning(), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    private static func currentBatteryWarning() -> Bool? {
        // IOPowerSources.h: none=1, early=2, final=3. Unknown stays unavailable.
        switch IOPSGetBatteryWarningLevel().rawValue {
        case 1: false
        case 2, 3: true
        default: nil
        }
    }
}

private final class PowerSourceObservationContext {
    weak var controller: UserSessionController?
    init(_ controller: UserSessionController) { self.controller = controller }
}

/// General idle sessions, owned by the logged-in app, including incomplete hardware
/// observations. It never connects to the root service or changes another application's
/// request. AppModel relays its verified finite decision for notebook lid support.
@MainActor
final class UserSessionController {
    static let preferenceKey = "userOwnedSessionSettings"
    private let defaults: UserDefaults
    private let driver: IdleAssertionDriver
    private let displayDriver: IdleAssertionDriver
    private let guiProbe: (() -> GUISessionObservation)?
    private let environmentProbe: (() -> UserSessionEnvironment)?
    private let wallClock: () -> Date
    private let continuousClock: () -> Double
    private let boot: String
    private var guiAuthority = GUISessionAuthority()
    private var policy: IdleSessionPolicy
    private var readable = true
    private var savedSettings: IdleSessionSettings
    private var migrationOriginal: Data?
    private var migrationSourceVersion = 1
    private var latestPower = PowerSource.unknown
    private var v4LastKnownPower = PowerSource.unknown
    private var v4PowerGeneration: UInt64 = 0
    private var v4Evaluating = false
    private var v4Observations: [V4Observation] = []
    let v4ConditionSource = V4NativeObservations()
    private(set) var v4RuleEvaluation: V4RuleEvaluation?
    private(set) var v4WorkEvents = V4WorkEventStore()
    private var manualOptions: V4RequestOptions?
    private struct PendingExtension {
        var original: IdleSessionPolicy
        var proposed: IdleSessionPolicy
        var preparation: WorkSessionExtensionPreparation
        var prepared = false
        var committed = false
    }
    private var pendingExtension: PendingExtension?
    private var extensionRollbackID: UUID?
    private var latestThermal: Int?
    private var latestBatteryPercent: Int?
    private var latestLowPowerWarning: Bool? = false
    private var latestLowPowerMode: Bool? = false
    private var currentUser = false
    private var fullWake: Bool?
    private var manualWallDeadline: Date?
    private var reportedContinuousDeadline: Double?
    private var batteryWallDeadline: Date?
    private var batteryWallStart: Date?
    private var reportedBatteryDeadline: Double?
    private var automaticPauseWallDeadline: Date?
    private var reportedAutomaticPauseDeadline: Double?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var observing = false
    private(set) var powerSourceObserver: CFRunLoopSource?
    private var powerSourceContext: PowerSourceObservationContext?
    private var powerTransitionToken = UUID()
    private var pendingPowerTransition: WorkSessionPowerTransitionReceipt?
    private var endConsumptionID: UUID?
    private var lastExecutorEndAt: Double?
    private var rootProtectionLatchID: UUID?
    private var protectionResumeID: UUID?
    private var ended = false
    private var endRequested = false
    private var failure: String?
    private(set) var activity = UserSessionActivity()
    private var commandRecordingID: UUID?
    private(set) var activityStorageError: String?
    var activityPersistenceEnabled = false
    private var rootHandoffPrepared: Bool
    private var explicitlyActivated = false
    let sessionID = UUID()
    private var workSequence: UInt64 = 0
    private var lastConfirmedWorkLease: WorkSessionLease?
    private var closedLidObservation: Bool?
    private var zeroBrightnessEligible = false
    private var rootSleepCoordinated = false
    private var awaitingRootSleepConsumption = false
    private var pendingWorkspaceSleepAt: Double?
    private var acknowledgedSleepConsumption: WorkSessionSleepConsumption?
    private let log = Logger(subsystem: "io.github.jukqaz.tether", category: "UserSession")
    var onChange: ((UserSessionStatus) -> Void)?
    var onActivityChange: (() -> Void)?
    var onSleepBoundary: (() -> Void)?
    /// The app's lifetime writer lease is independent of GUI observation and the
    /// command socket. Standalone deterministic/native driver tests own their fixture.
    var ownershipProbe: () -> Bool = { true }
    /// Deterministic persistence failure seam; production writes the same user
    /// preference record and confirms it before a new native acquisition.
    var persistenceProbe: (() -> Bool) = { true }
    var idleSecondsProbe: () -> Double? = { UserInput.idleSeconds }
    private(set) var displayIdleObservation: (seconds: Double, validUntil: Double)?

    init(defaults: UserDefaults, backend: IdleAssertionBackend = NativeIdleAssertionBackend(),
         displayBackend: IdleAssertionBackend = NativeIdleAssertionBackend(type: .display),
         guiProbe: (() -> GUISessionObservation)? = { GUISessionProbe.callerObservation() },
         environmentProbe: (() -> UserSessionEnvironment)? = { UserSessionEnvironment.current() },
         legacyControl: Control? = nil, legacyBridge: WorkSessionBridge? = nil,
         requiresRootHandoff: Bool = false, boot: String = ContinuousTime.bootID, wallClock: @escaping () -> Date = Date.init,
         continuousClock: @escaping () -> Double = { ContinuousTime.now }) {
        self.defaults = defaults
        if let saved = defaults.data(forKey: "v4DecisionHistory") {
            do { activity = try UserSessionActivity(archive: saved) }
            catch { activityStorageError = L("Previous decision history could not be read.", "이전 결정 기록을 읽지 못했습니다.") }
        }
        self.guiProbe = guiProbe
        self.environmentProbe = environmentProbe
        self.wallClock = wallClock
        self.continuousClock = continuousClock
        self.boot = boot
        rootHandoffPrepared = !requiresRootHandoff
        driver = IdleAssertionDriver(backend: backend)
        displayDriver = IdleAssertionDriver(backend: displayBackend)
        var settings = IdleSessionSettings()
        // A fresh, unedited controller may discover a legacy writer later.
        // General work is independent; only confirmed choice import is pending.
        settings.legacyRootConfigurationPending = true
        var previousSettings: IdleSessionSettings?
        if let raw = defaults.data(forKey: Self.preferenceKey) {
            if let decoded = try? JSONDecoder().decode(IdleSessionSettings.self, from: raw),
               let migrated = decoded.migratedToCurrentVersion {
                settings = migrated; previousSettings = decoded
                if migrated.version != decoded.version {
                    migrationOriginal = raw
                    migrationSourceVersion = decoded.version
                    if decoded.version == 1, let legacyControl, legacyControl.isSupported {
                        settings.limits = legacyControl.limits.map { UserLimits(batteryFloor: $0.batteryFloor) }
                    }
                }
            } else {
                readable = false; settings.enabled = false
                failure = L("Saved session settings need review; original data retained.", "세션 설정 확인이 필요합니다. 원본은 보존했습니다.")
            }
        } else if let legacyControl, legacyControl.isSupported {
            // Preserve explicit off. Never translate a notebook's AC choice into
            // an always-on desktop trigger. Temporary holds are not migrated.
            settings.enabled = legacyControl.enabled
            settings.limits = legacyControl.limits.map { UserLimits(batteryFloor: $0.batteryFloor) }
        }
        if let legacyControl, legacyControl.isSupported, !legacyControl.enabled,
           previousSettings?.version != IdleSessionSettings.currentVersion || settings.legacyRootConfigurationPending == true {
            // A known explicit old off must prevent acquisition before the
            // asynchronous preparation ACK, even when saved common prefs say on.
            // Current v3 automatic-off projections are not a whole user stop.
            settings.enabled = false; settings.automaticEnabled = false
        }
        savedSettings = previousSettings ?? settings
        policy = IdleSessionPolicy(settings: settings, boot: boot)
        if let legacyBridge, legacyBridge.version == 1 {
            rootSleepCoordinated = legacyBridge.coordinated
            if !legacyBridge.coordinated, let legacyControl, legacyControl.isSupported {
                policy.adoptLegacyConfiguration(legacyControl)
            }
            if legacyBridge.coordinated { policy.resolveLegacyConfiguration() }
            policy.mergeLegacyBudgets(automatic: legacyBridge.automaticBudget, manual: legacyBridge.manualBudget)
            if let reason = WorkSessionBridge.generalWorkBlockReason(legacyBridge.automaticBudget.blockReason) { policy.acceptProtection(reason) }
            if legacyBridge.stopRequested { policy.setEnabled(false) }
        }
        v4ConditionSource.onChange = { [weak self] observations in
            guard let self else { return }
            self.v4Observations = observations
            if !self.v4Evaluating { self.reevaluate() }
        }
    }

    deinit {
        timer?.invalidate()
        for token in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        if let source = powerSourceObserver {
            // The source dispatches on the main run loop. Keep its weak context
            // alive until removal even if the final strong reference is dropped
            // elsewhere; a queued callback can then only see a nil controller.
            let context = powerSourceContext
            let cleanup = {
                withExtendedLifetime(context) {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                    CFRunLoopSourceInvalidate(source)
                }
            }
            if Thread.isMainThread { cleanup() } else { DispatchQueue.main.async { cleanup() } }
        }
    }

    /// Authority to present current session observations, independent of whether
    /// the remaining battery allowance permits starting more manual work.
    var hasConfirmedSessionAuthority: Bool {
        ownershipProbe() && readable && !ended && !endRequested && !awaitingRootSleepConsumption
            && currentUser && fullWake == true
    }

    private var ownReleasePending: Bool {
        driver.releasePending || displayDriver.releasePending
            || (!policy.automaticActive && !policy.manualActive
                && (driver.assertionID != nil || displayDriver.assertionID != nil))
    }
    var canResume: Bool { hasConfirmedSessionAuthority && !ownReleasePending && policy.canResume(thermal: latestThermal) }
    private var thermalAllowsWork: Bool {
        latestThermal.map { (0..<(policy.settings.stopOnSeriousThermal ? 2 : 3)).contains($0) } == true
    }
    private var manualPowerAllowsWork: Bool {
        policy.settings.manualPowerCondition == .any
            || policy.settings.manualPowerCondition.rawValue == latestPower.rawValue
    }

    var settings: IdleSessionSettings { policy.settings }
    var runtimeMarkers: RuntimeMarkers { policy.markers }
    var sessionDecision: WorkSessionDecision { policy.decision }
    var automaticPauseActive: Bool { policy.automaticPauseActive }
    var automaticPauseUntil: Date? { policy.automaticPauseActive ? automaticPauseWallDeadline : nil }

    var status: UserSessionStatus {
        var value = UserSessionStatus(power: latestPower, thermal: latestThermal ?? -1,
            batteryPercent: latestBatteryPercent, limits: policy.settings.limits, enabled: policy.settings.enabled,
            automaticEnabled: policy.settings.automaticEnabled, automaticActive: policy.automaticActive,
            powerCondition: policy.settings.effectiveAutomaticCondition, automaticMinutes: policy.settings.automaticMinutes,
            batteryHoldUntil: policy.automaticActive ? batteryWallDeadline : nil,
            pendingBatteryMinutes: policy.pendingBatteryMinutes,
            manualActive: policy.manualActive,
            holding: driver.state == .holding && driver.expiry.map({ $0 > ContinuousTime.now }) == true,
            until: policy.manualActive ? manualWallDeadline : nil,
            blockReason: policy.settings.blockReason, error: failure,
            canStart: ownershipProbe() && readable && !ended && !endRequested && !awaitingRootSleepConsumption && !ownReleasePending && currentUser && fullWake == true && policy.settings.enabled && policy.permitsExplicitManualStart
                && thermalAllowsWork && manualPowerAllowsWork && latestPower != .unknown && policy.batteryAllowsWork
                && (latestPower != .battery || policy.manualBatteryRemaining > 0),
            manualBatteryRemaining: policy.manualBatteryRemaining.isFinite ? policy.manualBatteryRemaining : Double.greatestFiniteMagnitude,
            manualEndReason: policy.manualEndReason,
            manualMaximumMinutes: Int((latestPower == .ac ? ManualSessionPolicy.maximumTimedDuration
                : (policy.settings.batteryTimeLimit.seconds ?? 4 * 3600)) / 60),
            canStartBatteryHold: latestPower == .battery && ownershipProbe() && readable && !ended && !endRequested && !awaitingRootSleepConsumption && !ownReleasePending && currentUser && fullWake == true
                && policy.settings.enabled && policy.permitsExplicitManualStart && !policy.manualActive
                && thermalAllowsWork && manualPowerAllowsWork && latestPower != .unknown && policy.batteryAllowsWork
                && policy.pendingBatteryMinutes == nil && policy.batteryDeadline == nil
                && (latestPower != .battery || policy.batteryRemaining > 0),
            batteryRemaining: policy.batteryRemaining.isFinite ? policy.batteryRemaining : Double.greatestFiniteMagnitude,
            manualStartedAt: policy.manualStart, manualContinuousDeadline: policy.effectiveManualDeadline,
            manualReschedulingLimit: policy.manualReschedulingLimit,
            manualBatteryContinuationMinutes: policy.manualActive ? policy.manualBatteryContinuationMinutes : policy.settings.manualBatteryContinuationMinutes,
            manualStartedOnBattery: policy.manualStartedOnBattery,
            keepDisplayAwake: policy.settings.keepDisplayAwake,
            displayHolding: displayDriver.state == .holding && displayDriver.expiry.map({ $0 > ContinuousTime.now }) == true,
            displayError: displayRequestError)
        value.manualRequestID = policy.manualRequestID
        value.manualExtensionID = policy.manualExtensionID
        value.manualApprovalPending = pendingExtension != nil
        value.disconnectPolicy = policy.settings.disconnectPolicy
        value.batteryTimeLimit = policy.settings.batteryTimeLimit
        value.manualPowerCondition = policy.settings.manualPowerCondition
        value.canResume = canResume
        value.observationLimited = !policy.decision.renewalAllowed
        value.ownReleasePending = ownReleasePending
        value.automaticPauseActive = automaticPauseActive
        value.automaticPauseUntil = automaticPauseUntil
        return value
    }
    var remainingFraction: Double {
        guard let start = policy.manualStart, let until = policy.effectiveManualDeadline, until > start else { return 1 }
        return min(1, max(0, (until - ContinuousTime.now) / (until - start)))
    }
    func batteryRemainingFraction(at date: Date) -> Double {
        guard let start = batteryWallStart, let until = batteryWallDeadline, until > start else { return 1 }
        return min(1, max(0, until.timeIntervalSince(date) / until.timeIntervalSince(start)))
    }
    func canExtendBatteryHold(minutes: Int, now: Double = ContinuousTime.now) -> Bool {
        false
    }

    func startObserving() {
        guard !observing, !ended else { return }
        observing = true
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            // Capture before hopping to the main queue: delayed delivery must not
            // turn a new post-wake user start into pre-sleep temporary intent.
            let observedAt = ContinuousTime.now
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.observeSystemSleep(observedAt: observedAt) }
            } else {
                DispatchQueue.main.async { self?.observeSystemSleep(observedAt: observedAt) }
            }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didWakeNotification { self?.onSleepBoundary?() }
                    self?.refresh()
                }
            })
        }
        if guiProbe != nil {
            let observerContext = PowerSourceObservationContext(self)
            powerSourceContext = observerContext
            let context = Unmanaged.passUnretained(observerContext).toOpaque()
            powerSourceObserver = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<PowerSourceObservationContext>.fromOpaque(context).takeUnretainedValue().controller?.refresh()
                }
            }, context)?.takeRetainedValue()
            if let powerSourceObserver { CFRunLoopAddSource(CFRunLoopGetMain(), powerSourceObserver, .commonModes) }
        }
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh()
    }

    func refresh() {
        checkInputs(now: continuousClock())
    }
    /// The helper's IOKit receipt owns coordinated consumption. Workspace events
    /// release native work immediately, then wait for that observation; a late
    /// duplicate cannot erase newer user intent using its delivery time.
    func observeSystemSleep(observedAt: Double) {
        onSleepBoundary?()
        guard !ended, observedAt.isFinite, observedAt >= 0, verifyOwnership() else { return }
        v4WorkEvents.consumeAll(reason: "os-sleep")
        if rootSleepCoordinated {
            awaitingRootSleepConsumption = true
            pendingWorkspaceSleepAt = max(pendingWorkspaceSleepAt ?? observedAt, observedAt)
        }
        else {
            policy.consumeSystemSleep(observedAt: observedAt)
            invalidatePowerTransition(preservingDirectBatteryIntent: true)
        }
        fullWake = false; driver.end(); displayDriver.end(); lastConfirmedWorkLease = nil
        // A delayed notification may leave newer temporary intent alive. Its
        // display clock must retain the original start/deadline until consumption
        // actually changes policy; native release alone never restarts that clock.
        if !policy.manualActive { manualWallDeadline = nil; reportedContinuousDeadline = nil }
        if policy.batteryDeadline == nil {
            batteryWallDeadline = nil; batteryWallStart = nil; reportedBatteryDeadline = nil
        }
        persist(); publish()
    }
    func acceptBridge(_ bridge: WorkSessionBridge, protection: ProtectionStatus?, preparedControl: Control? = nil,
                      now: Double = ContinuousTime.now) {
        guard verifyOwnership(), readable, !ended, bridge.version == 1 else { return }
        if let receipt = bridge.extensionPreparationReceipt, let pending = pendingExtension,
           receipt.sessionID == sessionID, receipt.sequence <= workSequence,
           receipt.preparation == pending.preparation, receipt.observedAt <= now,
           receipt.observedAt >= pending.preparation.expiresAt - 5, now < pending.preparation.expiresAt {
            pendingExtension?.prepared = true
        }
        let before = policy.settings
        let wasPrepared = rootHandoffPrepared
        let wasAwaitingSleep = awaitingRootSleepConsumption
        var consumedSleep = false
        var changedExecutorState = false
        // Apply authenticated deadline reductions before a terminal boundary.
        // They never acquire native work; reevaluation below still checks the
        // current GUI/power/thermal facts before applying an assertion.
        var batteryReceipts = bridge.batteryPermitReceipts.flatMap { $0.count <= 128 ? $0 : nil } ?? []
        if let receipt = bridge.batteryPermitReceipt, !batteryReceipts.contains(receipt) { batteryReceipts.append(receipt) }
        let knownReceipts = batteryReceipts.filter { receipt in
            receipt.sessionID == sessionID && receipt.isValid(boot: boot) && receipt.observedAt <= now
                && policy.recognizesBatteryPermit(id: receipt.permitID, observedAt: receipt.observedAt)
        }.sorted { $0.observedAt < $1.observedAt }
        for receipt in knownReceipts.prefix(128) {
            if policy.acceptBatteryPermit(id: receipt.permitID, observedAt: receipt.observedAt, deadline: receipt.deadline, now: now) {
                changedExecutorState = true
            }
        }
        if let latch = bridge.lidProtection, boot != "unknown", !latch.bootID.isEmpty, latch.bootID != "unknown",
           latch.observedAt.isFinite, latch.observedAt >= 0,
           latch.bootID != boot || latch.observedAt <= now,
           !latch.reason.isEmpty, latch.reason.utf8.count <= 256 {
            // Protection is durable across boots. Its old monotonic timestamp
            // grants no work; only this observed ID can be explicitly resumed.
            if rootProtectionLatchID != latch.id { changedExecutorState = true }
            rootProtectionLatchID = latch.id
            // Only an explicit safe Resume can acknowledge this exact latch.
            if protectionResumeID != latch.id,
               let commonReason = WorkSessionBridge.generalWorkBlockReason(latch.reason) {
                policy.acceptProtection(commonReason)
            }
        }
        if let end = bridge.lidEndReceipt, end.bootID == boot, boot != "unknown",
           end.sessionID == sessionID, end.sequence <= workSequence,
           end.observedAt.isFinite, end.observedAt >= 0, end.observedAt <= now,
           endConsumptionID != end.id, lastExecutorEndAt.map({ end.observedAt >= $0 }) ?? true {
            let commonReason = WorkSessionBridge.generalWorkBlockReason(bridge.lidProtection?.reason)
            let consumesCommonWork = end.kind != .protection || commonReason != nil
            if consumesCommonWork {
                policy.consumeExecutorEnd(observedAt: end.observedAt,
                    protection: end.kind == .protection ? commonReason : nil)
                driver.end(); displayDriver.end(); lastConfirmedWorkLease = nil
            }
            endConsumptionID = end.id; lastExecutorEndAt = end.observedAt
            changedExecutorState = true
        }
        if bridge.coordinated { rootSleepCoordinated = true }
        if let consumed = bridge.sleepConsumption,
           consumed.isValid(sessionID: sessionID, sequence: workSequence, now: now, boot: boot),
           acknowledgedSleepConsumption.map({ consumed.observedAt >= $0.observedAt }) ?? true {
            let newReceipt = acknowledgedSleepConsumption?.id != consumed.id
            // An old receipt cannot prove that a newly captured Workspace
            // boundary was consumed. Consume that boundary conservatively even
            // on a duplicate, preserving only intent started after its capture.
            // A delayed main-queue delivery retains its original capture time.
            let observedAt = pendingWorkspaceSleepAt.map { max($0, consumed.observedAt) }
                ?? (newReceipt ? consumed.observedAt : nil)
            rootSleepCoordinated = true; awaitingRootSleepConsumption = false; pendingWorkspaceSleepAt = nil
            if newReceipt { acknowledgedSleepConsumption = consumed }
            if let observedAt {
                policy.consumeSystemSleep(observedAt: observedAt)
                invalidatePowerTransition(preservingDirectBatteryIntent: true)
                driver.end(); displayDriver.end(); lastConfirmedWorkLease = nil
                // Preserve the previous reported deadline so reevaluation sees a
                // consumed timer change to nil and clears its wall-clock label.
                consumedSleep = true
            }
        }
        if let receipt = bridge.powerTransition, receipt.sessionID == sessionID,
           receipt.sequence <= workSequence, receipt.decision.token == powerTransitionToken,
           receipt.isValidObservation(now: now), !endRequested {
            pendingPowerTransition = receipt
        }
        if preparedControl != nil { rootHandoffPrepared = true }
        if !bridge.coordinated, let preparedControl {
            policy.adoptLegacyConfiguration(preparedControl, explicitActivation: explicitlyActivated)
        }
        if bridge.coordinated { policy.resolveLegacyConfiguration() }
        policy.mergeLegacyBudgets(automatic: bridge.automaticBudget, manual: bridge.manualBudget)
        if let reason = WorkSessionBridge.generalWorkBlockReason(protection?.blockReason) { policy.acceptProtection(reason) }
        if bridge.stopRequested { invalidatePowerTransition(); explicitlyActivated = false; policy.setEnabled(false) }
        if changedExecutorState || consumedSleep || wasAwaitingSleep != awaitingRootSleepConsumption || policy.settings != before
            || rootHandoffPrepared != wasPrepared || pendingPowerTransition != nil { reevaluate(now: now) }
    }
    /// AppModel calls this only after root detach/removal is positively confirmed.
    /// A missing poll, incompatible helper or failed release cannot end the sleep
    /// handshake. Preserve the final root budgets/protection and saved app choice;
    /// only a still-unconsumed Workspace boundary ends older temporary intent.
    func endRootCoordination(confirmedBridge: WorkSessionBridge? = nil, protection: ProtectionStatus? = nil,
                             now: Double = ContinuousTime.now) {
        guard verifyOwnership(), readable, !ended, now.isFinite, now >= 0 else { return }
        if let confirmedBridge { acceptBridge(confirmedBridge, protection: protection, now: now) }
        else if let reason = WorkSessionBridge.generalWorkBlockReason(protection?.blockReason) {
            policy.acceptProtection(reason)
        }
        if awaitingRootSleepConsumption, let observedAt = pendingWorkspaceSleepAt {
            policy.consumeSystemSleep(observedAt: observedAt)
            invalidatePowerTransition(preservingDirectBatteryIntent: true)
            driver.end(); displayDriver.end()
        }
        rootSleepCoordinated = false; awaitingRootSleepConsumption = false; pendingWorkspaceSleepAt = nil
        rootHandoffPrepared = true; lastConfirmedWorkLease = nil
        reevaluate(now: now)
    }
    func workLease(now: Double = ContinuousTime.now) -> WorkSessionLease? {
        guard ownershipProbe() else { return nil }
        guard readable, !ended, !endRequested, workSequence < UInt64.max else { return nil }
        // An unavailable mandatory observation can preserve an already issued
        // finite permit, but never create a helper heartbeat or lid reacquisition.
        // A consumed/expired policy still sends its empty release below.
        let releaseUnobservedPermit: Bool
        if !policy.decision.renewalAllowed, policy.decision.generalAssertionRequired {
            // An explicit output/reason opt-out must revoke the old helper grant
            // immediately. Missing observations permit a release, never a new or
            // renewed grant for the remaining GUI-owned work.
            guard let previous = lastConfirmedWorkLease else { return nil }
            releaseUnobservedPermit = (previous.lidPermit != nil && !v4LidRequested)
                || (previous.reasons.contains(.automatic) && !policy.automaticActive)
                || (previous.reasons.contains(.manual) && !policy.manualActive)
                || previous.effectiveClosedLidDisplayMode != policy.settings.closedLidDisplayMode
            if !releaseUnobservedPermit { return nil }
        } else { releaseUnobservedPermit = false }
        if !releaseUnobservedPermit, driver.state == .unverified, let previous = lastConfirmedWorkLease,
           let previousExpiry = previous.expiry, previousExpiry > now,
           let confirmedExpiry = driver.confirmedExpiry, confirmedExpiry >= previousExpiry,
           let desiredExpiry = policy.expiry, desiredExpiry >= previousExpiry,
           previous.power == latestPower,
           previous.configuration == WorkSessionConfiguration(settings: policy.settings),
            previous.effectiveClosedLidDisplayMode == policy.settings.closedLidDisplayMode,
            previous.manualDeadline == policy.effectiveManualDeadline,
            previous.sleepConsumptionID == acknowledgedSleepConsumption?.id,
            previous.endConsumptionID == endConsumptionID,
            previous.protectionResumeID == protectionResumeID,
            (previous.lidPermit != nil) == (v4LidRequested && rootHandoffPrepared),
           previous.reasons.contains(.automatic) == policy.automaticActive,
           previous.reasons.contains(.manual) == policy.manualActive,
           previous.continuationToken == (policy.hasDirectBatteryIntent ? powerTransitionToken : nil) {
            // Nil is deliberately no IPC update: an already attached helper may
            // keep only its original finite grant. This unavailable observation
            // grants no fresh lease or additional time; a stop, changed reason,
            // protection or power change falls through to an explicit empty grant.
            return nil
        }
        workSequence += 1
        var reasons: [WorkSessionReason] = []
        let holding = !releaseUnobservedPermit && driver.state == .holding && driver.expiry.map({ $0 > now }) == true
        if holding, policy.automaticActive { reasons.append(.automatic) }
        if holding, policy.manualActive { reasons.append(.manual) }
        let transition: WorkSessionPowerTransition? = nil // v4 never preapproves the opposite power source.
        let decision = policy.decision
        var lidPermit: WorkSessionLidPermit?
        if holding, v4LidRequested, rootHandoffPrepared, !decision.powerScopes.isEmpty {
            let candidate = WorkSessionLidPermit(powerScopes: decision.powerScopes,
                batteryPermitID: decision.batteryPermitID, batteryDuration: decision.batteryDuration,
                batteryDeadline: decision.batteryDeadline, disconnectAction: policy.settings.disconnectAction,
                protectiveAction: .sleepIfClosed,
                batteryMaximumDeadline: decision.powerScopes.contains(.battery)
                    ? (decision.batteryPermitID == policy.manualRequestID
                        ? policy.manualBatteryDeadline : policy.automaticBatteryDeadline) : nil,
                extensionID: policy.manualExtensionID,
                batteryTimeLimit: decision.batteryPermitLimit)
            if candidate.isValid(now: now, source: latestPower, batteryLimit: policy.settings.batteryTimeLimit),
               candidate.batteryPermitID.map({ policy.recordBatteryPermitIssued(id: $0, now: now) }) ?? true {
                lidPermit = candidate
            }
        }
        var projectedSettings = policy.settings
        if policy.manualActive { projectedSettings.manualBatteryContinuationMinutes = policy.manualBatteryContinuationMinutes }
        // Preserve an unplug end only for a natural power boundary. Empty work
        // after Off, Stop, lid opt-out, protection or manual cancellation is an
        // ordinary release and must not turn the old permit into a Sleep call.
        // Use the last emitted AC decision: an activation's original filter can
        // survive a later automatic-condition edit while the live scope changes.
        let disconnectEndRequested = reasons.isEmpty && latestPower == .battery
            && policy.settings.enabled && policy.settings.allowClosedLid
            && policy.settings.disconnectAction == .sleepIfClosed
            && policy.markers.permitsAcquisition && currentUser && fullWake == true
            && lastConfirmedWorkLease?.power == .ac
            && ((policy.settings.automaticEnabled && !policy.automaticActive
                 && lastConfirmedWorkLease?.reasons.contains(.automatic) == true)
                || (policy.manualEndReason == .powerDisconnected
                    && lastConfirmedWorkLease?.reasons.contains(.manual) == true))
        var lease = WorkSessionLease(sessionID: sessionID, sequence: workSequence, power: latestPower,
            expiry: reasons.isEmpty ? nil : driver.expiry, reasons: reasons,
            manualDeadline: decision.manualDeadline, settings: projectedSettings, powerTransition: transition,
            continuationToken: policy.hasDirectBatteryIntent ? powerTransitionToken : nil,
            sleepConsumptionID: acknowledgedSleepConsumption?.id, manualStartedOnBattery: policy.manualStartedOnBattery,
            lidPermit: lidPermit, endConsumptionID: endConsumptionID, protectionResumeID: protectionResumeID,
            disconnectEndRequested: disconnectEndRequested, closedLidDisplayMode: policy.settings.closedLidDisplayMode)
        lease.manualRequestID = policy.manualRequestID
        lease.automaticRequestID = policy.automaticRequestID
        lease.automaticBatteryDeadline = policy.automaticBatteryDeadline
        lease.manualPowerCondition = policy.manualPowerCondition
        lease.manualBatteryTimeLimit = policy.manualBatteryTimeLimit
        lease.automaticPowerCondition = policy.automaticPowerCondition
        lease.automaticBatteryTimeLimit = policy.automaticBatteryTimeLimit
        lease.manualExtensionID = policy.manualExtensionID
        lease.manualBatteryMaximumDeadline = policy.manualBatteryDeadline
        lease.extensionRollbackID = extensionRollbackID
        if let pending = pendingExtension, !pending.committed, now < pending.preparation.expiresAt,
           policy.manualRequestID == pending.preparation.requestID { lease.extensionPreparation = pending.preparation }
        lastConfirmedWorkLease = holding ? lease : nil
        return lease
    }

    func update(power: PowerSource, thermal: Int?, fullWake: Bool?, gui: GUISessionObservation, now: Double,
                batteryPercent: Int? = nil, lowPowerWarning: Bool? = false) {
        guard !ended else { return }
        if guiAuthority.login == nil, let login = gui.login, login.uid == getuid(), gui.consoleUID == login.uid {
            guiAuthority.bind(login)
        }
        guiAuthority.observe(gui, now: now)
        let expired = guiAuthority.confirmedUntil.map { now >= $0 } ?? false
        let lost = guiAuthority.status == .revoked || expired
        if lost { invalidatePowerTransition(); policy.loseGUIAuthority() }
        currentUser = guiAuthority.canAcquire
        applyUpdate(power: power, thermal: thermal, fullWake: fullWake, controllingPolicy: !lost, now: now,
                    authority: guiAuthority, batteryPercent: batteryPercent, lowPowerWarning: lowPowerWarning)
    }

    /// Deterministic adapter seam for observation failures and transition tests.
    func update(power: PowerSource, thermal: Int?, fullWake: Bool?, controllingUser: Bool, now: Double,
                batteryPercent: Int? = nil, lowPowerWarning: Bool? = false) {
        // Deterministic policy fixtures explicitly opt out of the native probe. Production
        // refreshes and explicit actions use the GUI observation overload above.
        precondition(guiProbe == nil)
        currentUser = controllingUser
        applyUpdate(power: power, thermal: thermal, fullWake: fullWake, controllingPolicy: controllingUser, now: now,
                    batteryPercent: batteryPercent, lowPowerWarning: lowPowerWarning)
    }
    private func applyUpdate(power: PowerSource, thermal: Int?, fullWake: Bool?, controllingPolicy: Bool,
                             now: Double, authority: GUISessionAuthority? = nil, batteryPercent: Int? = nil,
                             lowPowerWarning: Bool? = false) {
        guard !ended, verifyOwnership() else { return }
        v4Evaluating = true
        defer { v4Evaluating = false }
        if let pending = pendingExtension, now >= pending.preparation.expiresAt
            || policy.manualRequestID != pending.preparation.requestID
            || now >= pending.preparation.currentDeadline {
            cancelManualExtension(now: now)
        }
        if v4LastKnownPower == .ac && power == .battery { v4PowerGeneration &+= 1 }
        if power != .unknown { v4LastKnownPower = power }
        if !controllingPolicy { invalidatePowerTransition() }
        latestPower = power; latestThermal = thermal; latestBatteryPercent = batteryPercent; self.fullWake = fullWake
        latestLowPowerWarning = lowPowerWarning
        let presetIdle = V4RuleEngine.activePreset(policy.settings.v4)?.options.releaseDisplayAfterIdle
        let manualIdle = manualOptions?.releaseDisplayAfterIdle
        if (policy.automaticActive && presetIdle != nil) || (policy.manualActive && manualIdle != nil) {
            if let seconds = idleSecondsProbe(), seconds.isFinite, seconds >= 0 {
                displayIdleObservation = (seconds, now + 15)
            } else { displayIdleObservation = nil }
        } else { displayIdleObservation = nil }
        policy.setDisplayIdleObservation(seconds: displayIdleObservation?.seconds, validUntil: displayIdleObservation?.validUntil)
        updateV4AutomaticGate(now: now)
        let hadDirectBatteryIntent = policy.hasDirectBatteryIntent
        policy.evaluate(power: power, thermal: thermal, fullWake: fullWake, controllingUser: controllingPolicy,
                        now: now, batteryPercent: batteryPercent, lowPowerWarning: lowPowerWarning, lowPowerMode: latestLowPowerMode)
        v4WorkEvents.reconcile(context: v4Context(now: now), now: now)
        if hadDirectBatteryIntent, !policy.hasDirectBatteryIntent { invalidatePowerTransition() }
        if let receipt = pendingPowerTransition {
            if !receipt.isValidObservation(now: now) || receipt.decision.token != powerTransitionToken || !controllingPolicy {
                pendingPowerTransition = nil
            } else if currentUser, fullWake == true, power != .unknown, policy.settings.blockReason == nil,
                      latestThermal.map({ (0..<2).contains($0) }) == true,
                      receipt.decision.power != .battery || SafetyPolicy.canStartHold(batteryPercent: latestBatteryPercent, user: policy.settings.limits) {
                let changed = policy.acceptPowerTransition(receipt.decision, now: now, observedAt: receipt.observedAt)
                invalidatePowerTransition()
                if changed {
                    policy.evaluate(power: power, thermal: thermal, fullWake: fullWake, controllingUser: controllingPolicy,
                                    now: now, batteryPercent: batteryPercent, lowPowerWarning: lowPowerWarning)
                }
            }
        }
        let wallNow = wallClock()
        let projectedAutomaticPause = policy.automaticPauseDeadline.map { wallNow.addingTimeInterval(max(0, $0 - now)) }
        if reportedAutomaticPauseDeadline != policy.automaticPauseDeadline
            || projectedAutomaticPause.map({ abs(automaticPauseWallDeadline?.timeIntervalSince($0) ?? .infinity) > 1 }) == true {
            reportedAutomaticPauseDeadline = policy.automaticPauseDeadline
            automaticPauseWallDeadline = projectedAutomaticPause
        }
        let projectedManualEnd = policy.effectiveManualDeadline.map { wallNow.addingTimeInterval(max(0, $0 - now)) }
        if !policy.manualActive {
            manualWallDeadline = nil; reportedContinuousDeadline = nil
        } else if reportedContinuousDeadline != policy.effectiveManualDeadline
            || projectedManualEnd.map({ abs(manualWallDeadline?.timeIntervalSince($0) ?? .infinity) > 1 }) == true {
            reportedContinuousDeadline = policy.effectiveManualDeadline
            // Decisions use continuous time. Reproject the label after a wall-clock
            // change without moving the actual expiry or resuming expired work.
            manualWallDeadline = projectedManualEnd
        }
        let projectedBatteryEnd = policy.batteryDeadline.map { wallNow.addingTimeInterval(max(0, $0 - now)) }
        if reportedBatteryDeadline != policy.batteryDeadline
            || projectedBatteryEnd.map({ abs(batteryWallDeadline?.timeIntervalSince($0) ?? .infinity) > 1 }) == true {
            if reportedBatteryDeadline == nil, policy.batteryDeadline != nil { batteryWallStart = wallNow }
            else if let previousDeadline = reportedBatteryDeadline, let currentDeadline = policy.batteryDeadline,
                    let previous = batteryWallDeadline, let projected = projectedBatteryEnd {
                // Shift both presentation dates together after a clock correction.
                // The continuous deadline and consumed battery budget stay unchanged.
                let clockCorrection = projected.timeIntervalSince(previous) - (currentDeadline - previousDeadline)
                batteryWallStart = batteryWallStart?.addingTimeInterval(clockCorrection)
            }
            if policy.batteryDeadline == nil { batteryWallStart = nil }
            reportedBatteryDeadline = policy.batteryDeadline
            batteryWallDeadline = projectedBatteryEnd
        }
        // General idle work is process-owned and independent of root readiness.
        // New acquisitions always follow successful durable intent persistence.
        let durable = persist()
        let desired = durable && readable && !endRequested && !awaitingRootSleepConsumption ? policy.expiry : nil
        let expiry = authority.map { $0.expiry(desired, existing: driver.assertionID != nil, now: now) } ?? desired
        if authority?.status == .unavailable || !policy.decision.renewalAllowed {
            // Keep only the original finite timeout. A reduced deadline must
            // release the allocation, never renew/rearm under missing authority.
            if let expiry, let existingExpiry = driver.expiry, expiry >= existingExpiry, existingExpiry > now {
                driver.observe()
            } else { driver.end() }
        } else { driver.apply(expiry: expiry, now: now) }
        // Screen intent never grants work or extends the system executor. Both
        // share a finite policy deadline; unavailable GUI facts cannot renew it.
        let confirmedWork = driver.state == .holding || driver.state == .unverified
        let displayDesired = displayExecutionRequested && confirmedWork
            ? expiry.flatMap { desired in driver.confirmedExpiry.map { min(desired, $0) } } : nil
        let displayExpiry = authority.map { $0.expiry(displayDesired, existing: displayDriver.assertionID != nil, now: now) } ?? displayDesired
        if authority?.status == .unavailable || !policy.decision.renewalAllowed {
            if let displayExpiry, let existing = displayDriver.expiry, displayExpiry >= existing, existing > now {
                displayDriver.observe()
            } else { displayDriver.end() }
        } else if driver.state == .unverified, let displayExpiry, let existing = displayDriver.expiry,
                  displayExpiry >= existing, existing > now {
            displayDriver.observe()
        } else if driver.state == .unverified {
            // A missing system observation does not authorize a new screen request.
            displayDriver.apply(expiry: nil, now: now)
        } else { displayDriver.apply(expiry: displayExpiry, now: now) }
        switch driver.state {
        case .failed(let code): failure = L("Work request could not be confirmed (\(code)).", "작업 유지 요청을 확인하지 못했습니다(\(code)).")
        case .unverified: failure = L("Work request confirmation unavailable.", "작업 유지 요청 확인이 필요합니다.")
        default: if readable { failure = nil }
        }
        scheduleNextObservation(now: now)
        publish()
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard verifyOwnership(), readable, !ended else { return false }
        invalidatePowerTransition(preservingDirectBatteryIntent: enabled)
        checkInputs(now: continuousClock(), explicit: enabled)
        guard !enabled || !ownReleasePending else { return false }
        if enabled { endRequested = false }
        let accepted: Bool
        if enabled {
            accepted = currentUser && fullWake == true && policy.resume(thermal: latestThermal)
            if accepted { protectionResumeID = rootProtectionLatchID }
        }
        else { policy.setEnabled(false); accepted = true }
        explicitlyActivated = enabled && policy.settings.enabled && policy.settings.blockReason == nil
        reevaluate()
        // A saved Use choice remains on while protection is latched. It cannot
        // stand in for acknowledgement that an explicit resume was permitted.
        return readable && accepted && policy.settings.enabled == enabled && (!enabled || policy.markers.permitsAcquisition)
    }
    func setAutomatic(_ enabled: Bool) {
        guard verifyOwnership(), readable, !ended else { return }
        invalidatePowerTransition(preservingDirectBatteryIntent: true)
        checkInputs(now: continuousClock(), explicit: enabled)
        guard !enabled || !ownReleasePending else { return }
        if enabled { explicitlyActivated = true }
        policy.setAutomatic(enabled); reevaluate()
    }
    /// Persist the independent pause before releasing its automatic reason. The
    /// shared manual assertion, original timer and captured battery scope survive.
    @discardableResult
    func pauseAutomatic(for duration: TimeInterval?, now suppliedNow: Double? = nil) -> Bool {
        guard verifyOwnership(), readable, !ended, !endRequested else { return false }
        let now = suppliedNow ?? continuousClock()
        let original = policy
        guard policy.pauseAutomatic(for: duration, now: now) else { return false }
        guard persist() else { policy = original; reevaluate(now: now); return false }
        invalidatePowerTransition(preservingDirectBatteryIntent: true)
        reevaluate(now: now)
        return readable && policy.automaticPauseActive
    }
    @discardableResult
    func resumeAutomatic(now suppliedNow: Double? = nil) -> Bool {
        guard verifyOwnership(), readable, !ended, !endRequested, !ownReleasePending else { return false }
        let now = suppliedNow ?? continuousClock()
        guard now.isFinite, now >= 0, policy.lastEvaluation.map({ now >= $0 }) ?? true else { return false }
        checkInputs(now: now, explicit: true)
        guard policy.automaticPauseActive else { return true }
        let original = policy
        policy.resumeAutomatic()
        guard persist() else { policy = original; reevaluate(now: now); return false }
        invalidatePowerTransition(preservingDirectBatteryIntent: true)
        reevaluate(now: now)
        return readable && !policy.automaticPauseActive
    }
    func setLimits(_ limits: UserLimits) {
        guard verifyOwnership(), readable, !ended, !endRequested, policy.setLimits(limits.isDefault ? nil : limits) else { return }
        invalidatePowerTransition(preservingDirectBatteryIntent: true)
        // Re-evaluate the current request against the new reserve and consumed time;
        // changing the displayed limit must never reset a running battery budget.
        checkInputs(now: continuousClock())
        reevaluate()
    }
    func setPowerCondition(_ condition: PowerCondition) {
        guard verifyOwnership(), readable, !ended, !endRequested else { return }
        invalidatePowerTransition(preservingDirectBatteryIntent: true)
        policy.setPowerCondition(condition); reevaluate()
    }
    func setAutomaticMinutes(_ minutes: Int) {
        guard verifyOwnership(), readable, !ended, !endRequested, policy.setAutomaticMinutes(minutes) else { return }
        invalidatePowerTransition(preservingDirectBatteryIntent: true)
        reevaluate()
    }
    @discardableResult
    func startBatteryHold(minutes: Int, now: Double = ContinuousTime.now) -> Bool {
        guard (1...120).contains(minutes) else { return false }
        return start(duration: Double(minutes) * 60, now: now)
    }
    func cancelBatteryHold() { guard verifyOwnership() else { return }; invalidatePowerTransition(); policy.cancelBatteryHold(); reevaluate() }
    func extendBatteryHold(minutes: Int, now: Double = ContinuousTime.now) {
        // v3 has no live extension command.
    }
    @discardableResult
    func start(duration: TimeInterval?, now: Double = ContinuousTime.now) -> Bool {
        guard verifyOwnership(), !ended else { return false }
        checkInputs(now: now, explicit: true)
        guard readable, !awaitingRootSleepConsumption, !ownReleasePending, currentUser, fullWake == true, latestThermal.map({ (0..<2).contains($0) }) == true,
              policy.start(duration: duration, now: now) else { return false }
        manualOptions = policy.settings.v4.nextManualOptions
        extensionRollbackID = nil
        invalidatePowerTransition(preservingDirectBatteryIntent: true)
        explicitlyActivated = true
        endRequested = false
        reevaluate(now: now)
        guard driver.state == .holding && manualDisplayConfirmed else {
            policy.endManual(); reevaluate(now: now)
            return false
        }
        return true
    }
    func endManual() { guard verifyOwnership() else { return }; invalidatePowerTransition(preservingDirectBatteryIntent: true); policy.resolveLegacyConfiguration(); policy.endManual(); manualWallDeadline = nil; reevaluate() }
    @discardableResult
    func setManualBatteryContinuationMinutes(_ minutes: Int?, now: Double = ContinuousTime.now) -> Bool {
        guard verifyOwnership(), readable, !ended, !endRequested else { return false }
        checkInputs(now: now)
        guard policy.setManualBatteryContinuationMinutes(minutes, now: now) else { return false }
        invalidatePowerTransition(preservingDirectBatteryIntent: true)
        reevaluate(now: now)
        return policy.settings.manualBatteryContinuationMinutes == minutes
    }
    @discardableResult
    func selectManualDuration(_ duration: TimeInterval?) -> Bool {
        guard verifyOwnership(), readable, !ended, policy.selectManualDuration(duration) else { return false }
        let saved = persist(); publish(); return saved
    }
    func setAllowClosedLid(_ allowed: Bool) {
        guard verifyOwnership(), readable, !ended else { return }
        policy.setAllowClosedLid(allowed); reevaluate()
    }
    /// Explicit exit from preparation preserves automatic choices, stop markers
    /// and live request identities. Persist before releasing the lid permission.
    @discardableResult
    func disableClosedLidForGeneralSetup() -> Bool {
        updatePowerPolicy { $0.setAllowClosedLid(false) }
    }
    func setKeepDisplayAwake(_ enabled: Bool) {
        guard verifyOwnership(), readable, !ended, !endRequested else { return }
        policy.setKeepDisplayAwake(enabled); reevaluate()
    }
    @discardableResult
    func setClosedLidDisplayMode(_ mode: ClosedLidDisplayMode) -> Bool {
        updatePowerPolicy { $0.setClosedLidDisplayMode(mode) }
    }
    /// The model supplies observed lid/helper/topology facts; selection alone
    /// cannot obtain the finite display request used by brightness-zero mode.
    func setClosedLidDisplayContext(lidClosed: Bool?, zeroBrightnessEligible: Bool) {
        guard closedLidObservation != lidClosed || self.zeroBrightnessEligible != zeroBrightnessEligible else { return }
        closedLidObservation = lidClosed
        self.zeroBrightnessEligible = zeroBrightnessEligible
        guard !ended, !endRequested else { displayDriver.end(); return }
        // Binding a view/model can provide display context before the first
        // GUI/power observation. Context is not evidence of authority loss and
        // must not create an ownerEnded marker during session preparation.
        guard policy.lastEvaluation != nil else { return }
        reevaluate()
    }
    var closedLidDisplayAssertionConfirmed: Bool {
        hasConfirmedSessionAuthority && policy.decision.renewalAllowed && rootHandoffPrepared
            && closedLidObservation == true && zeroBrightnessEligible && v4LidRequested
            && policy.settings.closedLidDisplayMode == .zeroBrightness
            && driver.state == .holding && displayDriver.state == .holding
            && displayDriver.confirmedExpiry.map { $0 > continuousClock() } == true
    }
    private var displayRequestError: String? {
        switch displayDriver.state {
        case .failed(let code): L("Display request could not be confirmed (\(code)).", "화면 유지 요청을 확인하지 못했습니다(\(code)).")
        case .unverified: L("Display request confirmation unavailable.", "화면 유지 요청 확인이 필요합니다.")
        default: nil
        }
    }
    func setLockOnClose(_ enabled: Bool) {
        guard verifyOwnership(), readable, !ended else { return }
        policy.setLockOnClose(enabled); reevaluate()
    }
    func setDisconnectAction(_ action: WorkSessionEndAction) {
        guard verifyOwnership(), readable, !ended else { return }
        policy.setDisconnectAction(action); reevaluate()
    }
    @discardableResult
    func setDisconnectPolicy(_ value: WorkSessionDisconnectPolicy) -> Bool {
        updatePowerPolicy { $0.setDisconnectPolicy(value) }
    }
    @discardableResult
    func setManualPowerCondition(_ value: PowerCondition) -> Bool {
        updatePowerPolicy { $0.setManualPowerCondition(value) }
    }
    @discardableResult
    func setBatteryTimeLimit(_ value: WorkSessionBatteryLimit) -> Bool {
        updatePowerPolicy { $0.setBatteryTimeLimit(value) }
    }
    @discardableResult
    func setAutomaticallyResumeAfterProtection(_ value: Bool) -> Bool {
        updatePowerPolicy { $0.setAutomaticallyResumeAfterProtection(value) }
    }
    @discardableResult
    func setStopOnSeriousThermal(_ value: Bool) -> Bool {
        updatePowerPolicy { $0.setStopOnSeriousThermal(value) }
    }
    @discardableResult
    func setStartAutomaticOnBatteryDisconnect(_ value: Bool) -> Bool {
        updatePowerPolicy { $0.setStartAutomaticOnBatteryDisconnect(value) }
    }
    private func updatePowerPolicy(_ change: (inout IdleSessionPolicy) -> Void) -> Bool {
        guard verifyOwnership(), readable, !ended, !endRequested else { return false }
        let original = policy
        change(&policy)
        guard policy.settings.isSupported, persist() else {
            policy = original; reevaluate(); return false
        }
        invalidatePowerTransition(preservingDirectBatteryIntent: true)
        reevaluate()
        return true
    }
    /// Save the explicit intent before either executor is asked to sleep.
    /// Wake, refresh and app relaunch alone never clear this durable stop reason.
    @discardableResult
    func pauseForUserSleep(now: Double = ContinuousTime.now) -> Bool {
        guard verifyOwnership(), readable, !ended, now.isFinite, now >= 0,
              policy.lastEvaluation.map({ now >= $0 }) ?? true else { return false }
        invalidatePowerTransition(); policy.pauseForUserSleep(now: now)
        let saved = persist()
        manualWallDeadline = nil; driver.end(); displayDriver.end(); lastConfirmedWorkLease = nil
        publish()
        return saved && driver.assertionID == nil && displayDriver.assertionID == nil
    }
    func stopCurrent() { guard verifyOwnership() else { return }; invalidatePowerTransition(); policy.resolveLegacyConfiguration(); policy.stopCurrent(); manualWallDeadline = nil; reevaluate() }
    @discardableResult
    func extend(duration: TimeInterval, now: Double = ContinuousTime.now) -> Bool {
        guard verifyOwnership(), readable, !ended, !endRequested, pendingExtension == nil else { return false }
        checkInputs(now: now, explicit: true)
        let original = policy
        guard hasConfirmedSessionAuthority, policy.extend(duration: duration, now: now), let id = policy.manualExtensionID else { return false }
        reevaluate(now: now)
        guard policy.manualActive && driver.state == .holding && manualDisplayConfirmed else {
            _ = policy.restoreManualRevision(from: original, expectedExtensionID: id, now: now)
            reevaluate(now: now); return false
        }
        return true
    }
    @discardableResult
    func rescheduleManual(duration: TimeInterval, now: Double = ContinuousTime.now) -> Bool {
        false
    }
    @discardableResult
    func end() -> Bool {
        guard !ended else { return true }
        v4ConditionSource.stop()
        invalidatePowerTransition()
        endRequested = true
        policy.endTemporarySession(); manualWallDeadline = nil
        driver.end(); displayDriver.end()
        guard driver.assertionID == nil && displayDriver.assertionID == nil else {
            failure = L("A work or display request has not been released. Try quitting again.", "작업 또는 화면 유지 요청 해제를 확인하지 못했습니다. 종료를 다시 시도해 주세요.")
            publish(); return false
        }
        ended = true
        if let powerSourceObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceObserver, .commonModes)
            CFRunLoopSourceInvalidate(powerSourceObserver)
        }
        powerSourceObserver = nil
        powerSourceContext = nil
        timer?.invalidate(); timer = nil
        for token in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        observers = []
        persist(); publish()
        return true
    }
    /// Explicit acquisition/renewal must use current power, thermal, wake and GUI facts,
    /// rather than the previous three-second polling result. Nil observations stay nil.
    private func checkInputs(now: Double, explicit: Bool = false) {
        guard !ended, verifyOwnership(), let guiProbe else { return }
        let environment = environmentProbe?() ?? UserSessionEnvironment(power: latestPower, thermal: latestThermal,
            fullWake: fullWake, batteryPercent: latestBatteryPercent)
        latestLowPowerMode = environment.lowPowerMode
        let observation = guiProbe()
        if explicit, let login = observation.login, login.uid == getuid(), observation.consoleUID == login.uid {
            guiAuthority.bind(login)
        }
        update(power: environment.power, thermal: environment.thermal, fullWake: environment.fullWake,
               gui: observation, now: now, batteryPercent: environment.batteryPercent,
               lowPowerWarning: environment.lowPowerWarning)
    }
    private func invalidatePowerTransition(preservingDirectBatteryIntent: Bool = false) {
        // An unrelated edit changes current reasons through the next finite lease;
        // it must not erase an already observed start of this same reservation.
        // Explicit continuation cancellation/replacement and whole-session stops
        // always rotate the token, including when a historical reply is in flight.
        if preservingDirectBatteryIntent, policy.hasDirectBatteryIntent { return }
        pendingPowerTransition = nil; powerTransitionToken = UUID()
    }
    private func reevaluate(now suppliedNow: Double? = nil) {
        // Deterministic fixtures advance their continuous observation clock
        // explicitly. A defaults edit has no independent clock advancement.
        let now = suppliedNow ?? (guiProbe == nil ? policy.lastEvaluation ?? continuousClock() : continuousClock())
        if guiProbe != nil {
            checkInputs(now: now)
        } else {
            update(power: latestPower, thermal: latestThermal, fullWake: fullWake, controllingUser: currentUser,
                   now: now, batteryPercent: latestBatteryPercent, lowPowerWarning: latestLowPowerWarning)
        }
    }
    /// One one-shot timer for the next product deadline or finite execution
    /// renewal. Power, thermal and GUI changes arrive through native observers.
    private func scheduleNextObservation(now: Double) {
        guard guiProbe != nil, !ended else { return }
        timer?.invalidate(); timer = nil
        var boundaries = [policy.effectiveManualDeadline, policy.batteryDeadline, policy.automaticPauseDeadline].compactMap { $0 }
        if let pending = pendingExtension { boundaries.append(pending.preparation.expiresAt); boundaries.append(pending.preparation.currentDeadline) }
        if policy.automaticActive || policy.manualActive || policy.settings.automaticEnabled { boundaries.append(now + 5) }
        for expiry in [driver.expiry, displayDriver.expiry].compactMap({ $0 }) {
            boundaries.append(min(now + IdleSessionPolicy.healthTTL / 2, expiry - 1))
        }
        guard let next = boundaries.filter({ $0 > now }).min() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(0.01, next - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timer = nil; self?.refresh() }
        }
    }
    @discardableResult
    private func persist() -> Bool {
        guard ownershipProbe(), readable else { return false }
        guard policy.settings != savedSettings else { return true }
        guard persistenceProbe(), let data = try? JSONEncoder().encode(policy.settings) else {
            persistenceFailed(); return false
        }
        if let original = migrationOriginal {
            var key = Self.preferenceKey + ".migration.v\(migrationSourceVersion).backup"
            if let previous = defaults.data(forKey: key), previous != original {
                key += "." + UUID().uuidString
            }
            defaults.set(original, forKey: key)
            guard defaults.synchronize(), defaults.data(forKey: key) == original else {
                persistenceFailed(); return false
            }
            migrationOriginal = nil
        }
        if let previous = defaults.data(forKey: Self.preferenceKey) {
            defaults.set(previous, forKey: Self.preferenceKey + ".backup")
        }
        defaults.set(data, forKey: Self.preferenceKey)
        guard defaults.synchronize(), defaults.data(forKey: Self.preferenceKey) == data else {
            persistenceFailed(); return false
        }
        savedSettings = policy.settings
        // Manual execution deadlines and pending jobs are never saved. A saved
        // automatic pause deadline is restrictive intent, not execution authority.
        return true
    }
    private func persistenceFailed() {
        readable = false
        failure = L("Session intent could not be saved; new work is paused.", "세션 의도를 저장하지 못해 새 작업 유지를 중지했습니다.")
    }
    private func verifyOwnership() -> Bool {
        guard ownershipProbe() else {
            invalidatePowerTransition()
            policy.endTemporarySession(); manualWallDeadline = nil
            driver.end(); displayDriver.end(); currentUser = false
            failure = AppCoordinatorFailure.unsafeLocation.localizedDescription
            publish()
            return false
        }
        return true
    }
    func setActivityRecording(_ on: Bool, minutes: Int = 15) {
        // Every GUI selection supersedes an older CLI's eventual finish request.
        commandRecordingID = nil
        if !on { writeActivity(activity.setRecording(false)); return }
        guard ownershipProbe(), !ended, !endRequested else { return }
        writeActivity(activity.observe(status))
        writeActivity(activity.setRecording(on, minutes: minutes))
        if on { writeActivity(activity.observe(status)) }
    }

    func applyActivityRecording(_ action: UserSessionRecordingAction, requestID: UUID) -> Bool {
        switch action {
        case .start(let minutes):
            guard (1...240).contains(minutes), ownershipProbe(), !ended, !endRequested else { return false }
            if activity.isRecording() {
                // Join an existing bounded recording without replacing its deadline.
                // No waiting CLI may end a recording now shared with another caller.
                commandRecordingID = nil
                return true
            }
            setActivityRecording(true, minutes: minutes)
            commandRecordingID = requestID
            return activity.isRecording()
        case .finish(let recordingID):
            guard commandRecordingID == recordingID else { return true }
            setActivityRecording(false)
            return true
        }
    }

    @discardableResult
    func markActivity() -> Bool {
        guard ownershipProbe(), !ended, !endRequested else { return false }
        writeActivity(activity.observe(status))
        if let marker = activity.mark() { writeActivity([marker]) }
        return true
    }

    private func writeActivity(_ entries: [UserSessionActivity.Entry]) {
        guard !entries.isEmpty else { return }
        for entry in entries { log.notice("\(entry.line, privacy: .public)") }
        if activityPersistenceEnabled, ownershipProbe(), entries.contains(where: { $0.kind != .detail }) {
            do {
                let data = try activity.archivedDecisions()
                defaults.set(data, forKey: "v4DecisionHistory")
                if !defaults.synchronize() || defaults.data(forKey: "v4DecisionHistory") != data {
                    activityStorageError = L("Some decision history was not saved.", "결정 기록 일부를 저장하지 못했습니다.")
                }
            } catch { activityStorageError = L("Some decision history was not saved.", "결정 기록 일부를 저장하지 못했습니다.") }
        }
        onActivityChange?()
    }

    private func publish() {
        let value = status
        if ended { writeActivity(activity.setRecording(false)) }
        writeActivity(activity.observe(value))
        onChange?(value)
    }
}

extension UserSessionController {
    var v4Scope: V4Scope {
        V4Scope(bootID: boot, ownerID: sessionID.uuidString, powerGeneration: v4PowerGeneration)
    }
    var v4Settings: V4Settings { policy.settings.v4 }
    var v4DisplayRequested: Bool {
        policy.decision.displayRequired
    }
    private var displayExecutionRequested: Bool {
        if closedLidObservation == true {
            return policy.settings.closedLidDisplayMode == .zeroBrightness && zeroBrightnessEligible
                && v4LidRequested && rootHandoffPrepared
        }
        return v4DisplayRequested
    }
    var manualDisplayConfirmed: Bool {
        let required = closedLidObservation == true ? displayExecutionRequested : policy.manualDisplayRequired
        return !required || displayDriver.state == .holding
    }
    var v4LidRequested: Bool {
        policy.decision.closedLidRequired
    }
    func v4Context(now: Double, lidClosed: Bool? = nil, isMacBook: Bool = true) -> V4ExecutionContext {
        V4ExecutionContext(scope: v4Scope, power: V4Power(rawValue: latestPower.rawValue) ?? .unknown,
            validUntil: (policy.lastEvaluation ?? -30) + 15, automaticEnabled: settings.automaticEnabled, paused: !settings.enabled,
            protectionActive: settings.blockReason != nil, ownerValid: currentUser && fullWake == true,
            isMacBook: isMacBook, lidClosed: lidClosed, allowDisplay: settings.keepDisplayAwake,
            allowClosedLid: settings.allowClosedLid, automaticPowerCondition: policy.automaticEvaluationCondition)
    }
    var v4RehearsalObservations: [V4Observation] {
        v4Observations + V4RuleEngine.requiredConditions(settings: settings.v4, automaticEnabled: settings.automaticEnabled)
            .filter { $0.kind == .taskEvent }.map { v4WorkEvents.observation(for: $0, context: v4Context(now: ContinuousTime.now), now: ContinuousTime.now) }
    }
    var v4Capabilities: [V4Capability] {
        let experimental: Set<V4ConditionKind> = [.cpuLoad, .networkThroughput]
        let unavailable: Set<V4ConditionKind> = [.download, .microphoneInput, .cameraUsage, .audioPlayback, .unsupported]
        return V4ConditionKind.allCases.map {
            V4Capability(kind: $0, status: unavailable.contains($0) ? .unsupported : experimental.contains($0) ? .experimental : .supported)
        }
    }
    /// User-requested import/rollback review only. Inactive providers never query authorization on policy ticks.
    func v4ReviewCapabilities(for settings: V4Settings) -> [V4Capability] {
        let selected = Set(settings.presets.flatMap(\.groups).flatMap(\.conditions).map(\.kind))
        return v4Capabilities.map { capability in
            var result = capability
            if selected.contains(result.kind) { result.permissionGranted = V4NativeObservations.permissionKnownGranted(for: result.kind) }
            return result
        }
    }
    private func updateV4AutomaticGate(now: Double) {
        v4ConditionSource.configure(settings: policy.settings.v4,
            enabled: policy.settings.automaticEnabled && currentUser && fullWake == true
                && policy.settings.enabled && policy.settings.blockReason == nil
                && (policy.automaticEvaluationCondition == .any || policy.automaticEvaluationCondition.rawValue == latestPower.rawValue),
            scope: v4Scope, observing: observing)
        let capabilities = v4Capabilities
        var context = v4Context(now: now); context.validUntil = now + 15 // This call follows fresh common observations.
        v4WorkEvents.reconcile(context: context, now: now)
        let taskObservations = V4RuleEngine.requiredConditions(settings: policy.settings.v4, automaticEnabled: policy.settings.automaticEnabled)
            .filter { $0.kind == .taskEvent }.map { v4WorkEvents.observation(for: $0, context: context, now: now) }
        let result = V4RuleEngine.evaluate(settings: policy.settings.v4, context: context,
            observations: v4Observations + taskObservations, capabilities: capabilities, now: now, wallDate: wallClock(), calendar: .current)
        v4RuleEvaluation = result
        policy.setV4AutomaticGate(result.gate, now: now)
    }
    @discardableResult
    func setV4Settings(_ next: V4Settings, presetDefaults: V4Preset? = nil) -> Bool {
        guard verifyOwnership(), readable, !ended, !endRequested else { return false }
        let original = policy
        guard policy.setV4Settings(next) else { return false }
        if let presetDefaults, !policy.selectManualDuration(presetDefaults.nextManualMinutes.map { Double($0) * 60 }) {
            policy = original; return false
        }
        guard persist() else { policy = original; reevaluate(); return false }
        reevaluate(); return true
    }
    @discardableResult
    func applyInitialChoices(automatic: Bool, allowClosedLid: Bool) -> Bool {
        guard verifyOwnership(), readable, !ended, !endRequested else { return false }
        let original = policy
        guard policy.applyUserChoices(automatic: automatic, allowClosedLid: allowClosedLid) else { return false }
        guard persist() else { policy = original; reevaluate(); return false }
        reevaluate()
        return true
    }
    var manualRequestID: UUID? { policy.manualRequestID }
    var manualExtensionID: UUID? { policy.manualExtensionID }
    var v4ManualSnapshot: V4ManualSnapshot? {
        guard let id = policy.manualRequestID, let start = policy.manualStart else { return nil }
        return V4ManualSnapshot(requestID: id, revisionID: policy.manualExtensionID ?? id,
            ownerID: sessionID.uuidString, startedAt: start, deadline: policy.effectiveManualDeadline,
            batteryStartedAt: policy.manualBatteryStartedAt, confirmed: status.holding && !manualExtensionPending,
            canExtend15: canExtendManual(by: 15), canExtend30: canExtendManual(by: 30),
            options: manualOptions ?? .init(), batteryTimeLimit: policy.manualBatteryTimeLimit,
            batteryLimitEnforced: latestPower != .ac)
    }
    func canExtendManual(by minutes: Int, now: Double = ContinuousTime.now) -> Bool {
        hasConfirmedSessionAuthority && pendingExtension == nil && [15, 30].contains(minutes)
            && policy.canExtend(duration: Double(minutes) * 60, now: now)
    }
    var manualExtensionPrepared: Bool { pendingExtension?.prepared == true }
    var manualExtensionPending: Bool { pendingExtension != nil }
    var pendingManualExtensionID: UUID? { pendingExtension?.preparation.id }
    @discardableResult
    func prepareManualExtension(minutes: Int, now: Double = ContinuousTime.now) -> Bool {
        guard canExtendManual(by: minutes, now: now) else { return false }
        checkInputs(now: now, explicit: true)
        var proposed = policy
        guard let request = policy.manualRequestID, let deadline = policy.effectiveManualDeadline,
              proposed.extend(duration: Double(minutes) * 60, now: now), let id = proposed.manualExtensionID,
              let proposedDeadline = proposed.effectiveManualDeadline else { return false }
        let preparation = WorkSessionExtensionPreparation(id: id, requestID: request,
            currentDeadline: deadline, proposedDeadline: proposedDeadline, expiresAt: min(now + 5, deadline))
        pendingExtension = PendingExtension(original: policy, proposed: proposed, preparation: preparation)
        publish()
        return true
    }
    @discardableResult
    func commitManualExtension(now: Double = ContinuousTime.now, requiresHelper: Bool) -> Bool {
        guard let pending = pendingExtension, !requiresHelper || pending.prepared,
              now < pending.preparation.expiresAt,
              policy.manualRequestID == pending.preparation.requestID,
              policy.effectiveManualDeadline == pending.preparation.currentDeadline,
              policy.commitPreparedManualExtension(pending.proposed, now: now) else { return false }
        pendingExtension?.committed = true
        reevaluate(now: now)
        return driver.state == .holding && manualDisplayConfirmed
    }
    func completeManualExtension() {
        pendingExtension = nil
        publish()
    }
    func cancelManualExtension(now: Double = ContinuousTime.now) {
        guard let pending = pendingExtension else { return }
        pendingExtension = nil
        if pending.committed {
            if policy.restoreManualRevision(from: pending.original, expectedExtensionID: pending.preparation.id, now: now) {
                extensionRollbackID = pending.preparation.id
            } else if policy.manualRequestID == pending.preparation.requestID,
                      policy.manualExtensionID == pending.preparation.id {
                // A rejected tentative extension must never outlive its original deadline.
                policy.endManual(reason: now >= pending.preparation.currentDeadline ? .time : .cancelled)
            }
        }
    }
    func acknowledgeExtensionRollback(_ id: UUID?) {
        if let id, id == extensionRollbackID { extensionRollbackID = nil }
    }
    func applyWorkEvent(_ event: V4WorkEvent, now: Double = ContinuousTime.now) -> V4WorkEventResult {
        checkInputs(now: now)
        let result = v4WorkEvents.apply(event, context: v4Context(now: now), now: now)
        reevaluate(now: now)
        return result
    }
    @discardableResult
    func applyConfiguration(_ document: V4SettingsDocument) -> Bool {
        guard verifyOwnership(), readable, !ended, !endRequested,
              V4SettingsTransfer.validate(document).isEmpty, persistenceProbe() else { return false }
        let original = policy
        var next = policy
        guard next.setV4Settings(document.settings),
              next.applyUserChoices(automatic: document.preferences.automaticEnabled, allowClosedLid: document.preferences.allowClosedLid),
              next.setLimits(UserLimits(batteryFloor: document.preferences.batteryLowerBound)),
              next.selectManualDuration(document.preferences.nextManualMinutes.map { Double($0) * 60 }) else { return false }
        next.setKeepDisplayAwake(document.preferences.allowDisplay)
        next.setDisconnectAction(document.preferences.disconnectAction)
        policy = next
        guard persist() else { policy = original; return false }
        reevaluate()
        return true
    }
}
