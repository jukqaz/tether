import Foundation

/// Helper bookkeeping that must survive a restart: the hold request being tracked (and when it
/// was first seen, which anchors the 4 h cap), whether it is used up, and the Low Power Mode
/// settings to restore (battery for a hold, AC for the heat guard).
public struct HelperState: Codable, Equatable, Sendable {
    public var appSessionRequired: Bool?
    public var appPID: Int32?
    public var appStarted: UInt64?
    public var appUID: UInt32?
    /// Old state needs a fresh kernel-authenticated app handshake.
    public var guiOwner: GUISessionOwner?
    /// Retained on disconnect, preventing silent transfer to another console user.
    public var controllerUID: UInt32?
    public var holdValue: Double?
    public var holdSeenAt: Double?
    public var consumedHold: Double?
    public var holdContinuousStart: Double?
    public var holdContinuousDeadline: Double?
    /// Manual battery allowance survives restarts; the manual session itself never does.
    public var manualBatteryBudget: ProtectionState?
    /// The app now supplies finite decisions. A restart/downgrade cannot silently
    /// re-enable the legacy autonomous policy before a new authenticated lease.
    public var userSessionCoordinated: Bool?
    public var coordinatedStopPending: Bool?
    /// Enforcement receipt only; the helper never restores this as an active job.
    public var workSessionLease: WorkSessionLease?
    /// A same-boot consumption receipt survives helper restart. It never grants
    /// work or restores the app's temporary sessions.
    public var workSleepConsumption: WorkSessionSleepConsumption?
    /// v3 execution bookkeeping lives beside the existing recovery journals;
    /// no saved request here is restored as a live app decision.
    public var lidExecutionVersion: Int?
    public var batteryPermitReceipts: [WorkSessionBatteryPermitReceipt]?
    public var lidProtection: WorkSessionProtectionLatch?
    public var lidEndReceipt: WorkSessionEndReceipt?
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
