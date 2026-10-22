import Foundation

public enum V4CommandDisposition: String, Codable, Sendable {
    case accepted, alreadyProcessed, rejected, limited, unknown
}
public enum V4WorkEventKind: String, Codable, Sendable {
    /// Actual task start, not discovery of an open REPL/editor.
    case start, working, waiting, idle, heartbeat, finished, failed, cancelled
}
public enum V4WorkEvidence: String, Codable, Sendable { case direct, ownedCommand, externalPID, estimated }
public enum V4WorkState: String, Codable, Sendable { case working, waiting, idle, ended, expired, revoked }

public struct V4WorkEvent: Codable, Equatable, Sendable {
    public var jobID: UUID
    public var eventID: UUID
    public var sequence: UInt64
    public var scope: V4Scope
    public var producerID: String
    public var kind: V4WorkEventKind
    public var evidence: V4WorkEvidence
    public var ttl: Double
    public var fixedDeadline: Double?
    public var exitCode: Int32?
    public init(jobID: UUID, eventID: UUID, sequence: UInt64, scope: V4Scope, producerID: String,
                kind: V4WorkEventKind, evidence: V4WorkEvidence = .direct, ttl: Double = 120,
                fixedDeadline: Double? = nil, exitCode: Int32? = nil) {
        self.jobID = jobID; self.eventID = eventID; self.sequence = sequence; self.scope = scope
        self.producerID = producerID; self.kind = kind; self.evidence = evidence; self.ttl = ttl
        self.fixedDeadline = fixedDeadline; self.exitCode = exitCode
    }
}

public struct V4WorkRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var scope: V4Scope
    public var producerID: String
    public var evidence: V4WorkEvidence
    public var state: V4WorkState
    public var createdAt: Double
    public var updatedAt: Double
    public var ttl: Double
    public var fixedDeadline: Double?
    public var waitingSince: Double?
    public var lastSequence: UInt64
    public var lastEventID: UUID
    public var endReason: String?
    public var exitCode: Int32?
    public var isTerminal: Bool { state == .ended || state == .expired || state == .revoked }
    public var expiry: Double {
        var expiry = updatedAt + ttl
        if let deadline = fixedDeadline { expiry = min(expiry, deadline) }
        if state == .waiting, let waitingSince { expiry = min(expiry, waitingSince + 300) }
        return expiry
    }
}

public struct V4WorkEventResult: Codable, Equatable, Sendable {
    public var disposition: V4CommandDisposition
    public var reason: String
    public var record: V4WorkRecord?
}

/// In-memory ledger. The app serializes calls; there are no timers, observers, files or process actions here.
/// Terminal IDs remain tombstones for this ledger lifetime. Capacity rejects new IDs rather than forgetting revocations.
public struct V4WorkEventStore: Sendable {
    public private(set) var records: [UUID: V4WorkRecord] = [:]
    private var lastEvents: [UUID: V4WorkEvent] = [:]
    public let maximumRecords: Int
    public init(maximumRecords: Int = 1024) { self.maximumRecords = max(1, maximumRecords) }

