import Foundation

/// User choices and durable stop markers share one atomic preference record.
/// Legacy budget fields are decode-only compatibility; no v3 request uses them.
public struct IdleSessionSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 8
    public var version = Self.currentVersion
    public var enabled = true
    public var automaticEnabled = false
    public var automaticSuppressed = false
    public var blockReason: String?
    public var limits: UserLimits?
    public var manualBatteryBudget: ProtectionState?
    public var manualBatteryContinuationMinutes: Int?
    public var powerCondition: PowerCondition?
    public var automaticHoldMinutes: Int?
    public var automaticBatteryBudget: ProtectionState?
    public var batterySuppressed: Bool?
    public var legacyRootConfigurationPending: Bool?
    public var runtimeMarkers: RuntimeMarkers?
    public var allowClosedLid = false
    public var lockOnClose = false
    /// Optional idle display prevention shares the work session's finite lifetime.
    public var keepDisplayAwake = false
    /// Internal-panel handling is independent from keeping an open display awake.
    /// Missing preferences preserve the previous helper display-off behavior.
    public var closedLidDisplayMode: ClosedLidDisplayMode = .off
    public var v4: V4Settings = .init()
    public var disconnectAction: WorkSessionEndAction = .sleepIfClosed
    public var disconnectPolicy: WorkSessionDisconnectPolicy = .endAll
    /// Nil preserves AC-only semantics of pre-P0 preferences. The legacy
    /// powerCondition field alone is never promoted into new battery authority.
    public var automaticPowerCondition: PowerCondition?
    public var manualPowerCondition: PowerCondition = .any
    public var batteryTimeLimit: WorkSessionBatteryLimit = .twoHours
    public var automaticallyResumeAfterProtection = false
    public var stopOnSeriousThermal = true
    public var startAutomaticOnBatteryDisconnect = false
    /// Nil is an explicit AC unlimited choice. A missing old key defaults to 30m.
    public var lastManualDurationSeconds: Double? = 30 * 60
    /// Old battery/both choices are retained for decoding, never battery authority.
    public var condition: PowerCondition { automaticPowerCondition ?? .ac }
    /// The basic mode is AC-only without rewriting a saved advanced power choice.
    public var effectiveAutomaticCondition: PowerCondition {
        v4.usesAdvancedAutomaticConditions ? condition : .ac
    }
    public var automaticMinutes: Int { min(120, max(1, automaticHoldMinutes ?? 60)) }
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case version, enabled, automaticEnabled, automaticSuppressed, blockReason, limits,
             manualBatteryBudget, manualBatteryContinuationMinutes, powerCondition,
             automaticHoldMinutes, automaticBatteryBudget, batterySuppressed,
             legacyRootConfigurationPending, runtimeMarkers, allowClosedLid, lockOnClose,
             disconnectAction, lastManualDurationSeconds, keepDisplayAwake, v4,
             disconnectPolicy, automaticPowerCondition, manualPowerCondition, batteryTimeLimit,
             automaticallyResumeAfterProtection, stopOnSeriousThermal, startAutomaticOnBatteryDisconnect,
             closedLidDisplayMode
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        automaticEnabled = try c.decodeIfPresent(Bool.self, forKey: .automaticEnabled) ?? false
        automaticSuppressed = try c.decodeIfPresent(Bool.self, forKey: .automaticSuppressed) ?? false
        blockReason = try c.decodeIfPresent(String.self, forKey: .blockReason)
        limits = try c.decodeIfPresent(UserLimits.self, forKey: .limits)
        manualBatteryBudget = try c.decodeIfPresent(ProtectionState.self, forKey: .manualBatteryBudget)
        manualBatteryContinuationMinutes = try c.decodeIfPresent(Int.self, forKey: .manualBatteryContinuationMinutes)
        powerCondition = try c.decodeIfPresent(PowerCondition.self, forKey: .powerCondition)
        automaticHoldMinutes = try c.decodeIfPresent(Int.self, forKey: .automaticHoldMinutes)
        automaticBatteryBudget = try c.decodeIfPresent(ProtectionState.self, forKey: .automaticBatteryBudget)
        batterySuppressed = try c.decodeIfPresent(Bool.self, forKey: .batterySuppressed)
        legacyRootConfigurationPending = try c.decodeIfPresent(Bool.self, forKey: .legacyRootConfigurationPending)
        runtimeMarkers = try c.decodeIfPresent(RuntimeMarkers.self, forKey: .runtimeMarkers)
        allowClosedLid = try c.decodeIfPresent(Bool.self, forKey: .allowClosedLid) ?? false
        lockOnClose = try c.decodeIfPresent(Bool.self, forKey: .lockOnClose) ?? false
        keepDisplayAwake = try c.decodeIfPresent(Bool.self, forKey: .keepDisplayAwake) ?? false
        closedLidDisplayMode = try c.decodeIfPresent(ClosedLidDisplayMode.self, forKey: .closedLidDisplayMode) ?? .off
        v4 = try c.decodeIfPresent(V4Settings.self, forKey: .v4) ?? .init()
        disconnectAction = try c.decodeIfPresent(WorkSessionEndAction.self, forKey: .disconnectAction) ?? .sleepIfClosed
        disconnectPolicy = try c.decodeIfPresent(WorkSessionDisconnectPolicy.self, forKey: .disconnectPolicy) ?? .endAll
        automaticPowerCondition = try c.decodeIfPresent(PowerCondition.self, forKey: .automaticPowerCondition)
        manualPowerCondition = try c.decodeIfPresent(PowerCondition.self, forKey: .manualPowerCondition) ?? .any
        batteryTimeLimit = try c.decodeIfPresent(WorkSessionBatteryLimit.self, forKey: .batteryTimeLimit) ?? .twoHours
        automaticallyResumeAfterProtection = try c.decodeIfPresent(Bool.self, forKey: .automaticallyResumeAfterProtection) ?? false
        stopOnSeriousThermal = try c.decodeIfPresent(Bool.self, forKey: .stopOnSeriousThermal) ?? true
        startAutomaticOnBatteryDisconnect = try c.decodeIfPresent(Bool.self, forKey: .startAutomaticOnBatteryDisconnect) ?? false
        if c.contains(.lastManualDurationSeconds) {
            lastManualDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .lastManualDurationSeconds)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(enabled, forKey: .enabled)
        try c.encode(automaticEnabled, forKey: .automaticEnabled); try c.encode(automaticSuppressed, forKey: .automaticSuppressed)
        try c.encodeIfPresent(blockReason, forKey: .blockReason); try c.encodeIfPresent(limits, forKey: .limits)
        try c.encodeIfPresent(manualBatteryBudget, forKey: .manualBatteryBudget)
        try c.encodeIfPresent(manualBatteryContinuationMinutes, forKey: .manualBatteryContinuationMinutes)
        try c.encodeIfPresent(powerCondition, forKey: .powerCondition); try c.encodeIfPresent(automaticHoldMinutes, forKey: .automaticHoldMinutes)
        try c.encodeIfPresent(automaticBatteryBudget, forKey: .automaticBatteryBudget); try c.encodeIfPresent(batterySuppressed, forKey: .batterySuppressed)
        try c.encodeIfPresent(legacyRootConfigurationPending, forKey: .legacyRootConfigurationPending)
        try c.encodeIfPresent(runtimeMarkers, forKey: .runtimeMarkers)
        try c.encode(allowClosedLid, forKey: .allowClosedLid); try c.encode(lockOnClose, forKey: .lockOnClose)
        try c.encode(keepDisplayAwake, forKey: .keepDisplayAwake)
        try c.encode(closedLidDisplayMode, forKey: .closedLidDisplayMode)
        try c.encode(v4, forKey: .v4)
        try c.encode(disconnectAction, forKey: .disconnectAction)
        try c.encode(disconnectPolicy, forKey: .disconnectPolicy)
        try c.encodeIfPresent(automaticPowerCondition, forKey: .automaticPowerCondition)
        try c.encode(manualPowerCondition, forKey: .manualPowerCondition)
        try c.encode(batteryTimeLimit, forKey: .batteryTimeLimit)
        try c.encode(automaticallyResumeAfterProtection, forKey: .automaticallyResumeAfterProtection)
        try c.encode(stopOnSeriousThermal, forKey: .stopOnSeriousThermal)
        try c.encode(startAutomaticOnBatteryDisconnect, forKey: .startAutomaticOnBatteryDisconnect)
        try c.encode(lastManualDurationSeconds, forKey: .lastManualDurationSeconds)
    }
    public var isSupported: Bool {
        version == Self.currentVersion && (blockReason?.utf8.count ?? 0) <= 256
            && v4.version == V4Settings.currentVersion
            && (runtimeMarkers?.isSupported ?? true)
            && limits?.closedLidMaxTemperature == nil && limits?.openLidMaxTemperature == nil
            && (limits?.maxHoldHours.map { $0.isFinite && $0 > 0 } ?? true)
            && (limits?.batteryFloor.map { (0...100).contains($0) } ?? true)
            && (automaticHoldMinutes.map { (1...120).contains($0) } ?? true)
            && ManualSessionPolicy.validContinuationMinutes(manualBatteryContinuationMinutes)
            && (lastManualDurationSeconds.map { $0.isFinite && $0 > 0 && $0 <= ManualSessionPolicy.maximumTimedDuration } ?? true)
    }
    public var migratedToCurrentVersion: Self? {
        if isSupported { return self }
        // Schema 8 adds only a display choice. Do not reapply the pre-P0
        // migration or discard approved schema-7 options and stop markers.
        if version == 7 {
            var next = self; next.version = Self.currentVersion
            return next.isSupported ? next : nil
        }
        guard (1..<Self.currentVersion).contains(version), (blockReason?.utf8.count ?? 0) <= 256,
              manualBatteryContinuationMinutes.map({ (1...240).contains($0) }) ?? true,
              automaticHoldMinutes.map({ (1...240).contains($0) }) ?? true else { return nil }
        var next = self; next.version = Self.currentVersion
        if version < 7, powerCondition == .battery { next.automaticEnabled = false }
        if version < 7 {
            next.automaticPowerCondition = nil; next.disconnectPolicy = .endAll
            next.manualPowerCondition = .any; next.batteryTimeLimit = .twoHours
            next.automaticallyResumeAfterProtection = false; next.stopOnSeriousThermal = true
            next.startAutomaticOnBatteryDisconnect = false
        }
        // Only clear choices survive: neither elapsed budgets nor an active job
        // are interpreted as a v3 execution permission.
        next.manualBatteryBudget = nil; next.automaticBatteryBudget = nil
        next.limits = limits.flatMap { value in value.batteryFloor.map { UserLimits(batteryFloor: $0) } }
        next.manualBatteryContinuationMinutes = nil
        next.automaticHoldMinutes = automaticHoldMinutes.map { min(120, $0) }
        next.legacyRootConfigurationPending = version <= 2
        var markers = runtimeMarkers ?? RuntimeMarkers()
        if !enabled || automaticSuppressed { markers.pauseReason = markers.pauseReason ?? .userStop }
        if !enabled { next.automaticEnabled = false }
        markers.protectionReason = markers.protectionReason ?? blockReason
        if batterySuppressed == true {
            markers.automaticActivation = markers.automaticActivation ?? AutomaticActivationMarker(
                condition: condition, batteryConsumed: true, batteryExpired: true)
        }
        next.runtimeMarkers = markers
        return next.isSupported ? next : nil
    }
}

