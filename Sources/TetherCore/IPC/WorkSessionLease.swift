import Foundation

public enum WorkSessionReason: String, Codable, Hashable, Sendable { case automatic, manual }

public enum WorkSessionEndAction: String, Codable, Sendable { case followOS, sleepIfClosed }

/// App-approved execution scope. The helper never derives a scope from saved
/// automatic settings or starts a new battery request on the app's behalf.
public struct WorkSessionLidPermit: Codable, Equatable, Sendable {
    public var powerScopes: [PowerSource]
    public var batteryPermitID: UUID?
    public var batteryDuration: Double?
    public var batteryDeadline: Double?
    public var disconnectAction: WorkSessionEndAction
    public var protectiveAction: WorkSessionEndAction
    public var batteryMaximumDeadline: Double?
    public var extensionID: UUID?
    public var batteryTimeLimit: WorkSessionBatteryLimit?
    public init(powerScopes: [PowerSource], batteryPermitID: UUID? = nil,
                batteryDuration: Double? = nil, batteryDeadline: Double? = nil,
                disconnectAction: WorkSessionEndAction = .sleepIfClosed,
                protectiveAction: WorkSessionEndAction = .sleepIfClosed,
                batteryMaximumDeadline: Double? = nil, extensionID: UUID? = nil,
                batteryTimeLimit: WorkSessionBatteryLimit? = nil) {
        self.powerScopes = powerScopes; self.batteryPermitID = batteryPermitID
        self.batteryDuration = batteryDuration; self.batteryDeadline = batteryDeadline
        self.disconnectAction = disconnectAction; self.protectiveAction = protectiveAction
        self.batteryMaximumDeadline = batteryMaximumDeadline; self.extensionID = extensionID
        self.batteryTimeLimit = batteryTimeLimit
    }
    public func isValid(now: Double, source: PowerSource, batteryLimit: WorkSessionBatteryLimit = .twoHours) -> Bool {
        guard now.isFinite, !powerScopes.isEmpty, powerScopes.count <= 2,
              !powerScopes.contains(.unknown), Set(powerScopes).count == powerScopes.count,
              powerScopes.contains(source) else { return false }
        if powerScopes.contains(.battery) {
            guard batteryPermitID != nil else { return false }
            let selected = batteryTimeLimit ?? batteryLimit
            if let cap = selected.seconds {
                guard let duration = batteryDuration, duration.isFinite, duration > 0, duration <= cap,
                      batteryDeadline.map({ $0.isFinite && (source == .ac || $0 > now) }) ?? (source == .ac),
                      batteryMaximumDeadline.map({ maximum in maximum.isFinite
                          && (source == .ac || maximum > now)
                          && (batteryDeadline.map { $0 <= maximum } ?? true) }) ?? true else { return false }
            } else {
                guard batteryTimeLimit == .unlimited || batteryLimit == .unlimited,
                      batteryDuration.map({ $0.isFinite && $0 > 0 }) ?? true,
                      batteryDeadline.map({ $0.isFinite && (source == .ac || $0 > now) }) ?? true,
                      batteryMaximumDeadline.map({ $0.isFinite && (source == .ac || $0 > now) }) ?? true else { return false }
            }
        } else if batteryPermitID != nil || batteryDuration != nil || batteryDeadline != nil
            || batteryMaximumDeadline != nil || batteryTimeLimit != nil { return false }
        return true
    }
}

/// First helper-observed battery use of a one-use permit. Same-permit refreshes
/// can shorten this deadline; power round trips and process restarts cannot renew it.
public struct WorkSessionBatteryPermitReceipt: Codable, Equatable, Sendable {
    public var bootID: String
    public var sessionID: UUID
    public var permitID: UUID
    public var observedAt: Double
    public var deadline: Double
    public var extensionID: UUID?
    public var maximumDeadline: Double?
    public var batteryTimeLimit: WorkSessionBatteryLimit?
    public init(bootID: String, sessionID: UUID, permitID: UUID, observedAt: Double, deadline: Double,
                extensionID: UUID? = nil, maximumDeadline: Double? = nil,
                batteryTimeLimit: WorkSessionBatteryLimit? = nil) {
        self.bootID = bootID; self.sessionID = sessionID; self.permitID = permitID
        self.observedAt = observedAt; self.deadline = deadline
        self.extensionID = extensionID; self.maximumDeadline = maximumDeadline
        self.batteryTimeLimit = batteryTimeLimit
    }
    public func isValid(boot: String) -> Bool {
        boot != "unknown" && !boot.isEmpty && bootID == boot && observedAt.isFinite && observedAt >= 0
            && deadline.isFinite && deadline > observedAt
            && ((batteryTimeLimit ?? .twoHours).seconds.map { deadline <= observedAt + $0 } ?? true)
    }
}

