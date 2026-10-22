import Foundation

/// Protection changes only, never power commands or proof of OS Sleep.
/// Disabled notices are consumed. Startup seeds the current state without replaying it.
public struct SessionNotificationEvents: Sendable {
    public struct Choices: Sendable {
        public var thermal: Bool
        public var battery: Bool
        public init(thermal: Bool, battery: Bool) {
            self.thermal = thermal; self.battery = battery
        }
    }
    public enum Event: Equatable, Sendable {
        case protection(String)
    }
    private var previous: UserSessionStatus?
    public init() {}

    public mutating func observe(_ status: UserSessionStatus, choices: Choices,
                                 now: Double = ContinuousTime.now) -> [Event] {
        guard now.isFinite, now >= 0 else { return [] }
        defer { previous = status }
        guard let previous, previous.blockReason != status.blockReason,
              let reason = status.blockReason,
              previous.holding || previous.manualActive || previous.automaticActive else { return [] }
        if ["thermal", "sensor"].contains(reason), choices.thermal { return [.protection(reason)] }
        if reason == "battery", choices.battery { return [.protection(reason)] }
        // Time/budget exhaustion remains in state and logs, without a notification.
        return []
    }
}
