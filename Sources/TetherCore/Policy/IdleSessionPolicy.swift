import Foundation

/// User choices and durable stop markers share one atomic preference record.
/// Legacy budget fields are decode-only compatibility; no v3 request uses them.
public struct IdleSessionSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 6
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
    public var v4: V4Settings = .init()
    public var disconnectAction: WorkSessionEndAction = .sleepIfClosed
    /// Nil is an explicit AC unlimited choice. A missing old key defaults to 30m.
    public var lastManualDurationSeconds: Double? = 30 * 60
    /// Old battery/both choices are retained for decoding, never battery authority.
    public var condition: PowerCondition { .ac }
    public var automaticMinutes: Int { min(120, max(1, automaticHoldMinutes ?? 60)) }
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case version, enabled, automaticEnabled, automaticSuppressed, blockReason, limits,
             manualBatteryBudget, manualBatteryContinuationMinutes, powerCondition,
             automaticHoldMinutes, automaticBatteryBudget, batterySuppressed,
             legacyRootConfigurationPending, runtimeMarkers, allowClosedLid, lockOnClose,
             disconnectAction, lastManualDurationSeconds, keepDisplayAwake, v4
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
        v4 = try c.decodeIfPresent(V4Settings.self, forKey: .v4) ?? .init()
        disconnectAction = try c.decodeIfPresent(WorkSessionEndAction.self, forKey: .disconnectAction) ?? .sleepIfClosed
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
        try c.encode(v4, forKey: .v4)
        try c.encode(disconnectAction, forKey: .disconnectAction)
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
        guard (1..<Self.currentVersion).contains(version), (blockReason?.utf8.count ?? 0) <= 256,
              manualBatteryContinuationMinutes.map({ (1...240).contains($0) }) ?? true,
              automaticHoldMinutes.map({ (1...240).contains($0) }) ?? true else { return nil }
        var next = self; next.version = Self.currentVersion
        if powerCondition == .battery { next.automaticEnabled = false }
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
    public static let healthTTL: TimeInterval = 30
    public static let renewalInterval: TimeInterval = 10
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
        latestPower != .battery || (latestLowPowerWarning == false
            && SafetyPolicy.canStartHold(batteryPercent: latestBatteryPercent, user: settings.limits)
            && (!settings.v4.stopOnLowPowerMode || latestLowPowerMode == false))
    }
    public var manualStart: Double? { manual.startedAt }
    public var manualRequestID: UUID? { manual.requestID }
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
        guard settings.automaticEnabled, settings.condition.includesBattery,
              markers.automaticActivation?.batteryExpired != true else { return nil }
        return markers.automaticActivation?.id
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
        if next.powerCondition == .battery { next.automaticEnabled = false }
        next.manualBatteryBudget = nil; next.automaticBatteryBudget = nil
        if next.isSupported { next.limits = next.limits.flatMap { $0.batteryFloor.map { UserLimits(batteryFloor: $0) } } }
        self.settings = next; self.boot = boot
        manual = ManualSessionPolicy(batteryContinuationMinutes: next.manualBatteryContinuationMinutes, boot: boot)
        synchronizeCompatibilityMarkers()
    }
    @discardableResult
    public mutating func start(duration: TimeInterval?, now: Double) -> Bool {
        guard canStart(now: now), manual.start(duration: duration, power: latestPower, now: now) else { return false }
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
    public mutating func setDisconnectAction(_ action: WorkSessionEndAction) { settings.disconnectAction = action; resolveLegacyConfiguration() }
    @discardableResult
    public mutating func setV4Settings(_ value: V4Settings) -> Bool {
        guard settings.isSupported else { return false }
        settings.v4 = value; automaticGate = nil; resolveLegacyConfiguration(); return true
    }
    @discardableResult
    public mutating func applyUserChoices(automatic: Bool, allowClosedLid: Bool) -> Bool {
        guard settings.isSupported else { return false }
        setAutomatic(automatic); setAllowClosedLid(allowClosedLid); return true
    }
    public mutating func setV4AutomaticGate(_ gate: V4AutomaticGate?, now: Double) {
        guard validClock(now) else { return }
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
            && lastThermal.map({ (0..<2).contains($0) }) == true && latestPower != .unknown
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
              lastThermal.map({ (0..<2).contains($0) }) == true else {
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
        let accepted = manual.start(duration: Double(minutes * 60), power: latestPower, now: now)
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
        if enabled { settings.powerCondition = .ac }
        if !enabled {
            automaticActive = false
            if batteryDeadline != nil { finishAutomaticBattery() }
        }
    }
    public mutating func setPowerCondition(_ condition: PowerCondition) {
        resolveLegacyConfiguration(); settings.powerCondition = condition
        if condition == .battery { setAutomatic(false) }
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
        endTemporarySession()
        mutateMarkers { if $0.pauseReason == nil { $0.pauseReason = .userSleep } }
        userSleepRequestedAt = now; userSleepObserved = false
    }
    /// The UI and command path share the same protection recovery threshold.
    public func canResume(thermal: Int?) -> Bool {
        guard settings.isSupported, latestPower != .unknown, latestFullWake == true, latestControllingUser,
              thermal.map({ (0..<2).contains($0) }) == true else { return false }
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
        mutateMarkers { $0.pauseReason = nil; $0.protectionReason = nil; $0.automaticActivation = nil }
        automaticDuration = nil; automaticStartedAt = nil; batteryDeadline = nil
        userSleepRequestedAt = nil; userSleepObserved = false
        pruneIssuedBatteryPermits()
        return true
    }
    public mutating func endTemporarySession() {
        manual.end(.sessionEnded); automaticActive = false; expiry = nil; decision = WorkSessionDecision()
        if batteryDeadline != nil { finishAutomaticBattery() }
        issuedBatteryPermits.removeAll()
    }
    public mutating func suspendForSystemSleep() { consumeSystemSleep(observedAt: lastEvaluation ?? 0) }
    public mutating func consumeSystemSleep(observedAt: Double) {
        guard observedAt.isFinite, observedAt >= 0 else { return }
        consumeRequests(observedAt: observedAt)
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
           settings.automaticEnabled, settings.condition.includesBattery, automaticDuration != nil,
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
            let cap = min(deadline, observedAt + seconds)
            batteryDeadline = min(batteryDeadline ?? cap, cap)
            automaticStartedAt = min(automaticStartedAt ?? observedAt, observedAt)
            mutateMarkers { $0.automaticActivation?.batteryConsumed = true }
            if now >= cap { finishAutomaticBattery() }
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
              markers.permitsAcquisition, validClock(now), lastThermal.map({ (0..<2).contains($0) }) == true else { return false }
        var accepted = false
        if transition.reasons.contains(.manual) {
            accepted = manual.acceptBatteryTransition(transition, now: now, observedAt: observed)
        }
        if transition.reasons.contains(.automatic), let end = transition.batteryDeadline,
           let activation = markers.automaticActivation, !activation.batteryExpired,
           settings.automaticEnabled, settings.condition.includesBattery, let seconds = automaticDuration {
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
        expiry = nil; automaticActive = false; decision = WorkSessionDecision()
        guard validClock(now) else { return }
        lastEvaluation = now; lastThermal = thermal; latestPower = power; latestBatteryPercent = batteryPercent
        latestFullWake = fullWake; latestControllingUser = controllingUser
        latestLowPowerWarning = lowPowerWarning
        latestLowPowerMode = lowPowerMode
        // Keep the last confirmed source through unknown observations. Every
        // observed AC departure consumes old requests, including battery-origin
        // requests that visited AC. Reconnection never revives a manual request.
        if lastKnownPower == .ac, power == .battery {
            manual.end(.powerDisconnected); consumeRequests(observedAt: now)
        }
        manual.evaluate(power: power, now: now)
        if let end = batteryDeadline, now >= end { finishAutomaticBattery() }
        guard controllingUser else { loseGUIAuthority(); return }
        guard settings.isSupported else { return }
        guard let thermal, (0...3).contains(thermal) else { stopForProtection("sensor"); return }
        if thermal >= 2 { stopForProtection("thermal"); return }
        if power == .unknown { stopForProtection("sensor"); return }
        if fullWake == true, userSleepObserved, markers.pauseReason == .userSleep {
            mutateMarkers { $0.pauseReason = nil }; userSleepRequestedAt = nil; userSleepObserved = false
        }
        // A known false condition is the only natural activation boundary. In
        // both-power mode AC remains true; unknown and edits are not boundaries.
        if power != .unknown {
            observeAutomaticBoundary(power: power)
            lastKnownPower = power
        }
        pruneIssuedBatteryPermits()
        guard settings.enabled, markers.permitsAcquisition, fullWake == true, power != .unknown else { return }
        let advancedAllowed = !settings.v4.usesAdvancedAutomaticConditions
            || (automaticGate?.isSatisfied == true && automaticGate?.validUntil.map({ now < $0 }) == true)
        let automaticEligible = settings.automaticEnabled && power == .ac && advancedAllowed
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
                let condition = settings.condition
                mutateMarkers { $0.automaticActivation = AutomaticActivationMarker(condition: condition) }
                automaticDuration = Double(settings.automaticMinutes * 60)
            }
            if automaticDuration == nil, markers.automaticActivation?.batteryConsumed != true {
                automaticDuration = Double(settings.automaticMinutes * 60)
            }
            if power == .battery, batteryDeadline == nil,
               markers.automaticActivation?.batteryConsumed != true, boot != "unknown",
               let seconds = automaticDuration {
                batteryDeadline = now + seconds; automaticStartedAt = now
                mutateMarkers { $0.automaticActivation?.batteryConsumed = true }
            }
            automaticActive = power == .ac || batteryDeadline.map({ now < $0 }) == true
        }
        var reasons: [WorkSessionReason] = []
        if automaticActive { reasons.append(.automatic) }
        if manual.canHold { reasons.append(.manual) }
        guard !reasons.isEmpty else { return }
        let automaticEnd = automaticActive ? (power == .ac ? nil : batteryDeadline) : nil
        let manualEnd = manual.canHold ? manual.effectiveDeadline : nil
        let unlimited = (automaticActive && power == .ac) || (manual.canHold && manualEnd == nil)
        let final = unlimited ? nil : [automaticEnd, manualEnd].compactMap { $0 }.max()
        expiry = min(now + Self.observationTTL, now + Self.healthTTL, final ?? .infinity)
        if automaticActive, settings.v4.usesAdvancedAutomaticConditions,
           let validUntil = automaticGate?.validUntil { expiry = min(expiry!, validUntil) }
        // A saved battery-only trigger grants no battery scope to AC manual work.
        // An active both-power trigger still approves its first battery transition.
        let manualBatteryAllowed = manual.allowsBattery && power == .battery
        let permitDeadline = manualBatteryAllowed ? manual.batteryDeadline : nil
        let scopes: [PowerSource] = power == .battery ? [.battery] : [.ac]
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
            batteryPermitID: manualBatteryAllowed ? manual.requestID : nil,
            batteryDuration: manualBatteryAllowed ? manual.selectedBatteryDuration : nil,
            batteryDeadline: permitDeadline, powerScopes: scopes,
            displayRequired: settings.keepDisplayAwake && (autoDisplay || (manualKeepDisplayAwake && displayPermitted(manualDisplayIdleLimit))),
            closedLidRequired: settings.allowClosedLid && (autoLid || manualAllowClosedLid))
    }
    private mutating func observeAutomaticBoundary(power: PowerSource) {
        guard var activation = markers.automaticActivation else { return }
        if !eligible(activation.condition, power) {
            activation.conditionEnded = true
            if batteryDeadline != nil { batteryDeadline = nil; automaticStartedAt = nil; activation.batteryExpired = true }
            mutateMarkers { $0.automaticActivation = activation }
        } else if activation.conditionEnded, eligible(settings.condition, power) {
            let condition = settings.condition
            mutateMarkers { $0.automaticActivation = AutomaticActivationMarker(condition: condition) }
            automaticDuration = Double(settings.automaticMinutes * 60); automaticStartedAt = nil; batteryDeadline = nil
        }
    }
    private func eligible(_ condition: PowerCondition, _ power: PowerSource) -> Bool {
        power == .ac
    }
    private func canStart(now: Double) -> Bool {
        settings.isSupported && settings.enabled && permitsExplicitManualStart && validClock(now)
            && lastEvaluation.map({ now - $0 <= Self.observationTTL }) == true
            && latestFullWake == true && latestControllingUser
            && lastThermal.map({ (0..<2).contains($0) }) == true && latestPower != .unknown && batteryAllowsWork
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
        return settings.automaticEnabled && settings.condition.includesBattery
            && !activation.conditionEnded && !activation.batteryExpired && issued.automaticID == activation.id
            && issued.automaticIssuedAt.map({ observedAt >= $0 }) == true
    }
    private mutating func pruneIssuedBatteryPermits() {
        let manualID = manual.allowsBattery ? manual.requestID : nil
        let activation = markers.automaticActivation
        let automaticID = activation?.conditionEnded != true && activation?.batteryExpired != true ? activation?.id : nil
        for (id, var issued) in issuedBatteryPermits {
            if issued.manualID != manualID { issued.manualID = nil; issued.manualIssuedAt = nil }
            if issued.automaticID != automaticID { issued.automaticID = nil; issued.automaticIssuedAt = nil }
            if issued.manualID == nil && issued.automaticID == nil { issuedBatteryPermits.removeValue(forKey: id) }
            else { issuedBatteryPermits[id] = issued }
        }
    }
    private mutating func finishAutomaticBattery() {
        batteryDeadline = nil; automaticStartedAt = nil
        mutateMarkers { if $0.automaticActivation?.batteryConsumed == true { $0.automaticActivation?.batteryExpired = true } }
    }
    private mutating func consumeRequests(observedAt: Double) {
        temporaryConsumptionAt = max(temporaryConsumptionAt ?? observedAt, observedAt)
        if manual.startedAt.map({ $0 <= observedAt }) == true { manual.end(.sessionEnded) }
        if automaticStartedAt.map({ $0 <= observedAt }) == true { finishAutomaticBattery() }
        pruneIssuedBatteryPermits()
    }
    private mutating func stopForProtection(_ reason: String) {
        manual.end(.protection); finishAutomaticBattery(); automaticActive = false; expiry = nil; decision = WorkSessionDecision()
        issuedBatteryPermits.removeAll()
        mutateMarkers { $0.protectionReason = $0.protectionReason ?? reason }
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