/// Preparing an extension does not increase either executor's current authority.
public struct WorkSessionExtensionPreparation: Codable, Equatable, Sendable {
    public var id: UUID
    public var requestID: UUID
    public var currentDeadline: Double
    public var proposedDeadline: Double
    public var expiresAt: Double
    public init(id: UUID, requestID: UUID, currentDeadline: Double, proposedDeadline: Double, expiresAt: Double) {
        self.id = id; self.requestID = requestID; self.currentDeadline = currentDeadline
        self.proposedDeadline = proposedDeadline; self.expiresAt = expiresAt
    }
    public func isValid(now: Double, maximumDeadline: Double? = nil) -> Bool {
        let addition = proposedDeadline - currentDeadline
        return now.isFinite && currentDeadline.isFinite && proposedDeadline.isFinite && expiresAt.isFinite
            && (addition == 900 || addition == 1800) && now < expiresAt && expiresAt <= currentDeadline
            && expiresAt <= now + 5 && currentDeadline > now
            && (maximumDeadline.map { $0.isFinite && proposedDeadline <= $0 } ?? true)
    }
    public func matches(current: WorkSessionLease, incoming: WorkSessionLease, now: Double) -> Bool {
        isValid(now: now, maximumDeadline: current.power == .battery ? (current.manualBatteryMaximumDeadline ?? current.lidPermit?.batteryMaximumDeadline) : nil)
            && current.sessionID == incoming.sessionID && current.reasons.contains(.manual)
            && incoming.reasons.contains(.manual) && current.manualRequestID == requestID
            && incoming.manualRequestID == requestID && current.manualDeadline == currentDeadline
            && incoming.manualDeadline == currentDeadline
            && current.manualExtensionID == incoming.manualExtensionID
    }
}

public struct WorkSessionExtensionPreparationReceipt: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var sequence: UInt64
    public var observedAt: Double
    public var preparation: WorkSessionExtensionPreparation
    public init(sessionID: UUID, sequence: UInt64, observedAt: Double,
                preparation: WorkSessionExtensionPreparation) {
        self.sessionID = sessionID; self.sequence = sequence; self.observedAt = observedAt
        self.preparation = preparation
    }
    public func isValid(now: Double) -> Bool {
        sequence > 0 && observedAt.isFinite && observedAt <= now
            && preparation.isValid(now: now) && preparation.expiresAt <= observedAt + 5
    }
    public func permitsCommit(current: WorkSessionLease, incoming: WorkSessionLease, now: Double) -> Bool {
        isValid(now: now) && current.sessionID == sessionID && incoming.sessionID == sessionID
            && current.sequence >= sequence && incoming.sequence > current.sequence
            && current.reasons.contains(.manual) && incoming.reasons.contains(.manual)
            && current.manualRequestID == preparation.requestID && incoming.manualRequestID == preparation.requestID
            && current.manualDeadline == preparation.currentDeadline
            && incoming.manualDeadline == preparation.proposedDeadline && incoming.manualExtensionID == preparation.id
            && incoming.extensionPreparation == nil
            && preparation.isValid(now: now, maximumDeadline: current.power == .battery ? (current.manualBatteryMaximumDeadline ?? current.lidPermit?.batteryMaximumDeadline) : nil)
    }
}

public struct WorkSessionProtectionLatch: Codable, Equatable, Sendable {
    public var id: UUID
    public var bootID: String
    public var reason: String
    public var observedAt: Double
    public var sessionID: UUID
    public var sequence: UInt64
    public init(id: UUID = UUID(), bootID: String, reason: String, observedAt: Double,
                sessionID: UUID, sequence: UInt64) {
        self.id = id; self.bootID = bootID; self.reason = reason; self.observedAt = observedAt
        self.sessionID = sessionID; self.sequence = sequence
    }
}

