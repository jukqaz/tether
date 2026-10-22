import Foundation

public enum SessionPauseReason: String, Codable, Sendable {
    case userStop, userSleep, ownerEnded
}

/// A spent activation is a stop marker, never a saved timer or a battery ledger.
/// In both-power mode an AC visit is still the same activation.
public struct AutomaticActivationMarker: Codable, Equatable, Sendable {
    public var id: UUID
    public var condition: PowerCondition
    public var batteryConsumed: Bool
    public var batteryExpired: Bool
    public var conditionEnded: Bool
    public init(id: UUID = UUID(), condition: PowerCondition, batteryConsumed: Bool = false,
                batteryExpired: Bool = false, conditionEnded: Bool = false) {
        self.id = id; self.condition = condition; self.batteryConsumed = batteryConsumed
        self.batteryExpired = batteryExpired; self.conditionEnded = conditionEnded
    }
}

/// Durable intent only. Manual requests and live monotonic deadlines are absent.
public struct RuntimeMarkers: Codable, Equatable, Sendable {
    public var pauseReason: SessionPauseReason?
    public var protectionReason: String?
    public var automaticActivation: AutomaticActivationMarker?
    public init(pauseReason: SessionPauseReason? = nil, protectionReason: String? = nil,
                automaticActivation: AutomaticActivationMarker? = nil) {
        self.pauseReason = pauseReason; self.protectionReason = protectionReason
        self.automaticActivation = automaticActivation
    }
    public var permitsAcquisition: Bool { pauseReason == nil && protectionReason == nil }
    public var isSupported: Bool { (protectionReason?.utf8.count ?? 0) <= 256 }
}