    @discardableResult
    public mutating func apply(_ event: V4WorkEvent, context: V4ExecutionContext, now: Double) -> V4WorkEventResult {
        reconcile(context: context, now: now)
        func response(_ disposition: V4CommandDisposition, _ reason: String) -> V4WorkEventResult {
            .init(disposition: disposition, reason: reason, record: records[event.jobID])
        }
        guard now.isFinite, event.scope == context.scope, event.scope.isValid,
              !event.producerID.isEmpty, event.producerID.count <= 128,
              event.ttl.isFinite, event.ttl > 0,
              event.fixedDeadline.map(\.isFinite) != false else {
            return response(.rejected, "invalid-event")
        }
        if let record = records[event.jobID] {
            if record.lastEventID == event.eventID && record.lastSequence == event.sequence {
                return lastEvents[event.jobID] == event ? response(.alreadyProcessed, "already-processed")
                    : response(.rejected, "mismatched-event-replay")
            }
            guard !record.isTerminal else { return response(.rejected, "consumed-job") }
            guard record.scope == event.scope, record.producerID == event.producerID,
                  event.sequence > record.lastSequence, event.eventID != record.lastEventID,
                  event.evidence == record.evidence,
                  event.fixedDeadline == nil || event.fixedDeadline == record.fixedDeadline else {
                return response(.rejected, "stale-or-mismatched-event")
            }
            guard event.kind != .start else { return response(.rejected, "job-already-started") }
        } else {
            guard event.kind == .start else { return response(.rejected, "unknown-job") }
            guard event.fixedDeadline.map({ $0 > now }) != false else { return response(.rejected, "expired-fixed-deadline") }
            guard records.count < maximumRecords else { return response(.limited, "ledger-capacity") }
        }
        guard context.permitsAutomatic(at: now) else { return response(.rejected, "automatic-gate-blocked") }
        var record = records[event.jobID] ?? V4WorkRecord(id: event.jobID, scope: event.scope,
            producerID: event.producerID, evidence: event.evidence, state: .working,
            createdAt: now, updatedAt: now, ttl: min(300, max(1, event.ttl)),
            fixedDeadline: event.fixedDeadline, waitingSince: nil,
            lastSequence: event.sequence, lastEventID: event.eventID, endReason: nil, exitCode: nil)
        // A heartbeat can refresh liveness only. Deadline, TTL, identity and state are immutable through it.
        switch event.kind {
        case .start, .working:
            record.state = .working; record.waitingSince = nil
        case .waiting:
            if record.state != .waiting { record.waitingSince = now }
            record.state = .waiting
        case .idle:
            record.state = .idle; record.waitingSince = nil
        case .heartbeat: break
        case .finished, .failed, .cancelled:
            record.state = .ended; record.waitingSince = nil; record.endReason = event.kind.rawValue
            // External PID disappearance or an estimated state is never an exit-status oracle.
            record.exitCode = record.evidence == .ownedCommand ? event.exitCode : nil
        }
        record.updatedAt = now; record.lastSequence = event.sequence; record.lastEventID = event.eventID
        records[event.jobID] = record
        lastEvents[event.jobID] = event
        return response(.accepted, "accepted")
    }

    public mutating func reconcile(context: V4ExecutionContext, now: Double) {
        guard now.isFinite else { return }
        for id in records.keys {
            guard var record = records[id], !record.isTerminal else { continue }
            if record.scope != context.scope || !context.permitsAutomatic(at: now) {
                record.state = .revoked; record.endReason = "scope-or-gate-consumed"
            } else if now >= record.expiry {
                record.state = .expired
                record.endReason = record.waitingSince.map { now >= $0 + 300 } == true ? "waiting-expired" : "observation-expired"
            } else { continue }
            records[id] = record
        }
    }

    public mutating func consumeAll(reason: String) {
        for id in records.keys {
            guard var record = records[id], !record.isTerminal else { continue }
            record.state = .revoked; record.endReason = String(reason.prefix(128)); records[id] = record
        }
    }

    public func gate(context: V4ExecutionContext, now: Double, producerID: String? = nil) -> V4AutomaticGate {
        guard context.permitsAutomatic(at: now) else { return .init(isSatisfied: false, validUntil: nil, reason: "automatic-gate-blocked") }
        let deadlines = records.values.filter {
            $0.scope == context.scope && ($0.state == .working || $0.state == .waiting)
                && $0.expiry > now && (producerID == nil || $0.producerID == producerID)
        }.map { min($0.expiry, context.validUntil) }
        return .init(isSatisfied: !deadlines.isEmpty, validUntil: deadlines.max(), reason: deadlines.isEmpty ? "no-active-work" : "work-events")
    }