/// One terminal action in the existing helper journal. `consumed` is recorded
/// before an OS call, so a crash/restart cannot replay that call as a new incident.
/// Command acceptance is deliberately separate from an observed OS Sleep.
public struct WorkSessionEndReceipt: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case disconnect, batteryExpired, taskEnded, protection, user }
    public enum Phase: String, Codable, Sendable { case captured, restored, consumed }
    public var id: UUID
    public var bootID: String
    public var sessionID: UUID
    public var sequence: UInt64
    public var observedAt: Double
    public var kind: Kind
    public var action: WorkSessionEndAction
    public var phase: Phase
    public var outcome: String?
    public var observedSleepAt: Double?
    /// Optional evidence only. Restart never reconstructs execution permission.
    public var cleanupDeadline: Double?
    public var actionID: UUID?
    public var actionIssuedAt: Double?
    public var actionDeadline: Double?
    public init(id: UUID = UUID(), bootID: String, sessionID: UUID, sequence: UInt64,
                observedAt: Double, kind: Kind, action: WorkSessionEndAction) {
        self.id = id; self.bootID = bootID; self.sessionID = sessionID; self.sequence = sequence
        self.observedAt = observedAt; self.kind = kind; self.action = action; self.phase = .captured
    }
}

/// Decode-only legacy opposite-power metadata. It remains available for old
/// journals and observations, but the v4 gate never projects it into live work.
public struct WorkSessionPowerTransition: Codable, Equatable, Sendable {
    public var token: UUID
    public var issuedAt: Double
    public var power: PowerSource
    public var expiry: Double
    public var reasons: [WorkSessionReason]
    public var manualDeadline: Double?
    public var batteryDeadline: Double?
    public var manualBudgetStart: Double?
    public var automaticBudgetStart: Double?
    public init(token: UUID, issuedAt: Double, power: PowerSource, expiry: Double,
                reasons: [WorkSessionReason], manualDeadline: Double?, batteryDeadline: Double?,
                manualBudgetStart: Double?, automaticBudgetStart: Double?) {
        self.token = token; self.issuedAt = issuedAt; self.power = power; self.expiry = expiry
        self.reasons = reasons; self.manualDeadline = manualDeadline; self.batteryDeadline = batteryDeadline
        self.manualBudgetStart = manualBudgetStart; self.automaticBudgetStart = automaticBudgetStart
    }
    public func isValid(source: PowerSource, parentExpiry: Double, now: Double) -> Bool {
        guard source != .unknown, power != .unknown, source != power,
              issuedAt.isFinite, issuedAt >= 0, issuedAt <= now, expiry.isFinite,
              expiry > now, expiry <= parentExpiry, expiry <= issuedAt + IdleSessionPolicy.healthTTL,
              !reasons.isEmpty, reasons.count <= 2, Set(reasons).count == reasons.count,
              [manualDeadline, batteryDeadline].allSatisfy({ $0.map { $0.isFinite && $0 > issuedAt } ?? true }),
              [manualBudgetStart, automaticBudgetStart].allSatisfy({ $0.map { $0.isFinite && $0 >= 0 && $0 <= issuedAt } ?? true }) else { return false }
        if power == .battery {
            if reasons.contains(.manual), manualDeadline == nil || manualBudgetStart == nil { return false }
            if reasons.contains(.automatic), batteryDeadline == nil || automaticBudgetStart == nil { return false }
        }
        return true
    }
    public func activeReasons(now: Double) -> [WorkSessionReason] {
        guard now.isFinite, now < expiry else { return [] }
        return reasons.filter {
            $0 == .manual ? manualDeadline.map { now < $0 } ?? (power == .ac)
                : (power == .ac || (batteryDeadline.map { now < $0 } ?? false))
        }
    }
}

