import Foundation

/// One product decision, projected to the native assertion and optional lid
/// executor. The executor receives this authorization rather than trigger settings.
public struct WorkSessionDecision: Equatable, Sendable {
    public var reasons: [WorkSessionReason]
    public var generalAssertionRequired: Bool
    public var expiry: Double?
    public var finalDeadline: Double?
    public var manualDeadline: Double?
    public var automaticBatteryDeadline: Double?
    public var batteryPermitID: UUID?
    public var batteryDuration: Double?
    public var batteryDeadline: Double?
    public var powerScopes: [PowerSource]
    public var displayRequired: Bool
    public var closedLidRequired: Bool
    public init(reasons: [WorkSessionReason] = [], expiry: Double? = nil,
                finalDeadline: Double? = nil, manualDeadline: Double? = nil,
                automaticBatteryDeadline: Double? = nil, batteryPermitID: UUID? = nil,
                batteryDuration: Double? = nil, batteryDeadline: Double? = nil,
                powerScopes: [PowerSource] = [], displayRequired: Bool = false, closedLidRequired: Bool = false) {
        self.reasons = reasons; generalAssertionRequired = !reasons.isEmpty && expiry != nil
        self.expiry = expiry; self.finalDeadline = finalDeadline; self.manualDeadline = manualDeadline
        self.automaticBatteryDeadline = automaticBatteryDeadline; self.batteryPermitID = batteryPermitID
        self.batteryDuration = batteryDuration; self.batteryDeadline = batteryDeadline; self.powerScopes = powerScopes
        self.displayRequired = displayRequired; self.closedLidRequired = closedLidRequired
    }
}
