import Foundation

/// A local join key, deliberately excluding serial numbers, EDID and display names.
public struct DisplayIdentity: Codable, Equatable, Sendable {
    public let id: UInt32
    public let vendor: UInt32
    public let model: UInt32
    public init(_ display: DisplayObservation) {
        id = display.id; vendor = display.vendor; model = display.model
    }
}

/// A matched wired connection is a candidate, not proof of native closed-lid operation.
/// USB software outputs, wireless outputs, names and unmatched profile rows cannot qualify.
public struct NativeDisplayEvidence: Equatable, Sendable {
    public let identities: [DisplayIdentity]
    public let wired: [DisplayIdentity]

    public init?(report: DisplayReport) {
        guard report.graphicsAvailable,
              let identities = Self.identities(report.displays.map(\.observation)) else { return nil }
        let wired = report.displays.filter {
            !$0.observation.builtIn && $0.profileMatched && $0.kind == .wired
        }.map { DisplayIdentity($0.observation) }
        guard !wired.isEmpty else { return nil }
        self.identities = identities; self.wired = wired
    }

    /// The built-in panel can disappear from the online list when the lid closes. Its
    /// presence/resolution is not part of an external connection's identity.
    public static func identities(_ observations: [DisplayObservation]?) -> [DisplayIdentity]? {
        guard let observations, !observations.isEmpty,
              Set(observations.map(\.id)).count == observations.count else { return nil }
        return observations.filter { !$0.builtIn }.map(DisplayIdentity.init).sorted { $0.id < $1.id }
    }

    public func matches(_ observations: [DisplayObservation]?) -> Bool {
        guard Self.identities(observations) == identities, let observations else { return false }
        return observations.contains {
            !$0.builtIn && $0.active && wired.contains(DisplayIdentity($0))
        }
    }

    public func available(snapshot: Snapshot, observations: [DisplayObservation]?, causesSleep: Bool?) -> Bool {
        snapshot.power == .ac && snapshot.observedFullWake == true
            && snapshot.observedSleepDisabled == false && snapshot.observedLidClosed != nil
            && causesSleep == false && matches(observations)
    }
}

/// One profiler request per current display setup, off the helper's main queue. An old
/// asynchronous result cannot restore evidence after a display/wake transition.
public struct NativeDisplayProbeCache: Sendable {
    public private(set) var evidence: NativeDisplayEvidence?
    public private(set) var pending = false
    private var generation: UInt64 = 0
    private var requested: [DisplayIdentity]?
    public init() {}

    public mutating func invalidate() {
        generation &+= 1; evidence = nil; requested = nil; pending = false
    }

    public mutating func begin(observations: [DisplayObservation]?, power: PowerSource, fullWake: Bool) -> UInt64? {
        guard power == .ac, fullWake, let observations,
              let identities = NativeDisplayEvidence.identities(observations), !identities.isEmpty,
              observations.contains(where: { !$0.builtIn && $0.providerHint == nil }) else {
            if requested != nil { invalidate() }
            return nil
        }
        guard requested != identities else { return nil }
        generation &+= 1; requested = identities; evidence = nil; pending = true
        return generation
    }

    @discardableResult
    public mutating func complete(generation: UInt64, report: DisplayReport,
                                  observations: [DisplayObservation]?) -> Bool {
        guard generation == self.generation, pending else { return false }
        pending = false
        guard requested == NativeDisplayEvidence.identities(observations) else {
            requested = nil; evidence = nil; return false
        }
        guard requested == NativeDisplayEvidence.identities(report.displays.map(\.observation)) else {
            // A failed profiler-side graphics capture must not cause another expensive
            // query on every timer tick while the cheap live list is unchanged.
            evidence = nil; return false
        }
        evidence = NativeDisplayEvidence(report: report)
        return true
    }
}

/// A failed open-lid trial does not repeatedly toggle a global power setting on timer ticks.
/// The next lid opening, power return, wake or actual display transition permits a new trial.
public struct NativeClamshellHandoffGate: Sendable {
    private var attempted = false
    public init() {}
    public mutating func reset() { attempted = false }
    public mutating func begin(snapshot: Snapshot, allowed: Bool, ownsOverride: Bool) -> Bool {
        if snapshot.lidClosed || snapshot.power != .ac { attempted = false }
        guard !attempted, allowed, ownsOverride, snapshot.observedSleepDisabled == true,
              snapshot.power == .ac, snapshot.observedFullWake == true, snapshot.observedLidClosed == false,
              snapshot.nativeDisplayCandidate else { return false }
        attempted = true
        return true
    }
}