/// Root observation of an already-approved transition, not a new start command.
public struct WorkSessionPowerTransitionReceipt: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var sequence: UInt64
    public var observedAt: Double
    public var decision: WorkSessionPowerTransition
    public init(sessionID: UUID, sequence: UInt64, observedAt: Double, decision: WorkSessionPowerTransition) {
        self.sessionID = sessionID; self.sequence = sequence; self.observedAt = observedAt; self.decision = decision
    }
    /// A past observation can consume an old reservation, but cannot authorize
    /// present root work. The actual observation must be inside the finite grant.
    public func isValidObservation(now: Double) -> Bool {
        sequence > 0 && now.isFinite && observedAt.isFinite && observedAt >= decision.issuedAt && observedAt <= now
            && decision.isValid(source: decision.power == .ac ? .battery : .ac,
                                parentExpiry: decision.expiry, now: observedAt)
    }
    public func isValid(now: Double) -> Bool {
        isValidObservation(now: now)
            && decision.isValid(source: decision.power == .ac ? .battery : .ac,
                                parentExpiry: decision.expiry, now: now)
    }
}

/// Same-boot observation of authority consumed by the OS sleep boundary. The
/// app acknowledges this only after consuming pre-existing temporary intent.
public struct WorkSessionSleepConsumption: Codable, Equatable, Sendable {
    public var version = 1
    public var id: UUID
    public var bootID: String
    public var sessionID: UUID
    /// Zero means that only a preparation, rather than a work grant, existed.
    public var sequence: UInt64
    public var observedAt: Double
    public var continuationToken: UUID?
    public init(id: UUID = UUID(), bootID: String = ContinuousTime.bootID, sessionID: UUID, sequence: UInt64, observedAt: Double,
                continuationToken: UUID? = nil) {
        self.id = id; self.bootID = bootID; self.sessionID = sessionID; self.sequence = sequence
        self.observedAt = observedAt; self.continuationToken = continuationToken
    }
    public func isValid(sessionID: UUID, sequence: UInt64, now: Double, boot: String = ContinuousTime.bootID) -> Bool {
        version == 1 && boot != "unknown" && bootID == boot && self.sessionID == sessionID && self.sequence <= sequence
            && observedAt.isFinite && observedAt >= 0 && now.isFinite && observedAt <= now
    }
}

/// Fixed product settings only. No paths, executable names, display or lock writes.
public struct WorkSessionConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var automaticEnabled: Bool
    public var condition: PowerCondition
    public var automaticMinutes: Int
    public var limits: UserLimits?
    public var manualBatteryContinuationMinutes: Int?
    public var disconnectPolicy: WorkSessionDisconnectPolicy?
    public var batteryTimeLimit: WorkSessionBatteryLimit?
    public var manualPowerCondition: PowerCondition?
    public var startAutomaticOnBatteryDisconnect: Bool?
    public var stopOnSeriousThermal: Bool?
    public var stopOnLowPowerMode: Bool?
    public var effectiveDisconnectPolicy: WorkSessionDisconnectPolicy { disconnectPolicy ?? .endAll }
    public var effectiveBatteryTimeLimit: WorkSessionBatteryLimit { batteryTimeLimit ?? .twoHours }
    public var effectiveManualPowerCondition: PowerCondition { manualPowerCondition ?? .any }
    public init(settings: IdleSessionSettings) {
        enabled = settings.enabled; automaticEnabled = settings.automaticEnabled
        condition = settings.condition; automaticMinutes = settings.automaticMinutes; limits = settings.limits
        manualBatteryContinuationMinutes = settings.manualBatteryContinuationMinutes
        disconnectPolicy = settings.disconnectPolicy; batteryTimeLimit = settings.batteryTimeLimit
        manualPowerCondition = settings.manualPowerCondition
        startAutomaticOnBatteryDisconnect = settings.startAutomaticOnBatteryDisconnect
        stopOnSeriousThermal = settings.stopOnSeriousThermal
        stopOnLowPowerMode = settings.v4.stopOnLowPowerMode
    }
    public var isSupported: Bool {
        var settings = IdleSessionSettings()
        settings.limits = limits; settings.automaticHoldMinutes = automaticMinutes
        settings.manualBatteryContinuationMinutes = manualBatteryContinuationMinutes
        return settings.isSupported
    }
}

