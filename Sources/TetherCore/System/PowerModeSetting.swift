import Foundation

/// pmset uses 0/1 on low-power-only Macs, and 0/1/2 when High Power Mode is supported.
/// Preserve the complete original mode, including High Power, when temporarily reducing heat.
public struct PowerModeSetting: Equatable, Sendable {
    public enum Key: String, Sendable { case lowpowermode, powermode }
    public let key: Key
    public let value: Int
    public init(key: Key, value: Int) { self.key = key; self.value = value }
    public func arguments(onBattery: Bool, value: Int) -> [String]? {
        guard (0...(key == .powermode ? 2 : 1)).contains(value) else { return nil }
        return [onBattery ? "-b" : "-c", key.rawValue, String(value)]
    }
}
