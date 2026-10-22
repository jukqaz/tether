import Foundation

public enum PowerSource: String, Codable, Sendable {
    case ac, battery, unknown
}

/// Automatic activation is deliberately limited to the physical power source.
public enum PowerCondition: String, Codable, CaseIterable, Identifiable, Sendable {
    case ac, battery, any
    public var id: Self { self }
    public var includesAC: Bool { self != .battery }
    public var includesBattery: Bool { self != .ac }
    public var title: String {
        switch self {
        case .ac: L("On power only", "전원 연결 중만")
        case .battery: L("On battery only", "배터리 사용 중만")
        case .any: L("Power and battery", "전원·배터리 모두")
        }
    }
}

/// One automatic battery hold per eligible power transition. Canceling cannot re-arm it.
public struct AutomaticHoldGate {
    private var wasEligible = false
    public init() {}
    public mutating func reset(eligible: Bool) { wasEligible = eligible }
    public mutating func entering(eligible: Bool) -> Bool {
        let entered = eligible && !wasEligible
        wasEligible = eligible
        return entered
    }
}

/// What the helper can observe about the Mac right now.
public struct Snapshot: Equatable, Sendable {
    public var power: PowerSource
    public var observedLidClosed: Bool?
    public var observedSleepDisabled: Bool?
    public var observedFullWake: Bool?
    /// Compatibility values for presentation. OS decisions must use the optional readings;
    /// an unavailable query is neither an open lid nor a cleared global override.
    public var lidClosed: Bool {
        get { observedLidClosed ?? false }
        set { observedLidClosed = newValue }
    }
    public var sleepDisabled: Bool {
        get { observedSleepDisabled ?? false }
        set { observedSleepDisabled = newValue }
    }
    /// False during a dark wake (Power Nap), when nothing should be forced.
    public var fullWake: Bool {
        get { observedFullWake ?? false }
        set { observedFullWake = newValue }
    }
    public var lidControlObservationAvailable: Bool {
        observedLidClosed != nil && observedSleepDisabled != nil && observedFullWake != nil
    }
    public var unavailablePowerObservations: [String] {
        [("lid", observedLidClosed), ("sleepOverride", observedSleepDisabled), ("wake", observedFullWake)]
            .compactMap { $0.1 == nil ? $0.0 : nil }
    }
    /// Observed display setup; virtual outputs are distinct from physical monitors.
    public var displayTopology: DisplayTopology = .none
    public var externalDisplay: Bool
    /// Matched wired connection, used only to prepare an open-lid handoff.
    public var nativeDisplayCandidate = false
    /// A bounded profile query can defer a new override while the OS already reports that
    /// the lid does not cause sleep. It never relinquishes an existing owned override.
    public var nativeDisplayProbePending = false
    /// Matched connection plus current OS lid policy with SleepDisabled clear. This is an
    /// observed policy handoff; completed physical closed-lid operation requires a real test.
    public var nativeDisplayVerified = false
    /// Yield only after a physical-monitor handoff was verified. An unclassified or virtual
    /// output alone cannot end an otherwise valid work session.
    public var defersToDisplaySetup: Bool {
        power == .ac && lidControlObservationAvailable && externalDisplay && nativeDisplayVerified
            && displayTopology != .unknown && displayTopology.mayHavePhysicalExternal
    }
    public var usesNativeClamshell: Bool { defersToDisplaySetup }

    public init(power: PowerSource, lidClosed: Bool?, sleepDisabled: Bool?,
                fullWake: Bool? = true, externalDisplay: Bool = false) {
        self.power = power
        self.observedLidClosed = lidClosed
        self.observedSleepDisabled = sleepDisabled
        self.observedFullWake = fullWake
        self.externalDisplay = externalDisplay
        self.displayTopology = externalDisplay ? .externalUnverified : .none
    }
}

public enum Trigger: String, Sendable, Hashable {
    case start, power, lid, wake, settings, timer, sleepNow, thermal, display
}

public enum Action: Equatable, Sendable {
    case setSleepDisabled(Bool)
    case sleepSystem
}

/// The whole rule set: AC power turns clamshell mode on, anything else turns it off, except
/// during a time-boxed battery hold whose safety limits are checked by the helper.
public enum Policy {
    public static func wantsClamshell(_ s: Snapshot, enabled: Bool, sleepNowPending: Bool,
                                      batteryHold: Bool = false, condition: PowerCondition = .ac,
                                      ownsOverride: Bool = false, manualSession: Bool = false) -> Bool {
        // Losing a display observation does not invalidate power/time/protection policy.
        // Preserve an existing owned hold, but do not acquire a new global change blind.
        (enabled || manualSession) && !sleepNowPending && (!s.nativeDisplayProbePending || ownsOverride) && (s.displayTopology != .unknown || (ownsOverride && s.sleepDisabled))
            && !s.defersToDisplaySetup && (manualSession || (s.power == .ac && condition.includesAC) || (s.power == .battery && batteryHold))
    }

    public static func actions(for s: Snapshot, triggers: Set<Trigger>, enabled: Bool,
                               sleepNowPending: Bool, batteryHold: Bool = false, condition: PowerCondition = .ac,
                               ownsOverride: Bool = true, releaseNeedsSleep: Bool = false, manualSession: Bool = false) -> [Action] {
        // powerd can briefly report nothing at boot; wait for the next check.
        guard s.power != .unknown else { return s.observedSleepDisabled == true && ownsOverride ? [.setSleepDisabled(false)] : [] }

        var out: [Action] = []
        if wantsClamshell(s, enabled: enabled, sleepNowPending: sleepNowPending, batteryHold: batteryHold,
                         condition: condition, ownsOverride: ownsOverride, manualSession: manualSession) {
            // Display observation and bounded recovery are independent. This keeps an
            // awake Mac awake but never wakes a sleeping one: during a dark wake (Power Nap, a
            // maintenance wake, a charger connected while asleep) the Mac is left to go back to
            // sleep, and the next full wake turns clamshell mode on.
            if s.lidControlObservationAvailable, s.observedSleepDisabled == false, s.observedFullWake == true {
                out.append(.setSleepDisabled(true))
            }
            return out
        }

        let clearingFlag = s.observedSleepDisabled == true && ownsOverride
        if clearingFlag { out.append(.setSleepDisabled(false)) }
        // macOS only evaluates the lid when it opens or closes, so a lid that is already
        // shut when sleep is allowed again never sleeps on its own. On battery the lid
        // always wins; only a physical monitor can provide native clamshell on AC.
        let lidShouldSleep = s.observedLidClosed == true && s.observedFullWake == true
            && (s.power == .battery || !s.displayTopology.mayHavePhysicalExternal)
        // A lid that closes while sleep is already allowed is macOS's own clamshell sleep;
        // only step in when the flag was just cleared or the Mac stays awake on a later check.
        let macOSHandlesIt = triggers == [.lid] && !clearingFlag
        if s.observedSleepDisabled != nil, s.observedFullWake == true,
           (lidShouldSleep && !macOSHandlesIt && (ownsOverride || releaseNeedsSleep)) || triggers.contains(.sleepNow) {
            out.append(.sleepSystem)
        }
        return out
    }
}