/// A finite, same-boot work decision from the attached app. The helper verifies
/// caller identity, current observations and its own retained battery budgets.
public struct WorkSessionLease: Codable, Equatable, Sendable {
    public static let coordinatorVersion = 10
    public var version = 1
    /// Missing in old installed clients; never enables the v3 executor by accident.
    public var executionVersion: Int?
    public var sessionID: UUID
    public var sequence: UInt64
    public var power: PowerSource
    public var expiry: Double?
    public var reasons: [WorkSessionReason]
    public var manualDeadline: Double?
    public var manualRequestID: UUID?
    public var manualExtensionID: UUID?
    public var manualBatteryMaximumDeadline: Double?
    public var automaticRequestID: UUID?
    public var automaticBatteryDeadline: Double?
    public var manualPowerCondition: PowerCondition?
    public var manualBatteryTimeLimit: WorkSessionBatteryLimit?
    public var automaticBatteryTimeLimit: WorkSessionBatteryLimit?
    public var automaticPowerCondition: PowerCondition?
    public var effectiveManualPowerCondition: PowerCondition { manualPowerCondition ?? configuration.effectiveManualPowerCondition }
    public var effectiveManualBatteryTimeLimit: WorkSessionBatteryLimit { manualBatteryTimeLimit ?? configuration.effectiveBatteryTimeLimit }
    public var effectiveAutomaticBatteryTimeLimit: WorkSessionBatteryLimit { automaticBatteryTimeLimit ?? configuration.effectiveBatteryTimeLimit }
    public var effectiveAutomaticPowerCondition: PowerCondition { automaticPowerCondition ?? configuration.condition }
    public var extensionPreparation: WorkSessionExtensionPreparation?
    public var extensionRollbackID: UUID?
    public var manualTaskEndRequestID: UUID?
    /// Legacy origin evidence, never permission to survive a later AC departure.
    public var manualStartedOnBattery: Bool?
    public var powerTransition: WorkSessionPowerTransition?
    /// Identity of a live direct continuation, including an AC reservation with
    /// no current holding reason. This can retain an observation, never grant work.
    public var continuationToken: UUID?
    /// Fresh epoch/revision preparation alone cannot prove that the app consumed
    /// an OS sleep event. Missing/old acknowledgement cannot restore old intent.
    public var sleepConsumptionID: UUID?
    public var lidPermit: WorkSessionLidPermit?
    /// Missing in older payloads means the existing display-off policy. A new
    /// client requires coordinatorVersion 10 so an old helper cannot ignore a
    /// zero-brightness/unchanged choice and send an all-display sleep command.
    public var closedLidDisplayMode: ClosedLidDisplayMode?
    public var effectiveClosedLidDisplayMode: ClosedLidDisplayMode { closedLidDisplayMode ?? .off }
    public var endConsumptionID: UUID?
    /// A GUI-first power end can preserve the previously approved AC incident.
    /// This is never a grant or a Sleep command; old clients omit it safely.
    public var disconnectEndRequested: Bool?
    /// The observed latch ID, supplied only for an explicit safe Resume command.
    public var protectionResumeID: UUID?
    public var configuration: WorkSessionConfiguration
    public init(sessionID: UUID, sequence: UInt64, power: PowerSource, expiry: Double?,
                reasons: [WorkSessionReason], manualDeadline: Double? = nil, settings: IdleSessionSettings,
                powerTransition: WorkSessionPowerTransition? = nil, continuationToken: UUID? = nil,
                sleepConsumptionID: UUID? = nil, manualStartedOnBattery: Bool? = nil,
                lidPermit: WorkSessionLidPermit? = nil, endConsumptionID: UUID? = nil,
                protectionResumeID: UUID? = nil, executionVersion: Int? = 3,
                disconnectEndRequested: Bool? = nil, manualRequestID: UUID? = nil,
                manualExtensionID: UUID? = nil, extensionPreparation: WorkSessionExtensionPreparation? = nil,
                extensionRollbackID: UUID? = nil, manualBatteryMaximumDeadline: Double? = nil,
                manualTaskEndRequestID: UUID? = nil, automaticRequestID: UUID? = nil,
                automaticBatteryDeadline: Double? = nil, manualPowerCondition: PowerCondition? = nil,
                manualBatteryTimeLimit: WorkSessionBatteryLimit? = nil,
                automaticBatteryTimeLimit: WorkSessionBatteryLimit? = nil,
                automaticPowerCondition: PowerCondition? = nil,
                closedLidDisplayMode: ClosedLidDisplayMode = .off) {
        self.sessionID = sessionID; self.sequence = sequence; self.power = power
        self.expiry = expiry; self.reasons = reasons; self.manualDeadline = manualDeadline
        self.manualStartedOnBattery = manualStartedOnBattery
        self.manualRequestID = manualRequestID; self.manualExtensionID = manualExtensionID
        self.manualBatteryMaximumDeadline = manualBatteryMaximumDeadline
        self.extensionPreparation = extensionPreparation
        self.extensionRollbackID = extensionRollbackID
        self.manualTaskEndRequestID = manualTaskEndRequestID
        self.automaticRequestID = automaticRequestID; self.automaticBatteryDeadline = automaticBatteryDeadline
        self.manualPowerCondition = manualPowerCondition; self.manualBatteryTimeLimit = manualBatteryTimeLimit
        self.automaticBatteryTimeLimit = automaticBatteryTimeLimit; self.automaticPowerCondition = automaticPowerCondition
        configuration = WorkSessionConfiguration(settings: settings)
        self.powerTransition = powerTransition
        self.continuationToken = continuationToken
        self.sleepConsumptionID = sleepConsumptionID
        self.lidPermit = lidPermit; self.endConsumptionID = endConsumptionID
        self.closedLidDisplayMode = closedLidDisplayMode
        self.disconnectEndRequested = disconnectEndRequested
        self.protectionResumeID = protectionResumeID; self.executionVersion = executionVersion
    }
    public func isValid(now: Double) -> Bool {
        guard version == 1, sequence > 0, configuration.isSupported, now.isFinite,
              executionVersion == nil || executionVersion == 3,
              Set(reasons).count == reasons.count, reasons.count <= 2,
              manualDeadline.map({ $0.isFinite }) ?? true else { return false }
        if disconnectEndRequested == true,
           executionVersion != 3 || !reasons.isEmpty || power != .battery || !configuration.enabled { return false }
        if let continuationToken {
            guard configuration.enabled,
                  powerTransition.map({ $0.token == continuationToken }) ?? true else { return false }
        }
        if reasons.isEmpty { return expiry == nil && lidPermit == nil }
        if reasons.contains(.automatic) {
            guard configuration.automaticEnabled, effectiveAutomaticPowerCondition.permits(power) else { return false }
            if power == .battery {
                guard configuration.disconnectPolicy != nil, automaticRequestID != nil,
                      effectiveAutomaticBatteryTimeLimit == .unlimited
                        || automaticBatteryDeadline.map({ $0.isFinite && now < $0 }) == true else { return false }
            }
        }
        if reasons.contains(.manual), !effectiveManualPowerCondition.permits(power) { return false }
        if let maximum = manualBatteryMaximumDeadline {
            guard maximum.isFinite, power == .ac || maximum > now,
                  effectiveManualBatteryTimeLimit.seconds.map({ power == .ac || maximum <= now + $0 }) ?? true else { return false }
        }
        if let preparation = extensionPreparation {
            guard reasons.contains(.manual), preparation.requestID == manualRequestID,
                  preparation.currentDeadline == manualDeadline,
                  preparation.isValid(now: now, maximumDeadline: power == .battery ? (manualBatteryMaximumDeadline ?? lidPermit?.batteryMaximumDeadline) : nil) else { return false }
        }
        guard configuration.enabled, power != .unknown, let expiry, expiry.isFinite,
              expiry > now, expiry <= now + IdleSessionPolicy.healthTTL else { return false }
        if let manualDeadline, reasons.contains(.manual), manualDeadline <= now { return false }
        if power == .battery, reasons.contains(.manual), manualDeadline == nil, effectiveManualBatteryTimeLimit != .unlimited { return false }
        if manualStartedOnBattery == true, reasons.contains(.manual), manualDeadline == nil, effectiveManualBatteryTimeLimit != .unlimited { return false }
        if let lidPermit, executionVersion != 3 || !lidPermit.isValid(now: now, source: power, batteryLimit: configuration.effectiveBatteryTimeLimit) { return false }
        if let lidPermit, lidPermit.extensionID != nil, lidPermit.extensionID != manualExtensionID { return false }
        if let powerTransition, !powerTransition.isValid(source: power, parentExpiry: expiry, now: now) { return false }
        if executionVersion == 3, powerTransition != nil { return false }
        if let transition = powerTransition, transition.reasons.contains(.manual) {
            guard reasons.contains(.manual) else { return false }
            // On AC this is the actual user deadline. A battery parent can instead
            // carry a consumed-time cap that valid AC work is allowed to remove.
            if power == .ac, let manualDeadline {
                guard let targetDeadline = transition.manualDeadline, targetDeadline <= manualDeadline else { return false }
            }
            if transition.power == .battery {
                guard manualStartedOnBattery == true || configuration.manualBatteryContinuationMinutes != nil,
                      let targetDeadline = transition.manualDeadline, let budgetStart = transition.manualBudgetStart,
                      targetDeadline <= budgetStart + min(ManualSessionPolicy.batteryMaximum, SafetyPolicy.maxHold(configuration.limits)) else { return false }
                if manualStartedOnBattery != true, let minutes = configuration.manualBatteryContinuationMinutes,
                   targetDeadline > transition.issuedAt + Double(minutes * 60) { return false }
            }
        }
        return true
    }
}

