import Foundation

public enum V4ChargerTrendState: String, Codable, Sendable { case unavailable, collecting, stable, warning }
public struct V4ChargerTrendResult: Codable, Equatable, Sendable {
    public var state: V4ChargerTrendState
    public var warningActive: Bool
    public var shouldNotify: Bool
    public var didRecover: Bool
    public var netDecrease: Int?
    public var sampleCount: Int
    public var observedSpan: Double
    public var reason: String
}

/// Read-only AC trend guidance. This value has no work-session, charging or Sleep authority.
public struct V4ChargerTrend: Sendable {
    public static let window: Double = 600
    public static let maximumGap: Double = 120
    public static let minimumSamples = 6
    public static let minimumDecrease = 3
    private struct Sample: Sendable { var at: Double; var percent: Int }
    private var samples: [Sample] = []
    private var lastInputAt: Double?
    private var warningAt: Double?
    public private(set) var warningActive = false
    private let maximumSamples = 1024
    public init() {}

    /// A missing interval is not recovery. Preserve an already-announced episode until new evidence recovers it.
    public mutating func resetAfterSleepOrWake() {
        samples.removeAll(); lastInputAt = nil
    }

    public mutating func observe(at now: Double, power: V4Power, batteryPercent: Int?) -> V4ChargerTrendResult {
        func result(_ state: V4ChargerTrendState, _ reason: String, notify: Bool = false,
                    recovered: Bool = false, decrease: Int? = nil, span: Double = 0) -> V4ChargerTrendResult {
            .init(state: state, warningActive: warningActive, shouldNotify: notify, didRecover: recovered,
                  netDecrease: decrease, sampleCount: samples.count, observedSpan: span, reason: reason)
        }
        guard now.isFinite, now >= 0 else {
            samples.removeAll(); lastInputAt = nil
            return result(.unavailable, "invalid-clock")
        }
        if let lastInputAt, now < lastInputAt {
            samples.removeAll(); self.lastInputAt = nil
            return result(.unavailable, "clock-regressed")
        }
        // A confirmed source change always ends the AC window, even when two callbacks share one timestamp.
        guard power == .ac else {
            samples.removeAll(); lastInputAt = now
            if power == .battery || power == .ups { warningActive = false; warningAt = nil }
            return result(.unavailable, power == .unknown ? "power-unavailable" : "ac-segment-ended")
        }
        // Repeated updates at one timestamp cannot fabricate six independent observations or refresh freshness.
        if lastInputAt == now { return result(.unavailable, "duplicate-timestamp") }
        let gap = lastInputAt.map { now - $0 > Self.maximumGap } ?? false
        lastInputAt = now
        guard let percent = batteryPercent, (0...100).contains(percent) else {
            samples.removeAll()
            return result(.unavailable, "battery-unavailable")
        }
        if gap { samples.removeAll() }
        samples.append(.init(at: now, percent: percent))
        let cutoff = now - Self.window
        // Keep the latest real observation at/before the boundary. Do not interpolate invented battery readings.
        if let anchor = samples.lastIndex(where: { $0.at <= cutoff }), anchor > 0 { samples.removeFirst(anchor) }
        if samples.count > maximumSamples {
            // Preserve the real anchor plus recent samples while keeping a fixed memory bound.
            samples.removeSubrange(1..<(samples.count - maximumSamples + 1))
        }
        guard let first = samples.first, now - first.at >= Self.window,
              samples.count >= Self.minimumSamples else {
            return result(.collecting, gap ? "observation-gap" : "insufficient-observations")
        }
        let span = now - first.at, decrease = first.percent - percent
        if warningActive {
            guard let warningAt, first.at >= warningAt, decrease <= 0 else {
                return result(.warning, "already-announced-episode", decrease: decrease, span: span)
            }
            warningActive = false; self.warningAt = nil
            samples = [.init(at: now, percent: percent)]
            return result(.stable, "fresh-window-recovered", recovered: true, decrease: decrease, span: span)
        }
        if decrease >= Self.minimumDecrease {
            warningActive = true; warningAt = now
            return result(.warning, "ac-battery-net-decrease", notify: true, decrease: decrease, span: span)
        }
        return result(.stable, "no-warning-trend", decrease: decrease, span: span)
    }
}
