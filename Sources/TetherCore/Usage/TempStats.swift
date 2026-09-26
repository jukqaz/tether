import Foundation

/// Time-weighted battery temperatures: how long the pack spent at each whole degree.
public struct TempStats: Codable, Equatable, Sendable {
    public static let lowest = 20
    public static let bucketCount = 30  // 20...49 °C

    public var seconds: Double
    /// Sum of temperature × seconds, for the time-weighted average.
    public var weighted: Double
    public var max: Double?
    /// Seconds spent in each 1 °C bucket from `lowest`; the ends catch everything beyond.
    public var buckets: [Double]

    public init() {
        seconds = 0
        weighted = 0
        max = nil
        buckets = Array(repeating: 0, count: Self.bucketCount)
    }

    public mutating func add(_ temperature: Double, seconds step: Double) {
        guard step > 0 else { return }
        if buckets.count != Self.bucketCount { buckets = Array(repeating: 0, count: Self.bucketCount) }
        seconds += step
        weighted += temperature * step
        max = Swift.max(max ?? temperature, temperature)
        let index = Int(temperature.rounded(.down)) - Self.lowest
        buckets[Swift.min(Self.bucketCount - 1, Swift.max(0, index))] += step
    }

    public mutating func merge(_ other: TempStats) {
        guard other.seconds > 0 else { return }
        if buckets.count != Self.bucketCount { buckets = Array(repeating: 0, count: Self.bucketCount) }
        seconds += other.seconds
        weighted += other.weighted
        if let m = other.max { max = Swift.max(max ?? m, m) }
        for (i, value) in other.buckets.prefix(Self.bucketCount).enumerated() { buckets[i] += value }
    }

    public var average: Double? { seconds > 0 ? weighted / seconds : nil }

    /// The temperature the pack stayed at or below for fraction `p` of the time (the top of the
    /// bucket that reaches it, never above the peak seen).
    public func percentile(_ p: Double) -> Double? {
        guard seconds > 0, let max else { return nil }
        let target = seconds * Swift.min(1, Swift.max(0, p))
        var running = 0.0
        for (i, value) in buckets.enumerated() {
            running += value
            if running >= target { return Swift.min(Double(Self.lowest + i + 1), max) }
        }
        return max
    }
}