/// The sole v3 product state machine. Root code only enforces its projected
/// permit; it cannot restart triggers, reinterpret defaults, or mirror budgets.
public struct IdleSessionPolicy: Equatable, Sendable {
    /// Execution lifetime only, retained for the native assertion's finite timeout.
    /// This is not an experimentally qualified lid recovery guarantee.
    public static let healthTTL: TimeInterval = 15
    public static let renewalInterval: TimeInterval = 5
    public static let observationTTL: TimeInterval = 15
    private struct IssuedBatteryPermit: Equatable, Sendable {
        var manualID: UUID?
        var manualIssuedAt: Double?
        var automaticID: UUID?
        var automaticIssuedAt: Double?
    }
    // Match the executor's bounded receipt journal. These bindings are not saved
    // choices or execution grants and never survive an app session restart.
    private static let maximumIssuedBatteryPermits = 128
    private var issuedBatteryPermits: [UUID: IssuedBatteryPermit] = [:]
    public private(set) var settings: IdleSessionSettings
    private var manual: ManualSessionPolicy
    private let boot: String
    private var latestPower = PowerSource.unknown
    private var lastKnownPower = PowerSource.unknown
    private var latestFullWake: Bool?
    private var latestControllingUser = false
    private var latestBatteryPercent: Int?
    private var latestLowPowerWarning: Bool? = false
    private var latestLowPowerMode: Bool? = false
    private var automaticDuration: Double?
    private var automaticStartedAt: Double?
    private var temporaryConsumptionAt: Double?
    private var automaticGate: V4AutomaticGate?
    private var manualDisplayChoice = false
    private var manualLidChoice = false
    private var manualDisplayIdleLimit: Double?
    private var displayIdleSeconds: Double?
    private var displayIdleValidUntil: Double?
    public private(set) var batteryDeadline: Double?
    private var userSleepRequestedAt: Double?
    private var userSleepObserved = false
    private var lastValidExecutionObservation: Double?
    private var recoveryWindow = ProtectionRecoveryWindow()
    private var automaticExecutionID: UUID?
    private var automaticExecutionStartedAt: Double?
    private var automaticNeedsNewExecution = false
    private var gateWasSatisfied: Bool?
    private var pendingConditionActivation = false
    private var disconnectBlocksAutomatic = false
    public private(set) var automaticActive = false
    public private(set) var lastThermal: Int?
    public private(set) var lastEvaluation: Double?
    public private(set) var expiry: Double?
    public private(set) var decision = WorkSessionDecision()
    public var markers: RuntimeMarkers { settings.runtimeMarkers ?? RuntimeMarkers() }
    public var permitsExplicitManualStart: Bool {
        markers.permitsAcquisition || (markers.pauseReason == .ownerEnded && markers.protectionReason == nil)
    }
    public var batteryAllowsWork: Bool {
        (!settings.v4.stopOnLowPowerMode || latestLowPowerMode == false) && (latestPower != .battery || (latestLowPowerWarning == false
            && SafetyPolicy.canStartHold(batteryPercent: latestBatteryPercent, user: settings.limits)
            && (!settings.v4.stopOnLowPowerMode || latestLowPowerMode == false)))
    }
    public var manualStart: Double? { manual.startedAt }
    public var manualRequestID: UUID? { manual.requestID }
    public var automaticRequestID: UUID? { automaticExecutionID }
    public var automaticPauseActive: Bool { markers.automaticPause != nil }
    public var automaticPauseDeadline: Double? {
        guard let pause = markers.automaticPause, boot != "unknown", pause.bootID == boot else { return nil }
        return pause.until
    }
    public var automaticBatteryDeadline: Double? { batteryDeadline }
    public var manualBatteryTimeLimit: WorkSessionBatteryLimit { manual.batteryLimit }
    public var automaticBatteryTimeLimit: WorkSessionBatteryLimit { markers.automaticActivation?.batteryLimit ?? settings.batteryTimeLimit }
    public var manualPowerCondition: PowerCondition { manual.powerCondition }
    public var effectiveAutomaticCondition: PowerCondition { settings.effectiveAutomaticCondition }
    public var automaticPowerCondition: PowerCondition {
        settings.v4.usesAdvancedAutomaticConditions
            ? (markers.automaticActivation?.condition ?? effectiveAutomaticCondition) : .ac
    }
    /// The gate for an existing advanced activation uses its captured range.
    /// Editing the next default cannot disable that activation's providers.
    public var automaticEvaluationCondition: PowerCondition {
        guard settings.v4.usesAdvancedAutomaticConditions,
              let activation = markers.automaticActivation,
              !activation.conditionEnded, !activation.batteryExpired else { return effectiveAutomaticCondition }
        return activation.condition
    }
    public var manualExtensionID: UUID? { manual.extensionID }
    public var manualKeepDisplayAwake: Bool { manual.active && manualDisplayChoice }
    public var manualAllowClosedLid: Bool { manual.active && manualLidChoice }
    public var manualDeadline: Double? { manual.requestedDeadline }
    public var effectiveManualDeadline: Double? { manual.effectiveDeadline }
    public var manualActive: Bool { manual.active }
    public var manualStartedOnBattery: Bool { manual.startedOnBattery }
    public var manualEndReason: ManualSessionEnd? { manual.endReason }
    public var manualBatteryContinuationMinutes: Int? { manual.activeBatteryContinuationMinutes }
    public var manualBatteryDeadline: Double? { manual.batteryDeadline }
    public var manualBatteryStartedAt: Double? { manual.batteryStartedAt }
    public var manualBatteryRemaining: Double { manual.batteryRemaining(now: lastEvaluation ?? 0) }
    public var manualReschedulingLimit: Double? { nil }
    public var pendingBatteryMinutes: Int? {
        manual.active && !manual.startedOnBattery && manual.batteryDeadline == nil ? manual.activeBatteryContinuationMinutes : nil
    }
    public var hasDirectBatteryIntent: Bool { manual.allowsBattery }
    /// Live request identity survives an unavailable snapshot; it grants no work.
    public var currentBatteryPermitID: UUID? {
        if manual.allowsBattery { return manual.requestID }
        guard settings.automaticEnabled, automaticPowerCondition.includesBattery,
              markers.automaticActivation?.batteryExpired != true else { return nil }
        return automaticExecutionID
    }
    public var batteryRemaining: Double {
        guard boot != "unknown" else { return 0 }
        if let deadline = batteryDeadline { return max(0, deadline - (lastEvaluation ?? 0)) }
        return markers.automaticActivation?.batteryConsumed == true ? 0 : Double(settings.automaticMinutes * 60)
    }
    public init(settings: IdleSessionSettings = .init(), boot: String = ContinuousTime.bootID) {
        var next = settings.migratedToCurrentVersion ?? settings
        var marks = next.runtimeMarkers ?? RuntimeMarkers()
        if !next.enabled || (next.runtimeMarkers == nil && next.automaticSuppressed) {
            marks.pauseReason = marks.pauseReason ?? .userStop
        }
        marks.protectionReason = marks.protectionReason ?? next.blockReason
        if next.batterySuppressed == true, marks.automaticActivation == nil {
            marks.automaticActivation = AutomaticActivationMarker(condition: next.condition, batteryConsumed: true, batteryExpired: true)
        }
        next.runtimeMarkers = marks
        if next.automaticPowerCondition == nil, next.powerCondition == .battery {
            // A legacy battery-only preference was not an AC permission. Only
            // a new explicit power/automatic choice may replace that intent.
            next.automaticEnabled = false
        }
        next.manualBatteryBudget = nil; next.automaticBatteryBudget = nil
        if next.isSupported { next.limits = next.limits.flatMap { $0.batteryFloor.map { UserLimits(batteryFloor: $0) } } }
        self.settings = next; self.boot = boot
        manual = ManualSessionPolicy(batteryContinuationMinutes: next.manualBatteryContinuationMinutes, boot: boot)
        synchronizeCompatibilityMarkers()
    }
    @discardableResult
    public mutating func start(duration: TimeInterval?, now: Double) -> Bool {
        guard canStart(now: now), manual.start(duration: duration, power: latestPower, now: now,
            disconnectPolicy: settings.disconnectPolicy, powerCondition: settings.manualPowerCondition,
            batteryLimit: settings.batteryTimeLimit) else { return false }
        manualDisplayChoice = settings.v4.nextManualOptions.display; manualLidChoice = settings.v4.nextManualOptions.closedLid
        manualDisplayIdleLimit = settings.v4.nextManualOptions.releaseDisplayAfterIdle
        if markers.pauseReason == .ownerEnded { mutateMarkers { $0.pauseReason = nil } }
        settings.lastManualDurationSeconds = duration
        resolveLegacyConfiguration()
        return true
    }
    public mutating func endManual(reason: ManualSessionEnd = .cancelled) { manual.end(reason); pruneIssuedBatteryPermits() }
    @discardableResult
    public mutating func setManualBatteryContinuationMinutes(_ minutes: Int?, now: Double) -> Bool {
        guard settings.isSupported, minutes == nil, validClock(now) else { return false }
        settings.manualBatteryContinuationMinutes = nil; resolveLegacyConfiguration()
        return true
    }
    @discardableResult
    public mutating func selectManualDuration(_ seconds: Double?) -> Bool {
        guard seconds.map({ $0.isFinite && $0 > 0 && $0 <= ManualSessionPolicy.maximumTimedDuration }) ?? true else { return false }
        settings.lastManualDurationSeconds = seconds; resolveLegacyConfiguration(); return true
    }
    public mutating func setAllowClosedLid(_ allowed: Bool) { settings.allowClosedLid = allowed; resolveLegacyConfiguration() }
    public mutating func setLockOnClose(_ enabled: Bool) { settings.lockOnClose = enabled; resolveLegacyConfiguration() }
    public var manualDisplayRequired: Bool {
        guard settings.keepDisplayAwake, manualKeepDisplayAwake else { return false }
        if let limit = manualDisplayIdleLimit, let seconds = displayIdleSeconds,
           let until = displayIdleValidUntil, let now = lastEvaluation,
           seconds.isFinite, seconds >= 0, until.isFinite, now < until, seconds >= limit { return false }
        return true
    }
    /// A fresh public input-idle observation only relaxes display keeping, never general work.
    public mutating func setDisplayIdleObservation(seconds: Double?, validUntil: Double?) {
        displayIdleSeconds = seconds; displayIdleValidUntil = validUntil
    }
    public mutating func setKeepDisplayAwake(_ enabled: Bool) { settings.keepDisplayAwake = enabled; resolveLegacyConfiguration() }
    public mutating func setClosedLidDisplayMode(_ value: ClosedLidDisplayMode) { settings.closedLidDisplayMode = value }
    public mutating func setDisconnectAction(_ action: WorkSessionEndAction) { settings.disconnectAction = action; resolveLegacyConfiguration() }
    public mutating func setDisconnectPolicy(_ value: WorkSessionDisconnectPolicy) {
        settings.disconnectPolicy = value; resolveLegacyConfiguration()
    }
    public mutating func setManualPowerCondition(_ value: PowerCondition) {
        settings.manualPowerCondition = value; resolveLegacyConfiguration()
    }
    public mutating func setBatteryTimeLimit(_ value: WorkSessionBatteryLimit) {
        settings.batteryTimeLimit = value; resolveLegacyConfiguration()
    }
    public mutating func setAutomaticallyResumeAfterProtection(_ value: Bool) {
        settings.automaticallyResumeAfterProtection = value; resolveLegacyConfiguration()
    }
    public mutating func setStopOnSeriousThermal(_ value: Bool) {
        settings.stopOnSeriousThermal = value; resolveLegacyConfiguration()
    }
    public mutating func setStartAutomaticOnBatteryDisconnect(_ value: Bool) {
        settings.startAutomaticOnBatteryDisconnect = value; resolveLegacyConfiguration()
    }
    @discardableResult
    public mutating func setV4Settings(_ value: V4Settings) -> Bool {
        guard settings.isSupported else { return false }
        settings.v4 = value; automaticGate = nil
        // A settings edit is not a newly observed condition edge, including one
        // left pending by the previously selected advanced mode.
        gateWasSatisfied = nil; pendingConditionActivation = false
        resolveLegacyConfiguration(); return true
    }
    @discardableResult
    public mutating func applyUserChoices(automatic: Bool, allowClosedLid: Bool) -> Bool {
        guard settings.isSupported else { return false }
        setAutomatic(automatic); setAllowClosedLid(allowClosedLid); return true
    }
    public mutating func setV4AutomaticGate(_ gate: V4AutomaticGate?, now: Double) {
        guard validClock(now) else { return }
        if let gate, gate.validUntil.map({ now < $0 }) == true {
            if gate.isSatisfied, gateWasSatisfied == false { pendingConditionActivation = true }
            gateWasSatisfied = gate.isSatisfied
        }
        automaticGate = gate
    }
    public mutating func resolveLegacyConfiguration() { settings.legacyRootConfigurationPending = false }
    /// Legacy root preferences are choices only. Local off/protection is retained.
    public mutating func adoptLegacyConfiguration(_ control: Control, explicitActivation: Bool = false) {
        guard control.isSupported else { return }
        let pending = settings.legacyRootConfigurationPending == true
        if !control.enabled, !explicitActivation { setEnabled(false) }
        guard pending else { return }
        settings.automaticEnabled = settings.enabled && control.enabled && control.powerCondition != nil
            && control.powerCondition != .battery
        settings.powerCondition = control.condition
        settings.automaticHoldMinutes = min(120, control.automaticMinutes)
        if control.batteryHoldUntil != nil || control.pendingHoldMinutes != nil {
            let condition = settings.condition
            mutateMarkers { $0.automaticActivation = AutomaticActivationMarker(
                condition: condition, batteryConsumed: true, batteryExpired: true) }
        }
        if let floor = control.limits?.batteryFloor {
            settings.limits = UserLimits(batteryFloor: max(floor, SafetyPolicy.floor(settings.limits)))
        }
    }
    public mutating func mergeLegacyBudgets(automatic: ProtectionState, manual: ProtectionState?) {
        // Original root ledgers remain recovery evidence; v3 never executes them.
        if let reason = WorkSessionBridge.generalWorkBlockReason(automatic.blockReason) { acceptProtection(reason) }
        if let reason = WorkSessionBridge.generalWorkBlockReason(manual?.blockReason) { acceptProtection(reason) }
    }
    public mutating func acceptProtection(_ reason: String) { stopForProtection(reason) }
    @discardableResult
    public mutating func extend(duration: TimeInterval, now: Double) -> Bool {
        guard canExtend(duration: duration, now: now) else { return false }
        return manual.extend(duration: duration, now: now)
    }
    public func canExtend(duration: TimeInterval, now: Double) -> Bool {
        settings.isSupported && settings.enabled && markers.permitsAcquisition && validClock(now)
            && lastEvaluation.map({ now - $0 <= Self.observationTTL }) == true
            && latestFullWake == true && latestControllingUser
            && thermalAllowsWork && latestPower != .unknown
            && batteryAllowsWork && manual.canExtend(duration: duration, now: now)
    }
    @discardableResult
    public mutating func commitPreparedManualExtension(_ proposed: IdleSessionPolicy, now: Double) -> Bool {
        guard manual.requestID != nil, manual.requestID == proposed.manual.requestID,
              manual.startedAt == proposed.manual.startedAt,
              let oldDeadline = manual.requestedDeadline, let newDeadline = proposed.manual.requestedDeadline,
              proposed.manual.extensionID != nil, proposed.manual.extensionID != manual.extensionID,
              canExtend(duration: newDeadline - oldDeadline, now: now),
              manual.batteryDeadline == proposed.manual.batteryDeadline else { return false }
        manual = proposed.manual
        manual.evaluate(power: latestPower, now: now)
        return manual.active
    }
    @discardableResult
    public mutating func restoreManualRevision(from original: IdleSessionPolicy, expectedExtensionID: UUID, now: Double) -> Bool {
        if manual.requestID != nil, manual.requestID == original.manual.requestID,
           manual.extensionID == expectedExtensionID, let deadline = original.effectiveManualDeadline,
           now.isFinite, now >= deadline {
            manual.end(original.manual.batteryDeadline.map { $0 <= deadline } == true ? .batteryBudget : .time)
            return false
        }
        guard manual.requestID != nil, manual.requestID == original.manual.requestID,
              manual.extensionID == expectedExtensionID, manual.startedAt == original.manual.startedAt,
              let originalDeadline = original.manual.requestedDeadline, now < originalDeadline,
              settings.isSupported, settings.enabled, markers.permitsAcquisition,
              validClock(now), latestPower != .unknown, batteryAllowsWork,
              latestFullWake == true, latestControllingUser,
              thermalAllowsWork else {
            // Never end a different, newly approved manual request.
            if manual.requestID == original.manual.requestID { manual.end(.sessionEnded) }
            return false
        }
        manual = original.manual; manual.evaluate(power: latestPower, now: now)
        return manual.active
    }
    @discardableResult
    public mutating func rescheduleManual(duration: TimeInterval, now: Double) -> Bool { false }
    @discardableResult
    public mutating func extendBatteryHold(minutes: Int, now: Double) -> Bool { false }
    public func canExtendBatteryHold(minutes: Int, now: Double) -> Bool { false }
    /// Old direct-hold callers create the one manual request, never a third timer.
    @discardableResult
    public mutating func startBatteryHold(minutes: Int, now: Double) -> Bool {
        guard (1...120).contains(minutes), canStart(now: now) else { return false }
        let accepted = manual.start(duration: Double(minutes * 60), power: latestPower, now: now,
            disconnectPolicy: settings.disconnectPolicy, powerCondition: settings.manualPowerCondition,
            batteryLimit: settings.batteryTimeLimit)
        if accepted {
            manualDisplayChoice = settings.v4.nextManualOptions.display; manualLidChoice = settings.v4.nextManualOptions.closedLid
        manualDisplayIdleLimit = settings.v4.nextManualOptions.releaseDisplayAfterIdle
            if markers.pauseReason == .ownerEnded { mutateMarkers { $0.pauseReason = nil } }
            resolveLegacyConfiguration()
        }
        return accepted
    }
    public mutating func cancelBatteryHold() { endManual() }
    @discardableResult
    public mutating func setLimits(_ limits: UserLimits?) -> Bool {
        var next = settings; next.limits = limits
        guard next.isSupported else { return false }
        next.limits = limits.flatMap { $0.batteryFloor.map { UserLimits(batteryFloor: $0) } }
        settings = next; resolveLegacyConfiguration(); return true
    }
    public mutating func setEnabled(_ enabled: Bool) {
        resolveLegacyConfiguration(); settings.enabled = enabled
        if !enabled { stopCurrent() }
    }
    public mutating func setAutomatic(_ enabled: Bool) {
        resolveLegacyConfiguration(); settings.automaticEnabled = enabled
        if enabled, settings.automaticPowerCondition == nil { settings.automaticPowerCondition = settings.condition }
        if !enabled {
            mutateMarkers { $0.automaticPause = nil }
            automaticActive = false
            automaticExecutionID = nil
            if batteryDeadline != nil { finishAutomaticBattery() }
        }
    }
    @discardableResult
    public mutating func pauseAutomatic(for duration: TimeInterval?, now: Double) -> Bool {
        guard settings.automaticEnabled, validClock(now),
              duration.map({ [1800.0, 3600.0].contains($0) && boot != "unknown" }) ?? true else { return false }
        let deadline = duration.map { now + $0 }
        guard deadline.map(\.isFinite) ?? true else { return false }
        let marker = AutomaticPauseMarker(bootID: boot, until: deadline)
        mutateMarkers { $0.automaticPause = marker }
        automaticActive = false; automaticExecutionID = nil; automaticNeedsNewExecution = true
        return true
    }
    /// Remove only the automatic pause. General Stop/Sleep, safety protection,
    /// disconnect consumption and an activation's first battery cap remain intact.
    public mutating func resumeAutomatic() {
        mutateMarkers { $0.automaticPause = nil }
        automaticNeedsNewExecution = true
    }
    public mutating func setPowerCondition(_ condition: PowerCondition) {
        resolveLegacyConfiguration(); settings.automaticPowerCondition = condition
    }
    @discardableResult
    public mutating func setAutomaticMinutes(_ minutes: Int) -> Bool {
        guard (1...120).contains(minutes) else { return false }
        resolveLegacyConfiguration(); settings.automaticHoldMinutes = minutes; return true
    }
    public mutating func stopCurrent() {
        endTemporarySession(); mutateMarkers { $0.pauseReason = .userStop }
    }
    public mutating func loseGUIAuthority() {
        endTemporarySession(); mutateMarkers { $0.pauseReason = .ownerEnded }
    }
    public mutating func pauseForUserSleep(now: Double) {
        guard validClock(now) else { return }
        // A condition edge observed before Sleep was accepted cannot later
        // become the new event that clears that Sleep's restart block.
        pendingConditionActivation = false
        endTemporarySession()
        mutateMarkers { if $0.pauseReason == nil { $0.pauseReason = .userSleep } }
        userSleepRequestedAt = now; userSleepObserved = false
    }
    /// The UI and command path share the same protection recovery threshold.
    public func canResume(thermal: Int?) -> Bool {
        guard settings.isSupported, latestPower != .unknown, latestFullWake == true, latestControllingUser,
              thermal.map({ (0..<2).contains($0) }) == true else { return false }
        guard !settings.v4.stopOnLowPowerMode || latestLowPowerMode == false else { return false }
        if markers.protectionReason != nil {
            guard let now = lastEvaluation, recoveryWindow.isReady(now: now) else { return false }
        }
        if latestPower == .battery {
            guard !settings.v4.stopOnLowPowerMode || latestLowPowerMode == false else { return false }
            guard latestLowPowerWarning == false, let percent = latestBatteryPercent, (0...100).contains(percent),
                  percent >= SafetyPolicy.floor(settings.limits) + SafetyPolicy.resumeBatteryMargin else { return false }
        }
        return true
    }
    @discardableResult
    public mutating func resume(thermal: Int?) -> Bool {
        guard canResume(thermal: thermal) else { return false }
        settings.enabled = true; resolveLegacyConfiguration()
        mutateMarkers { $0.pauseReason = nil; $0.protectionReason = nil; $0.automaticActivation = nil; $0.automaticRestartBlocked = nil }
        automaticDuration = nil; automaticStartedAt = nil; batteryDeadline = nil
        automaticExecutionID = nil; disconnectBlocksAutomatic = false
        userSleepRequestedAt = nil; userSleepObserved = false
        pruneIssuedBatteryPermits()
        return true
    }
    public mutating func endTemporarySession() {
        manual.end(.sessionEnded); automaticActive = false; expiry = nil; decision = WorkSessionDecision()
        automaticExecutionID = nil
        if batteryDeadline != nil { finishAutomaticBattery() }
        issuedBatteryPermits.removeAll()
    }
    public mutating func suspendForSystemSleep() { consumeSystemSleep(observedAt: lastEvaluation ?? 0) }
    public mutating func consumeSystemSleep(observedAt: Double) {
        guard observedAt.isFinite, observedAt >= 0 else { return }
        // Sleep consumes temporary manual work. A new fullWake automatic ID may
        // use the same activation's original battery anchor, never a fresh cap.
        if manual.startedAt.map({ $0 <= observedAt }) == true { manual.end(.sessionEnded) }
        temporaryConsumptionAt = max(temporaryConsumptionAt ?? observedAt, observedAt)
        automaticExecutionID = nil; automaticNeedsNewExecution = true
        recoveryWindow.reset(); lastValidExecutionObservation = nil
        issuedBatteryPermits.removeAll()
        if markers.pauseReason == .userSleep,
           userSleepRequestedAt.map({ observedAt >= $0 }) == true { userSleepObserved = true }
        automaticActive = false; expiry = nil; decision = WorkSessionDecision()
    }
    public mutating func consumeExecutorEnd(observedAt: Double, protection: String? = nil) {
        guard observedAt.isFinite, observedAt >= 0 else { return }
        // A captured/consumed helper command is not an observed OS Sleep.
        consumeRequests(observedAt: observedAt)
        automaticActive = false; expiry = nil; decision = WorkSessionDecision()
        if let protection { stopForProtection(protection) }
    }
    /// Record only a concrete outgoing lid permit. An ACK can still cap a live
    /// automatic activation after its companion manual request has ended, but
    /// cannot consume intent that joined this permit after root's observation.
    @discardableResult
    public mutating func recordBatteryPermitIssued(id: UUID, now: Double) -> Bool {
        guard settings.isSupported, settings.enabled, markers.permitsAcquisition, validClock(now),
              decision.batteryPermitID == id, decision.powerScopes.contains(.battery),
              decision.expiry.map({ $0 > now }) == true else { return false }
        pruneIssuedBatteryPermits()
        guard issuedBatteryPermits[id] != nil || issuedBatteryPermits.count < Self.maximumIssuedBatteryPermits else { return false }
        var issued = issuedBatteryPermits[id] ?? IssuedBatteryPermit()
        if manual.allowsBattery, issued.manualID != manual.requestID {
            issued.manualID = manual.requestID; issued.manualIssuedAt = now
        }
        if let activation = markers.automaticActivation, !activation.conditionEnded, !activation.batteryExpired,
           settings.automaticEnabled, automaticPowerCondition.includesBattery,
           issued.automaticID != activation.id {
            issued.automaticID = activation.id; issued.automaticIssuedAt = now
        }
        guard issued.manualID != nil || issued.automaticID != nil else { return false }
        issuedBatteryPermits[id] = issued
        return true
    }
    public func recognizesBatteryPermit(id: UUID, observedAt: Double) -> Bool {
        guard observedAt.isFinite, observedAt >= 0, let issued = issuedBatteryPermits[id] else { return false }
        return matchesManualPermit(issued, observedAt: observedAt) || matchesAutomaticPermit(issued, observedAt: observedAt)
    }
    @discardableResult
    public mutating func acceptBatteryPermit(id: UUID, observedAt: Double, deadline: Double, now: Double,
                                            extensionID: UUID? = nil) -> Bool {
        guard settings.isSupported, settings.enabled, markers.permitsAcquisition, validClock(now),
              recognizesBatteryPermit(id: id, observedAt: observedAt), observedAt <= now,
              deadline.isFinite, deadline > observedAt, boot != "unknown",
              let issued = issuedBatteryPermits[id] else { return false }
        var accepted = false
        if matchesManualPermit(issued, observedAt: observedAt) {
            accepted = manual.acceptBatteryPermit(observedAt: observedAt, deadline: deadline, now: now, extensionID: extensionID)
        }
        if matchesAutomaticPermit(issued, observedAt: observedAt), let seconds = automaticDuration {
            // A short companion manual deadline is not the automatic budget.
            let cap = issued.manualID == nil ? min(deadline, observedAt + seconds) : observedAt + seconds
            batteryDeadline = min(batteryDeadline ?? cap, cap)
            automaticStartedAt = min(automaticStartedAt ?? observedAt, observedAt)
            mutateMarkers { $0.automaticActivation?.batteryConsumed = true }
            if latestPower == .battery && now >= cap { finishAutomaticBattery() }
            accepted = true
        }
        // The terminal observation may have arrived before this first battery
        // ACK. Consuming the same boundary again cannot end newer intent.
        if accepted, let observedAt = temporaryConsumptionAt { consumeRequests(observedAt: observedAt) }
        return accepted
    }
    @discardableResult
    public mutating func acceptPowerTransition(_ transition: WorkSessionPowerTransition, now: Double,
                                              observedAt: Double? = nil) -> Bool {
        let observed = observedAt ?? now
        guard transition.power == .battery, transition.isValid(source: .ac, parentExpiry: transition.expiry, now: observed),
              markers.permitsAcquisition, validClock(now), thermalAllowsWork else { return false }
        var accepted = false
        if transition.reasons.contains(.manual) {
            accepted = manual.acceptBatteryTransition(transition, now: now, observedAt: observed)
        }
        if transition.reasons.contains(.automatic), let end = transition.batteryDeadline,
           let activation = markers.automaticActivation, !activation.batteryExpired,
           settings.automaticEnabled, automaticPowerCondition.includesBattery, let seconds = automaticDuration {
            let cap = min(end, observed + seconds)
            batteryDeadline = min(batteryDeadline ?? cap, cap); automaticStartedAt = min(automaticStartedAt ?? observed, observed)
            mutateMarkers { $0.automaticActivation?.batteryConsumed = true }
            if now >= cap { finishAutomaticBattery() }
            accepted = true
        }
        return accepted
    }
    public mutating func evaluate(power: PowerSource, thermal: Int?, fullWake: Bool?,
                                  controllingUser: Bool, now: Double, batteryPercent: Int? = nil,
                                  lowPowerWarning: Bool? = false, lowPowerMode: Bool? = false) {
        let previousDecision = decision
        expiry = nil; automaticActive = false; decision = WorkSessionDecision()
        guard validClock(now) else { return }
        lastEvaluation = now; lastThermal = thermal; latestPower = power; latestBatteryPercent = batteryPercent
        if automaticPauseDeadline.map({ now >= $0 }) == true {
            resumeAutomatic()
        }
        latestFullWake = fullWake; latestControllingUser = controllingUser
        latestLowPowerWarning = lowPowerWarning
        latestLowPowerMode = lowPowerMode
        let disconnected = lastKnownPower == .ac && power == .battery
        let connected = lastKnownPower == .battery && power == .ac
        let conditionActivation = pendingConditionActivation
        pendingConditionActivation = false
        if disconnected {
            switch settings.disconnectPolicy {
            case .endAll:
                manual.end(.powerDisconnected); endAutomaticForDisconnect()
            case .endAutomatic: endAutomaticForDisconnect()
            case .continueEligible:
                // Only work that was actually running before this incident may
                // continue. A saved marker, delayed rule edge or retired start
                // preference cannot turn unplugging into a new battery start.
                let existingEligible = automaticPowerCondition.includesBattery
                    && previousDecision.reasons.contains(.automatic)
                    && previousDecision.expiry.map({ now < $0 }) == true
                    && markers.automaticActivation.map({ !$0.conditionEnded && !$0.batteryExpired }) == true
                if !existingEligible { endAutomaticForDisconnect() }
            }
        }
        manual.evaluate(power: power, now: now, disconnectPolicy: settings.disconnectPolicy)
        if power == .battery, let end = batteryDeadline, now >= end { finishAutomaticBattery() }
        guard controllingUser else { loseGUIAuthority(); return }
        guard settings.isSupported else { return }
        recoveryWindow.observe(now: now, thermal: thermal, power: power, battery: batteryPercent,
            floor: SafetyPolicy.floor(settings.limits), lowWarning: lowPowerWarning,
            lowMode: lowPowerMode, stopOnLowMode: settings.v4.stopOnLowPowerMode)
        // Confirmed hazards are immediate; only unresolved observations may use
        // the remainder of an already-issued finite permission.
        if let thermal, thermal == 3 || (settings.stopOnSeriousThermal && thermal == 2) {
            stopForProtection("thermal"); return
        }
        let batteryWork = power == .battery && (manual.active
            || (settings.automaticEnabled && automaticPowerCondition.includesBattery))
        if batteryWork, lowPowerWarning == true || batteryPercent.map({ (0...100).contains($0) && $0 <= SafetyPolicy.floor(settings.limits) }) == true {
            stopForProtection("battery"); return
        }
        if settings.v4.stopOnLowPowerMode, lowPowerMode == true,
           manual.active || previousDecision.generalAssertionRequired || settings.automaticEnabled {
            stopForProtection("lowPowerMode"); return
        }
        let readingsFresh = power != .unknown && thermal.map({ (0...3).contains($0) }) == true
            && (!settings.v4.stopOnLowPowerMode || lowPowerMode != nil)
            && (!batteryWork || (batteryPercent.map { (0...100).contains($0) } == true && lowPowerWarning != nil))
        if !readingsFresh {
            carryExistingPermission(previousDecision, now: now)
            if power != .unknown { lastKnownPower = power }
            return
        }
        lastValidExecutionObservation = now
        if connected || (conditionActivation && !disconnected) {
            let explicitSleepEvent = markers.pauseReason == .userSleep
            if markers.pauseReason == .userSleep {
                mutateMarkers { $0.pauseReason = nil }; userSleepRequestedAt = nil; userSleepObserved = false
            }
            let newActivation = conditionActivation || explicitSleepEvent
                || markers.automaticActivation == nil || markers.automaticActivation?.conditionEnded == true
                || markers.automaticRestartBlocked == true
            if newActivation, markers.pauseReason == nil && markers.protectionReason == nil {
                beginAutomaticActivation()
            }
        }
        // A known false condition is the only natural activation boundary. In
        // both-power mode AC remains true; unknown and edits are not boundaries.
        if power != .unknown {
            observeAutomaticBoundary(power: power)
            lastKnownPower = power
        }
        pruneIssuedBatteryPermits()
        if settings.automaticallyResumeAfterProtection, markers.protectionReason != nil,
           markers.pauseReason == nil, recoveryWindow.isReady(now: now) {
            // Protection consumed manual/lease work. Only current automatic
            // conditions can be evaluated again, with the original battery cap.
            mutateMarkers { $0.protectionReason = nil }
            automaticNeedsNewExecution = true
        }
        guard settings.enabled, markers.permitsAcquisition, fullWake == true, power != .unknown else { return }
        let advancedAllowed = !settings.v4.usesAdvancedAutomaticConditions
            || (automaticGate?.isSatisfied == true && automaticGate?.validUntil.map({ now < $0 }) == true)
        let capturedCondition = automaticPowerCondition
        let automaticEligible = settings.automaticEnabled && capturedCondition.permits(power) && advancedAllowed
            && !automaticPauseActive
            && !disconnectBlocksAutomatic && markers.automaticRestartBlocked != true
            && markers.automaticActivation?.batteryExpired != true
        let batteryNeeded = power == .battery && (manual.active || automaticEligible)
        if power == .battery, manual.active, settings.v4.stopOnLowPowerMode,
           lowPowerMode != false {
            stopForProtection(lowPowerMode == true ? "lowPowerMode" : "sensor"); return
        }
        if batteryNeeded, !batteryAllowsWork {
            let readingsValid = batteryPercent.map({ (0...100).contains($0) }) == true && lowPowerWarning != nil
            stopForProtection(readingsValid ? "battery" : "sensor")
            return
        }
        if automaticEligible {
            if markers.automaticActivation == nil {
                beginAutomaticActivation()
            }
            if power == .battery, markers.automaticActivation?.batteryConsumed != true, boot != "unknown" {
                automaticStartedAt = now
                batteryDeadline = automaticDuration.map { now + $0 }
                let capturedDeadline = batteryDeadline
                mutateMarkers {
                    $0.automaticActivation?.batteryConsumed = true
                    $0.automaticActivation?.batteryStartedAt = now
                    $0.automaticActivation?.batteryDeadline = capturedDeadline
                }
            }
            automaticActive = power == .ac || (boot != "unknown" && (batteryDeadline.map({ now < $0 })
                ?? (automaticBatteryTimeLimit == .unlimited)))
            if automaticActive && (automaticExecutionID == nil || automaticNeedsNewExecution) {
                automaticExecutionID = UUID(); automaticExecutionStartedAt = now; automaticNeedsNewExecution = false
            }
        }
        var reasons: [WorkSessionReason] = []
        if automaticActive { reasons.append(.automatic) }
        if manual.canHold { reasons.append(.manual) }
        guard !reasons.isEmpty else { return }
        let automaticEnd = automaticActive ? (power == .ac ? nil : batteryDeadline) : nil
        let manualEnd = manual.canHold ? manual.effectiveDeadline : nil
        let unlimited = (automaticActive && automaticEnd == nil) || (manual.canHold && manualEnd == nil)
        let final = unlimited ? nil : [automaticEnd, manualEnd].compactMap { $0 }.max()
        expiry = min(now + Self.observationTTL, now + Self.healthTTL, final ?? .infinity)
        if automaticActive, settings.v4.usesAdvancedAutomaticConditions,
           let validUntil = automaticGate?.validUntil { expiry = min(expiry!, validUntil) }
        // Saved basic-mode battery choices grant no automatic battery scope.
        // A directly approved manual or advanced both-power request remains separate.
        let manualBatteryAllowed = manual.allowsBattery
        let automaticBatteryAllowed = automaticActive && capturedCondition.includesBattery
            && (power == .battery || settings.disconnectPolicy == .continueEligible)
        let permitID = manualBatteryAllowed ? manual.requestID : (automaticBatteryAllowed ? automaticExecutionID : nil)
        let permitDeadline = manualBatteryAllowed ? manual.batteryDeadline : (automaticBatteryAllowed ? batteryDeadline : nil)
        var scopes: [PowerSource] = [power]
        if power == .ac && (manual.allowsBattery || automaticBatteryAllowed) { scopes.append(.battery) }
        let automaticOptions = settings.v4.usesAdvancedAutomaticConditions
            ? settings.v4.presets.first(where: { $0.id == settings.v4.activePresetID })?.options
            : nil
        func displayPermitted(_ idleLimit: Double?) -> Bool {
            guard let idleLimit, let displayIdleSeconds, let displayIdleValidUntil,
                  idleLimit.isFinite, idleLimit > 0, displayIdleSeconds.isFinite, displayIdleSeconds >= 0,
                  displayIdleValidUntil.isFinite, now < displayIdleValidUntil else { return true }
            return displayIdleSeconds < idleLimit
        }
        let autoDisplay = automaticActive && (automaticOptions?.display ?? settings.keepDisplayAwake)
            && displayPermitted(automaticOptions?.releaseDisplayAfterIdle)
        let autoLid = automaticActive && (automaticOptions?.closedLid ?? settings.allowClosedLid)
        decision = WorkSessionDecision(reasons: reasons, expiry: expiry, finalDeadline: final,
            manualDeadline: manual.effectiveDeadline, automaticBatteryDeadline: batteryDeadline,
            batteryPermitID: permitID,
            batteryDuration: manualBatteryAllowed ? manual.selectedBatteryDuration : (automaticBatteryAllowed ? automaticDuration : nil),
            batteryDeadline: permitDeadline, powerScopes: scopes,
            displayRequired: settings.keepDisplayAwake && (autoDisplay || (manualKeepDisplayAwake && displayPermitted(manualDisplayIdleLimit))),
            closedLidRequired: settings.allowClosedLid && (autoLid || manualAllowClosedLid),
            automaticRequestID: automaticActive ? automaticExecutionID : nil,
            batteryPermitLimit: permitID == nil ? nil : (manualBatteryAllowed ? manual.batteryLimit : automaticBatteryTimeLimit))
    }
    private mutating func observeAutomaticBoundary(power: PowerSource) {
        guard var activation = markers.automaticActivation else { return }
        let capturedCondition = automaticPowerCondition
        if !eligible(capturedCondition, power) {
            activation.conditionEnded = true
            mutateMarkers { $0.automaticActivation = activation }
        } else if activation.conditionEnded, eligible(effectiveAutomaticCondition, power) {
            // A confirmed false-to-true boundary starts a new activation, but
            // never overrides Stop all, protection or an unplug stop on battery.
            if power == .ac {
                if markers.pauseReason == .userSleep { mutateMarkers { $0.pauseReason = nil } }
                beginAutomaticActivation()
            }
        }
    }
    private func eligible(_ condition: PowerCondition, _ power: PowerSource) -> Bool {
        condition.permits(power)
    }
    private func canStart(now: Double) -> Bool {
        settings.isSupported && settings.enabled && permitsExplicitManualStart && validClock(now)
            && lastEvaluation.map({ now - $0 <= Self.observationTTL }) == true
            && latestFullWake == true && latestControllingUser
            && thermalAllowsWork && latestPower != .unknown && batteryAllowsWork
    }
    private var thermalAllowsWork: Bool {
        lastThermal.map { (0...2).contains($0) && (!settings.stopOnSeriousThermal || $0 < 2) } == true
    }
    private func validClock(_ now: Double) -> Bool {
        now.isFinite && now >= 0 && (lastEvaluation.map { now >= $0 } ?? true)
    }
    private func matchesManualPermit(_ issued: IssuedBatteryPermit, observedAt: Double) -> Bool {
        manual.allowsBattery && issued.manualID == manual.requestID
            && issued.manualIssuedAt.map({ observedAt >= $0 }) == true
    }
    private func matchesAutomaticPermit(_ issued: IssuedBatteryPermit, observedAt: Double) -> Bool {
        guard let activation = markers.automaticActivation else { return false }
        return settings.automaticEnabled && automaticPowerCondition.includesBattery
            && !activation.conditionEnded && !activation.batteryExpired && issued.automaticID == activation.id
            && issued.automaticIssuedAt.map({ observedAt >= $0 }) == true
    }
    private mutating func pruneIssuedBatteryPermits() {
        let manualID = manual.allowsBattery ? manual.requestID : nil
        let activation = markers.automaticActivation
        let automaticID = automaticPowerCondition.includesBattery
            && activation?.conditionEnded != true && activation?.batteryExpired != true ? activation?.id : nil
        for (id, var issued) in issuedBatteryPermits {
            if issued.manualID != manualID { issued.manualID = nil; issued.manualIssuedAt = nil }
            if issued.automaticID != automaticID { issued.automaticID = nil; issued.automaticIssuedAt = nil }
            if issued.manualID == nil && issued.automaticID == nil { issuedBatteryPermits.removeValue(forKey: id) }
            else { issuedBatteryPermits[id] = issued }
        }
    }
    private mutating func finishAutomaticBattery() {
        automaticActive = false; automaticExecutionID = nil
        mutateMarkers {
            if $0.automaticActivation?.batteryConsumed == true { $0.automaticActivation?.batteryExpired = true }
            $0.automaticRestartBlocked = true
        }
    }
    private mutating func consumeRequests(observedAt: Double) {
        temporaryConsumptionAt = max(temporaryConsumptionAt ?? observedAt, observedAt)
        if manual.startedAt.map({ $0 <= observedAt }) == true { manual.end(.sessionEnded) }
        if automaticExecutionStartedAt.map({ $0 <= observedAt }) == true { finishAutomaticBattery() }
        pruneIssuedBatteryPermits()
    }
    private mutating func stopForProtection(_ reason: String) {
        manual.end(.protection); automaticActive = false; automaticExecutionID = nil
        automaticNeedsNewExecution = true; expiry = nil; decision = WorkSessionDecision()
        issuedBatteryPermits.removeAll()
        recoveryWindow.reset()
        mutateMarkers { $0.protectionReason = $0.protectionReason ?? reason }
    }
    private mutating func beginAutomaticActivation() {
        let condition = effectiveAutomaticCondition, limit = settings.batteryTimeLimit
        mutateMarkers {
            $0.automaticActivation = AutomaticActivationMarker(condition: condition, batteryLimit: limit)
            $0.automaticRestartBlocked = nil
        }
        automaticDuration = limit.seconds; automaticStartedAt = nil; batteryDeadline = nil
        automaticExecutionID = nil; automaticNeedsNewExecution = true; disconnectBlocksAutomatic = false
    }
    private mutating func endAutomaticForDisconnect() {
        automaticActive = false; automaticExecutionID = nil; disconnectBlocksAutomatic = true
        mutateMarkers { $0.automaticRestartBlocked = true }
    }
    private mutating func carryExistingPermission(_ previous: WorkSessionDecision, now: Double) {
        if manual.active, let deadline = manual.effectiveDeadline, now >= deadline {
            manual.end(manual.batteryDeadline.map { $0 <= deadline } == true ? .batteryBudget : .time)
        }
        if latestPower == .battery, let deadline = batteryDeadline, now >= deadline { finishAutomaticBattery() }
        guard let lastValidExecutionObservation else {
            if manual.active { manual.end(.observationUnavailable); stopForProtection("sensor") }
            return
        }
        let bound = min(previous.expiry ?? lastValidExecutionObservation + Self.observationTTL,
                        lastValidExecutionObservation + Self.observationTTL)
        if now >= bound {
            if manual.active || !previous.reasons.isEmpty {
                manual.end(.observationUnavailable); stopForProtection("sensor")
            }
            return
        }
        guard settings.enabled, markers.permitsAcquisition else { return }
        var retained = previous
        retained.reasons = previous.reasons.filter {
            $0 == .manual ? manual.active : (settings.automaticEnabled && !automaticPauseActive
                && !disconnectBlocksAutomatic && markers.automaticRestartBlocked != true
                && automaticPowerCondition.permits(latestPower == .unknown ? lastKnownPower : latestPower))
        }
        let hasAutomatic = retained.reasons.contains(.automatic)
        let hasManual = retained.reasons.contains(.manual)
        if !hasAutomatic { retained.automaticRequestID = nil }
        let automaticOptions = settings.v4.usesAdvancedAutomaticConditions
            ? settings.v4.presets.first(where: { $0.id == settings.v4.activePresetID })?.options
            : nil
        // Missing observations cannot add an output, but a confirmed user
        // opt-out or a removed contributor must still release that output now.
        retained.displayRequired = previous.displayRequired && settings.keepDisplayAwake
            && ((hasAutomatic && (automaticOptions?.display ?? settings.keepDisplayAwake))
                || (hasManual && manualDisplayRequired))
        retained.closedLidRequired = previous.closedLidRequired && settings.allowClosedLid
            && ((hasAutomatic && (automaticOptions?.closedLid ?? settings.allowClosedLid))
                || (hasManual && manualAllowClosedLid))
        guard !retained.reasons.isEmpty, let issuedExpiry = previous.expiry, now < issuedExpiry else { return }
        let automaticDeadline = latestPower == .battery ? batteryDeadline : nil
        let deadline = [manual.effectiveDeadline, automaticDeadline].compactMap { $0 }.filter { $0 > now }.min()
        retained.expiry = min(bound, deadline ?? .infinity)
        retained.generalAssertionRequired = retained.expiry.map { now < $0 } == true
        retained.renewalAllowed = false
        decision = retained; expiry = retained.expiry
        automaticActive = retained.reasons.contains(.automatic)
    }
    private mutating func mutateMarkers(_ body: (inout RuntimeMarkers) -> Void) {
        var next = markers; body(&next); settings.runtimeMarkers = next; synchronizeCompatibilityMarkers()
    }
    private mutating func synchronizeCompatibilityMarkers() {
        settings.automaticSuppressed = !markers.permitsAcquisition
        settings.blockReason = markers.protectionReason
        settings.batterySuppressed = markers.automaticActivation?.batteryConsumed == true
        settings.manualBatteryBudget = nil; settings.automaticBatteryBudget = nil
    }
}