/// A bounded preparation receipt, never an active work grant. The root service
/// keeps legacy execution unchanged until a verified native decision is attached.
public struct WorkSessionPreparation: Codable, Equatable, Sendable {
    public var version = 1
    public var sessionID: UUID
    public var epoch: String
    public var revision: UInt64
    public var expiresAt: Double
    public init(sessionID: UUID, epoch: String, revision: UInt64, expiresAt: Double) {
        self.sessionID = sessionID; self.epoch = epoch; self.revision = revision; self.expiresAt = expiresAt
    }
    public func isValid(sessionID: UUID, epoch: String, revision: UInt64, now: Double) -> Bool {
        version == 1 && self.sessionID == sessionID && self.epoch == epoch && self.revision == revision
            && !epoch.isEmpty && epoch.utf8.count <= 256 && now.isFinite && expiresAt.isFinite
            && now < expiresAt && expiresAt <= now + IdleSessionPolicy.healthTTL
    }
}

public struct WorkSessionLeaseGate: Equatable, Sendable {
    public private(set) var current: WorkSessionLease?
    public private(set) var transitionReceipt: WorkSessionPowerTransitionReceipt?
    private var lastKnownPower: PowerSource?
    private var consumedOnDisconnect = false
    private var consumedManual = false
    private var consumedManualRequestID: UUID?
    public init() {}
    @discardableResult
    public mutating func accept(_ lease: WorkSessionLease, now: Double, attaching: Bool = false) -> Bool {
        // Old payloads remain decodable for release/recovery, but their active
        // grants lack the durable revocation protocol required across restart.
        guard lease.isValid(now: now), lease.reasons.isEmpty || lease.executionVersion == 3 else { return false }
        if let previous = current {
            guard lease.sessionID == previous.sessionID, lease.sequence > previous.sequence else { return false }
            // A heartbeat/default edit is not approval to widen a live request.
            // Deadline extensions use their separate preparation/commit protocol;
            // the original battery anchor, captured scope and cap stay unchanged.
            if let id = lease.manualRequestID, previous.manualRequestID == id {
                guard lease.effectiveManualPowerCondition == previous.effectiveManualPowerCondition,
                      lease.effectiveManualBatteryTimeLimit == previous.effectiveManualBatteryTimeLimit else { return false }
                if let maximum = previous.manualBatteryMaximumDeadline {
                    guard lease.manualBatteryMaximumDeadline.map({ $0 <= maximum }) == true else { return false }
                }
            }
            if let id = lease.automaticRequestID, previous.automaticRequestID == id {
                guard lease.effectiveAutomaticPowerCondition == previous.effectiveAutomaticPowerCondition,
                      lease.effectiveAutomaticBatteryTimeLimit == previous.effectiveAutomaticBatteryTimeLimit else { return false }
                if let maximum = previous.automaticBatteryDeadline {
                    guard lease.automaticBatteryDeadline.map({ $0 <= maximum }) == true else { return false }
                }
            }
        } else if !attaching { return false }
        let departsAC = lastKnownPower == .ac && lease.power == .battery
        let disconnect = current?.configuration.effectiveDisconnectPolicy ?? .endAll
        if lease.reasons.contains(.manual) {
            if consumedManual, lease.manualRequestID == consumedManualRequestID { return false }
            if departsAC, disconnect == .endAll {
                guard let requestID = lease.manualRequestID,
                      requestID != current?.manualRequestID else { return false }
            }
        }
        if departsAC { consumeForDisconnect() }
        // Retain the received payload as evidence, but old opposite-power fields
        // never grant work or produce a new transition receipt in v4.
        transitionReceipt = nil
        consumedOnDisconnect = false
        if !lease.reasons.isEmpty { lastKnownPower = lease.power }
        current = lease; return true
    }
    public func reasons(now: Double, power: PowerSource) -> [WorkSessionReason] {
        guard now.isFinite, let current, let expiry = current.expiry,
              now < expiry, power != .unknown else { return [] }
        let policy = current.configuration.effectiveDisconnectPolicy
        let crossing = current.power != power
        if crossing, current.power == .ac, power == .battery, policy == .endAll { return [] }
        return current.reasons.filter {
            switch $0 {
            case .automatic:
                return (!consumedOnDisconnect || policy == .continueEligible)
                    && (!crossing || policy == .continueEligible)
                    && current.configuration.automaticEnabled && current.effectiveAutomaticPowerCondition.permits(power)
                    && (power != .battery || current.effectiveAutomaticBatteryTimeLimit == .unlimited
                        || current.automaticBatteryDeadline.map { now < $0 } == true
                        || (crossing && current.power == .ac && current.automaticBatteryDeadline == nil
                            && current.automaticRequestID != nil && current.lidPermit?.batteryPermitID == current.automaticRequestID
                            && current.lidPermit?.powerScopes.contains(.battery) == true
                            && current.lidPermit?.isValid(now: now, source: .ac,
                                batteryLimit: current.effectiveAutomaticBatteryTimeLimit) == true))
            case .manual:
                return (!consumedOnDisconnect || policy != .endAll)
                    && current.effectiveManualPowerCondition.permits(power)
                    && (current.manualDeadline.map { now < $0 } ?? true)
                    && (power != .battery || current.manualBatteryMaximumDeadline.map { now < $0 } ?? true)
            }
        }
    }
    public mutating func observeTransition(now: Double, power: PowerSource) {
        guard now.isFinite, power != .unknown else { return }
        if lastKnownPower == .ac, power == .battery { consumeForDisconnect() }
        lastKnownPower = power
        transitionReceipt = nil
    }
    private mutating func consumeForDisconnect() {
        consumedOnDisconnect = true
        if current?.configuration.effectiveDisconnectPolicy == .endAll, current?.reasons.contains(.manual) == true {
            consumedManual = true
            consumedManualRequestID = current?.manualRequestID
        }
    }
    public mutating func end() {
        current = nil; transitionReceipt = nil; lastKnownPower = nil
        consumedOnDisconnect = false; consumedManual = false; consumedManualRequestID = nil
    }
}