    public func observation(for condition: V4Condition, context: V4ExecutionContext, now: Double) -> V4Observation {
        let target = condition.target
        let matching = records.values.filter { target.isEmpty || $0.producerID == target || $0.id.uuidString == target }
        let active = matching.filter { $0.scope == context.scope && ($0.state == .working || $0.state == .waiting) && $0.expiry > now }
        let deadline = active.map(\.expiry).max()
        let state: V4ObservationState = context.permitsAutomatic(at: now) && deadline != nil ? .satisfied
            : matching.contains(where: { $0.state == .expired }) ? .unknown : .notSatisfied
        return .init(conditionID: condition.id, scope: context.scope, state: state,
                     observedAt: now, validUntil: min(context.validUntil, deadline ?? context.validUntil))
    }
}

public struct V4ProcessIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startIdentity: UInt64
    public var executableIdentity: String
    public init(pid: Int32, startIdentity: UInt64, executableIdentity: String) {
        self.pid = pid; self.startIdentity = startIdentity; self.executableIdentity = executableIdentity
    }
    public var isValid: Bool { pid > 1 && startIdentity > 0 && executableIdentity.hasPrefix("/") }
}
public enum V4ProcessPresence: String, Codable, Sendable { case alive, gone, unknown }
public enum V4PIDResult: String, Codable, Sendable { case running, processEnded, identityChanged, observationUnavailable, deadlineExpired }
public struct V4PIDBinding: Codable, Equatable, Sendable {
    public var identity: V4ProcessIdentity
    public var scope: V4Scope
    public var fixedDeadline: Double?
    public init(identity: V4ProcessIdentity, scope: V4Scope, fixedDeadline: Double?) {
        self.identity = identity; self.scope = scope; self.fixedDeadline = fixedDeadline
    }
    public func evaluate(presence: V4ProcessPresence, observed: V4ProcessIdentity?,
                         observedUntil: Double, context: V4ExecutionContext, now: Double) -> V4PIDResult {
        guard context.scope == scope, context.permitsWork(at: now), identity.isValid,
              observedUntil.isFinite, observedUntil > now else { return .observationUnavailable }
        if let fixedDeadline, !fixedDeadline.isFinite || now >= fixedDeadline { return .deadlineExpired }
        if presence == .gone { return .processEnded }
        guard presence == .alive, let observed else { return .observationUnavailable }
        return observed == identity ? .running : .identityChanged
    }
}

public struct V4DownloadSample: Codable, Equatable, Sendable {
    public var scope: V4Scope
    public var partialNames: [String]
    public var lastProgressAt: Double?
    public var observedAt: Double
    public var validUntil: Double
    public var querySucceeded: Bool
    public init(scope: V4Scope, partialNames: [String], lastProgressAt: Double?, observedAt: Double,
                validUntil: Double, querySucceeded: Bool = true) {
        self.scope = scope; self.partialNames = partialNames; self.lastProgressAt = lastProgressAt
        self.observedAt = observedAt; self.validUntil = validUntil; self.querySucceeded = querySucceeded
    }
}

public struct V4DownloadTracker: Sendable {
    public private(set) var lastEvidenceAt: Double?
    private var scope: V4Scope?
    public init() {}
    public static func isSupportedPartial(_ name: String) -> Bool {
        ["crdownload", "download", "part"].contains((name as NSString).pathExtension.lowercased())
    }
    public mutating func evaluate(_ sample: V4DownloadSample, context: V4ExecutionContext,
                                  now: Double) -> V4ObservationState {
        if scope != context.scope { lastEvidenceAt = nil; scope = context.scope }
        guard context.permitsAutomatic(at: now) else { lastEvidenceAt = nil; return .notSatisfied }
        guard sample.querySucceeded, sample.scope == context.scope, sample.observedAt.isFinite,
              sample.validUntil.isFinite, sample.observedAt <= now, now < sample.validUntil else { return .unknown }
        let partials = sample.partialNames.filter(Self.isSupportedPartial)
        if !partials.isEmpty {
            guard let progress = sample.lastProgressAt, progress.isFinite, progress <= now,
                  now - progress < 300 else { lastEvidenceAt = nil; return .unknown }
            lastEvidenceAt = now
            return .satisfied
        }
        if let lastEvidenceAt, now >= lastEvidenceAt, now - lastEvidenceAt < 30 { return .satisfied }
        return .notSatisfied // no completion/success claim
    }
}
