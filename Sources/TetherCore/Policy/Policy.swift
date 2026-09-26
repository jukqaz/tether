import Foundation

public enum PowerSource: String, Codable, Sendable {
    case ac, battery, unknown
}

/// What the helper can observe about the Mac right now.
public struct Snapshot: Equatable, Sendable {
    public var power: PowerSource
    public var lidClosed: Bool
    public var sleepDisabled: Bool
    /// False during a dark wake (Power Nap), when nothing should be forced.
    public var fullWake: Bool
    /// True when an external display keeps a closed lid from causing sleep.
    public var externalDisplay: Bool

    public init(power: PowerSource, lidClosed: Bool, sleepDisabled: Bool,
                fullWake: Bool = true, externalDisplay: Bool = false) {
        self.power = power
        self.lidClosed = lidClosed
        self.sleepDisabled = sleepDisabled
        self.fullWake = fullWake
        self.externalDisplay = externalDisplay
    }
}

public enum Trigger: String, Sendable, Hashable {
    case start, power, lid, wake, settings, timer, sleepNow, thermal
}

public enum Action: Equatable, Sendable {
    case setSleepDisabled(Bool)
    case sleepSystem
}

/// The whole rule set: AC power turns clamshell mode on, anything else turns it off, except
/// during a time-boxed battery hold whose safety limits are checked by the helper.
public enum Policy {
    public static func wantsClamshell(_ s: Snapshot, enabled: Bool, sleepNowPending: Bool,
                                      batteryHold: Bool = false) -> Bool {
        enabled && !sleepNowPending && (s.power == .ac || (s.power == .battery && batteryHold))
    }

    public static func actions(for s: Snapshot, triggers: Set<Trigger>, enabled: Bool,
                               sleepNowPending: Bool, batteryHold: Bool = false) -> [Action] {
        // powerd can briefly report nothing at boot; wait for the next check.
        guard s.power != .unknown else { return [] }

        var out: [Action] = []
        if wantsClamshell(s, enabled: enabled, sleepNowPending: sleepNowPending, batteryHold: batteryHold) {
            // Clamshell mode keeps the session exactly as it was: no sleep, no display
            // sleep (which locks this Mac), so the lid is not touched here at all.
            if !s.sleepDisabled { out.append(.setSleepDisabled(true)) }
            return out
        }

        let clearingFlag = s.sleepDisabled
        if clearingFlag { out.append(.setSleepDisabled(false)) }
        // macOS only evaluates the lid when it opens or closes, so a lid that is already
        // shut when sleep is allowed again never sleeps on its own. On battery the lid
        // always wins; on AC an external display keeps normal clamshell use awake.
        let lidShouldSleep = s.lidClosed && s.fullWake && (s.power == .battery || !s.externalDisplay)
        // A lid that closes while sleep is already allowed is macOS's own clamshell sleep;
        // only step in when the flag was just cleared or the Mac stays awake on a later check.
        let macOSHandlesIt = triggers == [.lid] && !clearingFlag
        if (lidShouldSleep && !macOSHandlesIt) || triggers.contains(.sleepNow) {
            out.append(.sleepSystem)
        }
        return out
    }
}
