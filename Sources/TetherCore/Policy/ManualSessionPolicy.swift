import Foundation

public enum ManualSessionEnd: String, Codable, Sendable {
    case cancelled, time, batteryBudget, powerDisconnected, protection, sessionEnded, observationUnavailable, taskEnded
}

/// One explicit request with an immutable original battery anchor. The default
/// AC departure consumes it; explicit continuation never creates a new request.
public struct ManualSessionPolicy: Equatable, Sendable {
    public static let batteryMaximum: TimeInterval = 2 * 3600
    /// Numeric conversion bound, not a product limit on AC timed requests.
    public static let maximumTimedDuration = Double(Int.max).nextDown
    public private(set) var active = false
    public private(set) var requestID: UUID?
    public private(set) var extensionID: UUID?
    public private(set) var startedAt: Double?
    public private(set) var requestedDeadline: Double?
    public private(set) var effectiveDeadline: Double?
    public private(set) var batteryDeadline: Double?
    public private(set) var batteryStartedAt: Double?
    public private(set) var endReason: ManualSessionEnd?
    /// The next request's default; changing it cannot change an active request.
    public private(set) var batteryContinuationMinutes: Int?
    public private(set) var activeBatteryContinuationMinutes: Int?
    public private(set) var startedOnBattery = false
    public private(set) var powerCondition: PowerCondition
    public private(set) var batteryLimit: WorkSessionBatteryLimit
    private var disconnectPolicy: WorkSessionDisconnectPolicy
    private let boot: String
    private var power = PowerSource.unknown
    private var lastKnownPower = PowerSource.unknown
    private var lastClock: Double?

