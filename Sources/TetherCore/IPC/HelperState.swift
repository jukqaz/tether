import Foundation

/// Helper bookkeeping that must survive a restart: the hold request being tracked (and when it
/// was first seen, which anchors the 4 h cap), whether it is used up, and the Low Power Mode
/// settings to restore (battery for a hold, AC for the heat guard).
public struct HelperState: Codable, Equatable, Sendable {
    public var holdValue: Double?
    public var holdSeenAt: Double?
    public var consumedHold: Double?
    public var savedBatteryLowPower: Int?
    public var savedACLowPower: Int?

    public init(holdValue: Double? = nil, holdSeenAt: Double? = nil, consumedHold: Double? = nil,
                savedBatteryLowPower: Int? = nil, savedACLowPower: Int? = nil) {
        self.holdValue = holdValue
        self.holdSeenAt = holdSeenAt
        self.consumedHold = consumedHold
        self.savedBatteryLowPower = savedBatteryLowPower
        self.savedACLowPower = savedACLowPower
    }

    /// The active hold deadline, or nil when none is armed or it is used up.
    public func holdDeadline(requested: Double?, now: Date,
                             maxHold: TimeInterval = SafetyPolicy.maxHold) -> Date? {
        guard let requested, requested == holdValue, requested != consumedHold,
              let seen = holdSeenAt else { return nil }
        return SafetyPolicy.clamp(Date(timeIntervalSince1970: requested),
                                  now: Date(timeIntervalSince1970: seen), maxHold: maxHold)
    }
}
