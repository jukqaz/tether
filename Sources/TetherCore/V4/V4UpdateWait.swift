import Foundation

public struct V4UpdateIdentity: Codable, Equatable, Sendable {
    public var version: String
    public var packageIdentity: String
    public var channel: String
    public var settingsGeneration: UInt64
    public init(version: String, packageIdentity: String, channel: String, settingsGeneration: UInt64) {
        self.version = version; self.packageIdentity = packageIdentity; self.channel = channel
        self.settingsGeneration = settingsGeneration
    }
}
public enum V4UpdateWorkKind: String, Codable, Sendable {
    case timedManual, pidManual, unlimitedManual, taskEvent, pendingStart, pendingExtension, simpleAutomatic
}
public enum V4UpdateWorkState: String, Codable, Sendable {
    case active, waiting, idle, completed, failed, cancelled, observationExpired, safetyConsumed
}
public struct V4UpdateWork: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: V4UpdateWorkKind
    public var state: V4UpdateWorkState
    public var hasLinkedProcess: Bool
    public init(id: UUID, kind: V4UpdateWorkKind, state: V4UpdateWorkState, hasLinkedProcess: Bool = false) {
        self.id = id; self.kind = kind; self.state = state; self.hasLinkedProcess = hasLinkedProcess
    }
    public var isWaitTarget: Bool { kind != .simpleAutomatic }
    public var isNormalEnd: Bool { state == .completed || state == .failed || state == .cancelled }
}
public struct V4UpdateSnapshot: Codable, Equatable, Sendable {
    public var context: V4ExecutionContext
    public var identity: V4UpdateIdentity
    public var work: [V4UpdateWork]
    public var packageValidated: Bool
    public var compatible: Bool
    public var restorationPending: Bool
    public var authenticationRequired: Bool
    public init(context: V4ExecutionContext, identity: V4UpdateIdentity, work: [V4UpdateWork],
                packageValidated: Bool, compatible: Bool, restorationPending: Bool = false,
                authenticationRequired: Bool = false) {
        self.context = context; self.identity = identity; self.work = work
        self.packageValidated = packageValidated; self.compatible = compatible
        self.restorationPending = restorationPending; self.authenticationRequired = authenticationRequired
    }
}
public enum V4UpdateWaitState: String, Codable, Sendable {
    case none, waiting, ready, authenticationRequired, confirmationRequired, committing, cancelled, expired
}
public struct V4UpdateWaitResult: Codable, Equatable, Sendable {
    public var state: V4UpdateWaitState
    public var reason: String
    public var waitingFor: [UUID]
}

/// Reservation is not a power permit. No restart, authentication or installer callback is performed here.
public struct V4UpdateWaitEngine: Sendable {
    public private(set) var reservationID: UUID?
    public private(set) var identity: V4UpdateIdentity?
    public private(set) var scope: V4Scope?
    public private(set) var expiresAt: Double?
    public private(set) var state: V4UpdateWaitState = .none
    public private(set) var waitingFor: Set<UUID> = []
    public init() {}
    public var acceptsNewWork: Bool { state != .committing }

    @discardableResult
    public mutating func reserve(id: UUID, snapshot: V4UpdateSnapshot, now: Double) -> V4UpdateWaitResult {
        if reservationID == id {
            guard identity == snapshot.identity, scope == snapshot.context.scope else {
                return .init(state: state, reason: "mismatched-reservation-retry", waitingFor: Array(waitingFor))
            }
            return evaluate(snapshot: snapshot, now: now)
        }
        guard state != .committing else {
            return .init(state: state, reason: "replacement-already-committing", waitingFor: Array(waitingFor))
        }
        guard snapshot.context.permitsWork(at: now), snapshot.context.power == .ac,
              !snapshot.identity.version.isEmpty, !snapshot.identity.packageIdentity.isEmpty,
              snapshot.compatible, (now + 86400).isFinite else {
            return .init(state: .confirmationRequired, reason: "reservation-preflight-failed", waitingFor: [])
        }
        guard !snapshot.work.contains(where: { $0.kind == .unlimitedManual && !$0.hasLinkedProcess && !$0.isNormalEnd }) else {
            return .init(state: .confirmationRequired, reason: "unbounded-manual-has-no-observable-end", waitingFor: [])
        }
        reservationID = id; identity = snapshot.identity; scope = snapshot.context.scope
        expiresAt = now + 86400; waitingFor = []; state = .waiting
        return evaluate(snapshot: snapshot, now: now)
    }