    public init(batteryBudget: ProtectionState? = nil, batteryContinuationMinutes: Int? = nil,
                boot: String = ContinuousTime.bootID,
                disconnectPolicy: WorkSessionDisconnectPolicy = .endAll,
                powerCondition: PowerCondition = .any,
                batteryLimit: WorkSessionBatteryLimit = .twoHours) {
        self.boot = boot
        self.disconnectPolicy = disconnectPolicy; self.powerCondition = powerCondition; self.batteryLimit = batteryLimit
        self.batteryContinuationMinutes = Self.validContinuationMinutes(batteryContinuationMinutes) ? batteryContinuationMinutes : nil
        // Legacy consumption is recovery/migration evidence, never a new request.
    }
    public var savedBatteryBudget: ProtectionState? { nil }
    public var canHold: Bool { active && power != .unknown }
    public var allowsBattery: Bool { active && powerCondition.includesBattery
        && (startedOnBattery || disconnectPolicy != .endAll) }
    public var selectedBatteryDuration: Double? {
        guard allowsBattery else { return nil }
        return batteryLimit.seconds
    }
    public mutating func mergeBatteryBudget(_ other: ProtectionState) {}
    public static func validContinuationMinutes(_ minutes: Int?) -> Bool {
        minutes.map { (1...120).contains($0) } ?? true
    }
    @discardableResult
    public mutating func setBatteryContinuationMinutes(_ minutes: Int?, now: Double, user: UserLimits? = nil) -> Bool {
        guard Self.validContinuationMinutes(minutes), validClock(now) else { return false }
        batteryContinuationMinutes = minutes
        return true
    }
    public func batteryRemaining(now: Double, user: UserLimits? = nil) -> Double {
        guard now.isFinite, boot != "unknown", lastClock.map({ now >= $0 }) ?? true else { return 0 }
        return max(0, batteryDeadline.map { $0 - now } ?? batteryLimit.seconds ?? .infinity)
    }
    public func canStart(power: PowerSource, now: Double, user: UserLimits? = nil) -> Bool {
        !active && powerCondition.permits(power) && validClock(now) && (power != .battery || boot != "unknown")
    }
    @discardableResult
    public mutating func start(duration: TimeInterval?, power: PowerSource, now: Double,
                               user: UserLimits? = nil,
                               disconnectPolicy: WorkSessionDisconnectPolicy? = nil,
                               powerCondition: PowerCondition? = nil,
                               batteryLimit: WorkSessionBatteryLimit? = nil) -> Bool {
        guard !active else { return false }
        if let disconnectPolicy { self.disconnectPolicy = disconnectPolicy }
        if let powerCondition { self.powerCondition = powerCondition }
        if let batteryLimit { self.batteryLimit = batteryLimit }
        guard canStart(power: power, now: now, user: user),
              duration.map({ $0.isFinite && $0 > 0 && $0 <= Self.maximumTimedDuration && (now + $0).isFinite }) ?? (power == .ac || self.batteryLimit == .unlimited),
              power != .battery || (duration.map({ $0 >= 60 && $0 <= (self.batteryLimit.seconds ?? .infinity) }) ?? (self.batteryLimit == .unlimited)) else { return false }
        requestID = UUID(); extensionID = nil; startedAt = now; requestedDeadline = duration.map { now + $0 }
        activeBatteryContinuationMinutes = nil
        startedOnBattery = power == .battery; batteryDeadline = nil; batteryStartedAt = nil
        if startedOnBattery { batteryDeadline = self.batteryLimit.seconds.map { now + $0 }; batteryStartedAt = now }
        active = true; endReason = nil
        lastKnownPower = power
        evaluate(power: power, now: now, user: user)
        return active && canHold
    }
    public mutating func evaluate(power: PowerSource, now: Double, user: UserLimits? = nil,
                                  disconnectPolicy: WorkSessionDisconnectPolicy? = nil) {
        guard validClock(now) else { self.power = .unknown; return }
        if let disconnectPolicy { self.disconnectPolicy = disconnectPolicy }
        lastClock = now; self.power = power
        let disconnected = lastKnownPower == .ac && power == .battery
        if power != .unknown { lastKnownPower = power }
        guard active else { effectiveDeadline = nil; return }
        if disconnected && self.disconnectPolicy == .endAll { endSession(.powerDisconnected); return }
        if let end = requestedDeadline, now >= end { endSession(.time); return }
        if power != .unknown && !powerCondition.permits(power) { endSession(.powerDisconnected); return }
        if power == .battery, let end = batteryDeadline, now >= end { endSession(.batteryBudget); return }
        if power == .battery {
            guard allowsBattery else { endSession(.powerDisconnected); return }
            guard boot != "unknown" else { endSession(.observationUnavailable); return }
            if batteryStartedAt == nil {
                batteryStartedAt = now
                batteryDeadline = selectedBatteryDuration.map { now + $0 }
            }
        }
        // An unknown cannot expand an existing battery-limited permission.
        effectiveDeadline = power == .ac ? requestedDeadline : earlier(requestedDeadline, batteryDeadline)
    }
    /// A helper observed the first battery use sooner. ACKs can only shorten the
    /// request that authorized that permit; an AC return cannot remove its cap.
    @discardableResult
    public mutating func acceptBatteryPermit(observedAt: Double, deadline: Double, now: Double,
                                            extensionID: UUID? = nil) -> Bool {
        guard allowsBattery, validClock(now), observedAt.isFinite, observedAt >= (startedAt ?? .infinity),
              observedAt <= now, deadline.isFinite, deadline > observedAt,
              extensionID == self.extensionID else { return false }
        // A helper receipt may tighten this approved deadline, never the fixed
        // first-start ceiling. Old extension receipts cannot shorten a new one.
        if let seconds = batteryLimit.seconds {
            let maximum = observedAt + seconds
            batteryStartedAt = min(batteryStartedAt ?? observedAt, observedAt)
            batteryDeadline = min(batteryDeadline ?? maximum, maximum)
        }
        if deadline < (batteryDeadline ?? .infinity) { requestedDeadline = min(requestedDeadline ?? deadline, deadline) }
        evaluate(power: power, now: now)
        return true
    }
    @discardableResult
    public mutating func acceptBatteryTransition(_ decision: WorkSessionPowerTransition, now: Double,
                                                observedAt: Double, user: UserLimits? = nil) -> Bool {
        false // Opposite-power continuation is decode-only legacy evidence.
    }
    public func canExtend(duration: TimeInterval, now: Double) -> Bool {
        guard active, canHold, validClock(now), duration == 900 || duration == 1800,
              let deadline = requestedDeadline, now < deadline,
              (deadline + duration).isFinite else { return false }
        return power != .battery || (batteryDeadline.map { deadline + duration <= $0 } ?? true)
    }
    @discardableResult
    public mutating func extend(duration: TimeInterval, now: Double, user: UserLimits? = nil) -> Bool {
        guard canExtend(duration: duration, now: now), let deadline = requestedDeadline else { return false }
        requestedDeadline = deadline + duration; extensionID = UUID()
        evaluate(power: power, now: now)
        return active
    }
    public func reschedulingLimit(user: UserLimits? = nil) -> Double? { nil }
    public func reschedulingMaximum(now: Double, user: UserLimits? = nil) -> TimeInterval { 0 }
    @discardableResult
    public mutating func reschedule(duration: TimeInterval, now: Double, user: UserLimits? = nil) -> Bool { false }
    public mutating func end(_ reason: ManualSessionEnd = .cancelled) { endSession(reason) }
    private mutating func endSession(_ reason: ManualSessionEnd) {
        if active { endReason = reason }
        active = false; requestID = nil; extensionID = nil; startedAt = nil; requestedDeadline = nil; effectiveDeadline = nil
        batteryDeadline = nil; batteryStartedAt = nil; activeBatteryContinuationMinutes = nil; startedOnBattery = false
    }
    private func validClock(_ now: Double) -> Bool {
        now.isFinite && now >= 0 && (lastClock.map { now >= $0 } ?? true)
    }
    private func earlier(_ a: Double?, _ b: Double?) -> Double? {
        if let a, let b { return min(a, b) }
        return a ?? b
    }
}

/// Helper observations; a requested session is distinct from confirmed OS application.
public struct ManualSessionStatus: Codable, Equatable, Sendable {
    public var active: Bool
    public var holding: Bool
    public var until: Double?
    public var batteryRemaining: Double
    public var endReason: ManualSessionEnd?
    public var batteryContinuationMinutes: Int?
    public var startedOnBattery: Bool?
    public init(active: Bool, holding: Bool, until: Double?, batteryRemaining: Double,
                endReason: ManualSessionEnd?, batteryContinuationMinutes: Int? = nil, startedOnBattery: Bool? = nil) {
        self.active = active; self.holding = holding; self.until = until
        self.batteryRemaining = batteryRemaining; self.endReason = endReason
        self.batteryContinuationMinutes = batteryContinuationMinutes; self.startedOnBattery = startedOnBattery
    }
}
