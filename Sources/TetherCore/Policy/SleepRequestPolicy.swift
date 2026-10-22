import Foundation

/// A retry retains its original reason. Protection is tied to the closed-lid session;
/// it must never turn into an unconditional user-requested sleep after that session ends.
public enum SleepIntent: Equatable, Sendable {
    case user, closedLid, protection
}

/// Process-local responsibility for finishing a lid session that Tether actually
/// managed. Releasing the global flag (including a native-display handoff) does
/// not discard that responsibility. It never survives restart or authorizes a
/// sleep for a Mac that only used native clamshell in the first place.
public struct ClosedLidSleepTracker: Sendable {
    public private(set) var retryDeadline: Double?
    private var managedWork = false
    private var pendingPower: PowerSource?
    private var lastClock: Double?
    public init() {}

    public mutating func recordManagedWork(snapshot: Snapshot, ownsOverride: Bool, workRequested: Bool) {
        if ownsOverride, workRequested, snapshot.observedSleepDisabled == true,
           snapshot.observedFullWake == true, snapshot.power != .unknown {
            managedWork = true
        }
    }

    /// Reuse the existing finite helper lease allowance rather than retaining an
    /// old sleep indefinitely. A changed power/lid/session or foreign global
    /// override cancels it; unavailable observations cannot authorize an attempt.
    public mutating func update(snapshot s: Snapshot, ownsOverride: Bool, workRequested: Bool,
                                now: Double) -> Bool {
        guard now.isFinite, lastClock.map({ now >= $0 }) ?? true else { reset(); return false }
        lastClock = now
        guard s.power != .unknown, s.observedFullWake == true,
              s.observedLidClosed != nil else { reset(); return false }
        if workRequested {
            retryDeadline = nil; pendingPower = nil
            recordManagedWork(snapshot: s, ownsOverride: ownsOverride, workRequested: true)
            return false
        }
        guard s.observedLidClosed == true,
              !(s.observedSleepDisabled == true && !ownsOverride) else { reset(); return false }
        if managedWork, retryDeadline == nil {
            managedWork = false
            retryDeadline = now + IdleSessionPolicy.healthTTL
            pendingPower = s.power
        }
        guard let deadline = retryDeadline, now < deadline, pendingPower == s.power else {
            reset(); return false
        }
        return true
    }

    public mutating func reset() {
        managedWork = false; retryDeadline = nil; pendingPower = nil; lastClock = nil
    }
}

public enum SleepRequestPolicy {
    /// A pre-approved battery endpoint may be observed just after its timer fires.
    /// Bound that terminal action independently of the work heartbeat. A delayed
    /// wake/restart must never turn an old deadline into a new Sleep request.
    public static let maximumEndActionDelay: Double = 30
    public static let restoreRetryOffsets: [Double] = [0, 5, 10, 20]
    /// Missed slots are skipped. A later retry may recover our resource but can
    /// never create or refresh terminal Sleep permission.
    public static func nextRestoreRetry(observedAt: Double, failedAttempts: Int, now: Double) -> Double {
        guard observedAt.isFinite, now.isFinite, now >= observedAt else { return now + 30 }
        if failedAttempts < restoreRetryOffsets.count,
           let next = restoreRetryOffsets.dropFirst(max(1, failedAttempts)).map({ observedAt + $0 }).first(where: { $0 > now }) {
            return next
        }
        return now + 30
    }

    public static func approvedBatteryEndDeadline(lease: WorkSessionLease,
                                                  receipt: WorkSessionBatteryPermitReceipt,
                                                  boot: String, now: Double) -> Double? {
        guard lease.executionVersion == 3, lease.isValid(now: now), lease.configuration.enabled,
              let permit = lease.lidPermit, permit.powerScopes.contains(.battery),
              permit.batteryPermitID == receipt.permitID, lease.sessionID == receipt.sessionID,
              receipt.isValid(boot: boot), now.isFinite, now >= receipt.observedAt,
              let expiry = lease.expiry, expiry > now else { return nil }
        let automatic = false // Automatic work is AC-only; old battery settings are not a grant.
        let manual = lease.reasons.contains(.manual)
            && (lease.manualDeadline.map { now < $0 } ?? true)
        guard automatic || manual else { return nil }
        var deadline = min(receipt.deadline, permit.batteryDeadline ?? .greatestFiniteMagnitude)
        if !automatic, let manualDeadline = lease.manualDeadline { deadline = min(deadline, manualDeadline) }
        // Heartbeat expiry by itself authorizes cleanup, never demand Sleep.
        guard now < deadline, expiry >= deadline else { return nil }
        return deadline
    }
    /// A pre-approved v3 end incident is consumed once by the helper. A public
    /// idle assertion is not a global demand-Sleep blocker and is never removed
    /// or treated as a reason to wait for a client callback in this path.
    public static func allowsCoordinatedEnd(_ kind: WorkSessionEndReceipt.Kind, action: WorkSessionEndAction,
                                           snapshot s: Snapshot, ownerConfirmed: Bool, restoreConfirmed: Bool,
                                           batteryPermitValid: Bool, thermal: Int?, observerConfirmed: Bool,
                                           batteryProtectionActive: Bool = false) -> Bool {
        guard observerConfirmed, ownerConfirmed, restoreConfirmed, s.power != .unknown,
              s.observedFullWake == true, s.observedSleepDisabled == false else { return false }
        switch kind {
        case .user: return true
        case .disconnect, .batteryExpired, .taskEnded:
            return action == .sleepIfClosed && s.observedLidClosed == true && s.power == .battery && !batteryPermitValid
                && thermal.map({ (0...3).contains($0) }) == true
        case .protection:
            return action == .sleepIfClosed && s.observedLidClosed == true
                && (thermal.map({ (2...3).contains($0) }) == true || (s.power == .battery && batteryProtectionActive))
        }
    }
    /// Recovery has no healthy helper to verify an AC display setup. Release our
    /// override there, and reuse the normal coexistence policy only on battery.
    public static func allowsAutomaticRecovery(snapshot: Snapshot, foreignKeepAwake: Bool?) -> Bool {
        snapshot.power == .battery && allows(.closedLid, snapshot: snapshot, requestPending: false,
            enabled: false, batteryHold: false, condition: .ac, foreignKeepAwake: foreignKeepAwake)
    }

    public static func allows(_ intent: SleepIntent, snapshot s: Snapshot, requestPending: Bool,
                              enabled: Bool, batteryHold: Bool, condition: PowerCondition,
                              foreignKeepAwake: Bool? = nil, manualSession: Bool = false) -> Bool {
        guard s.observedFullWake == true, s.power != .unknown, s.observedSleepDisabled == false else { return false }
        switch intent {
        case .user:
            return requestPending
        case .protection:
            return foreignKeepAwake == false && requestPending && s.observedLidClosed == true
                && (s.power == .battery || (condition.includesAC && !s.displayTopology.mayHavePhysicalExternal))
        case .closedLid:
            guard foreignKeepAwake == false else { return false }
            guard s.observedLidClosed == true, s.power == .battery || !s.displayTopology.mayHavePhysicalExternal else { return false }
            return !Policy.wantsClamshell(s, enabled: enabled, sleepNowPending: requestPending,
                                         batteryHold: batteryHold, condition: condition, manualSession: manualSession)
        }
    }
}