    @discardableResult
    public mutating func evaluate(snapshot: V4UpdateSnapshot, now: Double) -> V4UpdateWaitResult {
        let wasCommitting = state == .committing
        func result(_ reason: String) -> V4UpdateWaitResult {
            .init(state: state, reason: reason, waitingFor: waitingFor.sorted { $0.uuidString < $1.uuidString })
        }
        guard reservationID != nil else { return result("no-reservation") }
        guard state != .cancelled, state != .expired, state != .confirmationRequired else { return result("reservation-not-authorized") }
        guard now.isFinite, let expiresAt, now < expiresAt else { state = .expired; return result("reservation-expired") }
        guard snapshot.context.scope == scope, snapshot.identity == identity else {
            state = .confirmationRequired; return result("reservation-identity-changed")
        }
        guard snapshot.compatible else { state = .confirmationRequired; return result("package-incompatible") }
        guard snapshot.context.permitsWork(at: now), snapshot.context.power == .ac else {
            state = .confirmationRequired; return result("safety-or-owner-consumed-reservation")
        }
        let grouped = Dictionary(grouping: snapshot.work, by: \.id)
        guard grouped.values.allSatisfy({ $0.count == 1 }) else { state = .confirmationRequired; return result("ambiguous-work-identity") }
        let relevant = snapshot.work.filter(\.isWaitTarget)
        if relevant.contains(where: { $0.kind == .unlimitedManual && !$0.hasLinkedProcess && !$0.isNormalEnd }) {
            state = .confirmationRequired; return result("new-unbounded-manual-cancelled-reservation")
        }
        if relevant.contains(where: { $0.state == .observationExpired || $0.state == .safetyConsumed }) {
            state = .confirmationRequired; return result("work-ended-without-completion-proof")
        }
        // Disappearance is not completion. The adapter must report a terminal event for every tracked target.
        if waitingFor.contains(where: { grouped[$0] == nil }) {
            state = .confirmationRequired; return result("tracked-work-disappeared")
        }
        waitingFor = Set(relevant.filter { !$0.isNormalEnd }.map(\.id))
        guard waitingFor.isEmpty else { state = .waiting; return result("waiting-for-work") }
        guard !snapshot.restorationPending else { state = .waiting; return result("own-restoration-pending") }
        guard !snapshot.context.isMacBook || snapshot.context.lidClosed == false else {
            state = .waiting; return result("open-lid-required")
        }
        guard !snapshot.authenticationRequired else { state = .authenticationRequired; return result("user-authentication-required") }
        guard snapshot.packageValidated else { state = .waiting; return result("package-verification-pending") }
        state = wasCommitting ? .committing : .ready
        return result("ready-for-serialized-replacement-boundary")
    }

    @discardableResult
    public mutating func beginReplacement(snapshot: V4UpdateSnapshot, now: Double) -> V4UpdateWaitResult {
        let checked = evaluate(snapshot: snapshot, now: now)
        guard checked.state == .ready || checked.state == .committing else { return checked }
        state = .committing
        return .init(state: .committing, reason: "recheck-immediately-before-termination", waitingFor: [])
    }

    /// Re-run at the actual termination boundary, after asynchronous package/auth/recovery work.
    @discardableResult
    public mutating func finalCheck(snapshot: V4UpdateSnapshot, now: Double) -> V4UpdateWaitResult {
        guard state == .committing else { return .init(state: state, reason: "replacement-not-committed", waitingFor: Array(waitingFor)) }
        return beginReplacement(snapshot: snapshot, now: now)
    }

    public mutating func cancel() {
        state = .cancelled; waitingFor.removeAll()
        reservationID = nil; identity = nil; scope = nil; expiresAt = nil
    }
}
