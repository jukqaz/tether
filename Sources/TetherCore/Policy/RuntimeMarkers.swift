import Foundation

public enum SessionPauseReason: String, Codable, Sendable {
    case userStop, userSleep, ownerEnded
}

/// An automatic-only pause is intent, never execution authority. A deadline
/// belongs to one boot's continuous clock; another boot keeps the pause until
/// explicitly resumed instead of inventing a new deadline or permission.
public struct AutomaticPauseMarker: Codable, Equatable, Sendable {
    public var bootID: String
    public var until: Double?
    public init(bootID: String, until: Double?) { self.bootID = bootID; self.until = until }
    public var isSupported: Bool {
        !bootID.isEmpty && bootID.utf8.count <= 256 && (until.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

/// A spent activation is a stop marker, never a saved timer or a battery ledger.
/// In both-power mode an AC visit is still the same activation.
public struct AutomaticActivationMarker: Codable, Equatable, Sendable {
    public var id: UUID
    public var condition: PowerCondition
    public var batteryConsumed: Bool
    public var batteryExpired: Bool
    public var conditionEnded: Bool
    /// Same-boot execution evidence, never permission to restore work on launch.
    public var batteryStartedAt: Double?
    public var batteryDeadline: Double?
    public var batteryLimit: WorkSessionBatteryLimit?
    public init(id: UUID = UUID(), condition: PowerCondition, batteryConsumed: Bool = false,
                batteryExpired: Bool = false, conditionEnded: Bool = false,
                batteryStartedAt: Double? = nil, batteryDeadline: Double? = nil,
                batteryLimit: WorkSessionBatteryLimit? = nil) {
        self.id = id; self.condition = condition; self.batteryConsumed = batteryConsumed
        self.batteryExpired = batteryExpired; self.conditionEnded = conditionEnded
        self.batteryStartedAt = batteryStartedAt; self.batteryDeadline = batteryDeadline; self.batteryLimit = batteryLimit
    }
}

/// Durable intent only. Manual requests and live monotonic deadlines are absent.
public struct RuntimeMarkers: Codable, Equatable, Sendable {
    public var pauseReason: SessionPauseReason?
    public var protectionReason: String?
    public var automaticActivation: AutomaticActivationMarker?
    public var automaticRestartBlocked: Bool?
    public var automaticPause: AutomaticPauseMarker?
    public init(pauseReason: SessionPauseReason? = nil, protectionReason: String? = nil,
                automaticActivation: AutomaticActivationMarker? = nil, automaticRestartBlocked: Bool? = nil,
                automaticPause: AutomaticPauseMarker? = nil) {
        self.pauseReason = pauseReason; self.protectionReason = protectionReason
        self.automaticActivation = automaticActivation
        self.automaticRestartBlocked = automaticRestartBlocked
        self.automaticPause = automaticPause
    }
    public var permitsAcquisition: Bool { pauseReason == nil && protectionReason == nil }
    public var isSupported: Bool { (protectionReason?.utf8.count ?? 0) <= 256 && (automaticPause?.isSupported ?? true) }
}
