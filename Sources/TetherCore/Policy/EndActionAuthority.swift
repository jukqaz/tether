import Foundation

/// A process-local cleanup lineage, never reconstructed from a persisted receipt.
/// Cleanup does not grant work; a terminal effect is issued once only after cleanup.
public struct EndActionAuthority: Equatable, Sendable {
    public static let cleanupWindow: Double = 60
    public static let actionWindow: Double = 15
    public let causeID: UUID
    public let observedAt: Double
    public let cleanupDeadline: Double
    public private(set) var actionID: UUID?
    public private(set) var issuedAt: Double?
    public private(set) var actionDeadline: Double?
    public private(set) var cancelled = false
    public private(set) var consumed = false

    public init(causeID: UUID, observedAt: Double) {
        self.causeID = causeID; self.observedAt = observedAt
        cleanupDeadline = observedAt + Self.cleanupWindow
    }

    public func canCleanUp(now: Double) -> Bool {
        !cancelled && !consumed && actionID == nil && observedAt.isFinite && observedAt >= 0
            && cleanupDeadline.isFinite && cleanupDeadline > observedAt
            && now.isFinite && now >= observedAt && now < cleanupDeadline
    }

    /// A late cleanup, retry, or cancelled lineage cannot mint another action.
    @discardableResult
    public mutating func issue(now: Double) -> Bool {
        guard canCleanUp(now: now), (now + Self.actionWindow).isFinite,
              now + Self.actionWindow > now else { return false }
        actionID = UUID(); issuedAt = now; actionDeadline = now + Self.actionWindow
        return true
    }

    @discardableResult
    public mutating func consume(now: Double) -> Bool {
        guard !consumed, canDispatch(now: now) else { return false }
        consumed = true; return true
    }

    /// Used again at the actual OS call boundary, including after durable writes.
    /// The executor must first consume once and durably record that consumption;
    /// this predicate alone is not permission to dispatch an additional effect.
    public func canDispatch(now: Double) -> Bool {
        !cancelled && actionID != nil && now.isFinite
            && issuedAt.map { now >= $0 } == true
            && actionDeadline.map { $0.isFinite && now < $0 } == true
    }

    public mutating func cancel() { cancelled = true }
}
