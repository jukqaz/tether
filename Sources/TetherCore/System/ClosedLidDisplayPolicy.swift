import Foundation

/// This choice affects only the built-in panel during an authorized closed-lid
/// session. It never changes screen-lock policy or authorizes a work session.
public enum ClosedLidDisplayMode: String, Codable, CaseIterable, Sendable {
    case off, zeroBrightness, unchanged
}

public struct ClosedLidDisplayTarget: Codable, Equatable, Sendable {
    public var id: UInt32
    public var vendor: UInt32
    public var model: UInt32
    public init(id: UInt32, vendor: UInt32, model: UInt32) {
        self.id = id; self.vendor = vendor; self.model = model
    }
}

public enum ClosedLidDisplayIssue: String, Codable, Equatable, Sendable {
    case privateAPIUnavailable, unsupportedSystem, topologyUnavailable
    case externalDisplayPresent, builtInDisplayUnavailable, brightnessReadUnavailable
    case brightnessWriteFailed, readbackMismatch, journalUnavailable, recoveryTargetUnavailable
}

/// A successful symbol lookup and read is a capability candidate, not proof of
/// panel power, closed-lid behavior, remote frames, or compatibility on this Mac.
public struct ClosedLidDisplaySupport: Equatable, Sendable {
    public enum Availability: String, Sendable { case unavailable, candidateRequiresPhysicalValidation }
    public var availability: Availability
    public var target: ClosedLidDisplayTarget?
    public var issue: ClosedLidDisplayIssue?
    public var canAttemptZeroBrightness: Bool {
        availability == .candidateRequiresPhysicalValidation && target != nil && issue == nil
    }
    public var requiresPhysicalValidation: Bool { true }
    public init(availability: Availability, target: ClosedLidDisplayTarget? = nil,
                issue: ClosedLidDisplayIssue? = nil) {
        self.availability = availability; self.target = target; self.issue = issue
    }
}

public enum ClosedLidDisplayState: Equatable, Sendable {
    case inactive, brightnessZero, unchanged, deferred, userChangePreserved
    case unavailable(ClosedLidDisplayIssue)
    case recoveryPending(ClosedLidDisplayIssue)
}

/// The native adapter must address this exact built-in target on every read and
/// write. Unknown targets and external outputs must never inherit its authority.
public protocol ClosedLidDisplayBrightnessBackend: AnyObject {
    var support: ClosedLidDisplaySupport { get }
    func read(target: ClosedLidDisplayTarget) -> Float?
    func write(_ brightness: Float, target: ClosedLidDisplayTarget) -> Bool
}

public struct ClosedLidDisplayRecoveryRecord: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case prepared, applied, restoring, relinquished }
    public var version = 1
    public var target: ClosedLidDisplayTarget
    public var original: Float
    public var applied: Float
    public var phase: Phase
    public init(target: ClosedLidDisplayTarget, original: Float, applied: Float = 0,
                phase: Phase = .prepared) {
        self.target = target; self.original = original; self.applied = applied; self.phase = phase
    }
    public var isValid: Bool {
        version == 1 && target.id != 0 && original.isFinite && (0...1).contains(original)
            && applied == 0
    }
}

/// Stores the original durably BEFORE a write, and removes it only after a
/// confirmed restore or a recorded handoff to a subsequent user/other-app value.
public protocol ClosedLidDisplayRecoveryJournaling: AnyObject {
    func load() throws -> ClosedLidDisplayRecoveryRecord?
    func save(_ record: ClosedLidDisplayRecoveryRecord) throws
    func remove() throws
}
