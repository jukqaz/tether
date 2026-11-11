import Foundation

/// Best-effort journal, not exclusive ownership of macOS's global setting.
public struct PowerOwnership: Codable, Equatable, Sendable {
    public var owned = false
    public var boot = ContinuousTime.bootID
    public var appliedAt: Double?
    public init() {}
    public var valid: Bool { isValid(for: ContinuousTime.bootID) }
    public func isValid(for currentBoot: String) -> Bool { boot == currentBoot && !boot.isEmpty && boot != "unknown" }
    @discardableResult
    public mutating func acquire(boot: String = ContinuousTime.bootID) -> Bool {
        guard !boot.isEmpty, boot != "unknown" else { return false }
        owned = true; self.boot = boot; appliedAt = Date().timeIntervalSince1970
        return true
    }
    public mutating func release() { owned = false; appliedAt = nil }
}

public enum DisplayTopology: String, Codable, Sendable {
    case none, externalUnverified, virtualOnly, externalWithVirtual, unknown
    /// Includes virtual outputs: an all-display sleep command would affect them too.
    public var mayHaveExternal: Bool { self != .none }
    /// Unknown outputs remain conservative; a confirmed virtual-only setup is not a
    /// physical monitor that can supply native closed-lid operation.
    public var mayHavePhysicalExternal: Bool { self != .none && self != .virtualOnly }
    public var title: String {
        switch self {
        case .none: L("No external display", "외부 화면 없음")
        case .externalUnverified: L("Additional display connected", "추가 화면 연결")
        case .virtualOnly: L("Remote virtual displays connected", "원격용 가상 화면 연결")
        case .externalWithVirtual: L("Additional and virtual displays connected", "추가 화면·가상 화면 연결")
        case .unknown: L("Display configuration unavailable", "화면 구성 확인 불가")
        }
    }
}

/// Recover transient display wakes without an unbounded fight with another app.
/// Requests are spaced and capped per incident. Only sustained, sampled sleep finishes one.
public struct DisplaySleepGate {
    /// Engineering observation/retry budget, not a hardware safety threshold.
    public static let acknowledgementWindow: TimeInterval = 10
    public static let maximumRequests = 3
    public static let stableSleepWindow: TimeInterval = 60
    public static let maximumObservationGap: TimeInterval = 10
    private var requestedAt: Double?
    private var confirmed = false
    private var awakeSince: Double?
    private var stopped = false
    private var asleepSince: Double?
    private var previousObservation: Double?
    public private(set) var phase: Phase = .inactive
    public enum Phase: String, Codable, Sendable { case inactive, checking, recovering, asleep, unavailable, stopped, deferred }
    public private(set) var requestCount = 0
    public private(set) var unavailableSince: Double?
    public init() {}
    public enum Decision: Equatable { case none, request, conflict }
    public var pending: Bool { !stopped && ((requestedAt != nil && !confirmed) || awakeSince != nil || unavailableSince != nil) }
    public mutating func reset() { self = Self() }
    public mutating func stop() { stopped = true; phase = .stopped }
    /// A foreign display request or unavailable request query defers all-display commands.
    /// Preserve the incident's request budget instead of replenishing it on every reconnect.
    public mutating func deferRequests() {
        guard !stopped else { return }
        requestedAt = nil; confirmed = false; awakeSince = nil; unavailableSince = nil
        asleepSince = nil; phase = .deferred
    }
    public mutating func evaluate(eligible: Bool, sleeping: Bool?, now: Double) -> Decision {
        guard eligible else { reset(); return .none }
        guard !stopped, now.isFinite, previousObservation.map({ now >= $0 }) ?? true else {
            stopped = true; phase = .stopped; return .conflict
        }
        if previousObservation.map({ now - $0 > Self.maximumObservationGap }) ?? true { asleepSince = nil }
        previousObservation = now
        if sleeping == true {
            confirmed = true; awakeSince = nil; unavailableSince = nil
            phase = .asleep
            if asleepSince == nil { asleepSince = now }
            if now - (asleepSince ?? now) >= Self.stableSleepWindow {
                requestCount = 0; requestedAt = nil
            }
            return .none
        }
        asleepSince = nil
        if sleeping == nil {
            phase = .unavailable
            // Missing observations are not known wakes and do not warrant retries.
            if unavailableSince == nil { unavailableSince = confirmed ? now : (requestedAt ?? now) }
            // An unavailable panel observation is not proof that a display is lit.
            // It must not trigger an all-display sleep request.
            if now - (unavailableSince ?? now) >= Self.acknowledgementWindow {
                stopped = true; phase = .stopped; return .conflict
            }
            return .none
        }
        unavailableSince = nil
        phase = requestCount > 0 ? .recovering : .checking
        if requestedAt == nil && !confirmed { return request(at: now) }
        if awakeSince == nil { awakeSince = confirmed ? now : requestedAt }
        guard now - (awakeSince ?? now) >= Self.acknowledgementWindow else { return .none }
        guard requestCount < Self.maximumRequests else { stopped = true; phase = .stopped; return .conflict }
        return request(at: now)
    }

    private mutating func request(at now: Double) -> Decision {
        guard requestCount < Self.maximumRequests else { stopped = true; phase = .stopped; return .conflict }
        requestedAt = now; awakeSince = now; requestCount += 1
        if phase != .unavailable { phase = .recovering }
        return .request
    }
}

/// Two independent observations spanning the normal 30 s safety poll are required.
/// This conservative engineering window is not a calibrated USB-C transition threshold.
public struct StablePowerGate: Equatable, Sendable {
    public static let confirmationInterval: Double = 30
    private var acSince: Double?
    public private(set) var confirmedAC = false
    public init() {}
    public mutating func observe(_ power: PowerSource, now: Double) -> Bool {
        guard power == .ac else { acSince = nil; confirmedAC = false; return false }
        guard let since = acSince else { acSince = now; return false }
        confirmedAC = now - since >= Self.confirmationInterval
        return confirmedAC
    }
}