/// Read-only migration evidence, not an active job or a root ownership journal.
public struct WorkSessionBridge: Codable, Equatable, Sendable {
    public var version = 1
    public var coordinated: Bool
    public var automaticBudget: ProtectionState
    public var manualBudget: ProtectionState?
    public var stopRequested: Bool
    public var powerTransition: WorkSessionPowerTransitionReceipt?
    public var sleepConsumption: WorkSessionSleepConsumption?
    public var batteryPermitReceipt: WorkSessionBatteryPermitReceipt?
    /// Retained same-session/boot evidence, not authority. Optional for old helpers.
    public var batteryPermitReceipts: [WorkSessionBatteryPermitReceipt]?
    public var lidProtection: WorkSessionProtectionLatch?
    public var lidEndReceipt: WorkSessionEndReceipt?
    public var extensionPreparationReceipt: WorkSessionExtensionPreparationReceipt?
    public init(coordinated: Bool, automaticBudget: ProtectionState, manualBudget: ProtectionState?, stopRequested: Bool = false) {
        self.coordinated = coordinated; self.automaticBudget = automaticBudget; self.manualBudget = manualBudget
        self.stopRequested = stopRequested
    }
    /// Root lid/display/ownership failures cannot cancel an independently verified
    /// general idle request. Charge, thermal and consumed-time protection applies to both.
    public static func generalWorkBlockReason(_ reason: String?) -> String? {
        guard let reason, ["thermal", "battery", "sensor", "time", "budget", "lowPowerMode"].contains(reason) else { return nil }
        return reason
    }
}
