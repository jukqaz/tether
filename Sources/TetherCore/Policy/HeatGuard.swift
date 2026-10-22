import Foundation

/// Legacy wire format only; schema 3 migration removes it.
public struct HeatGuardSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Thermal pressure that turns Low Power Mode on: 1 fair, 2 serious.
    public var level: Int

    public static let standard = HeatGuardSettings(enabled: true, level: 2)

    public init(enabled: Bool, level: Int) {
        self.enabled = enabled
        self.level = level
    }

    /// Only fair or serious make sense: critical is too late to start cooling.
    public var threshold: Int { min(2, max(1, level)) }
}
