import Foundation

/// Persisted by the helper after an authenticated, revision-checked request.
public struct Control: Codable, Equatable, Sendable {
    public static let currentSchema = 4
    public var schemaVersion: Int?
    public var enabled: Bool
    public var powerCondition: PowerCondition?
    public var automaticHoldMinutes: Int?
    public var condition: PowerCondition { .ac }
    public var automaticMinutes: Int { min(Int(SafetyPolicy.maxHold(limits) / 60), max(1, automaticHoldMinutes ?? 60)) }
    /// A new timestamp asks the helper to sleep the Mac now.
    public var sleepNowRequest: Double?
    /// Keep clamshell mode on battery until this time (capped at 4 h, safety limits apply).
    public var batteryHoldUntil: Double?
    /// Manual hold waiting for a full-wake transition to battery. Never survives helper restart.
    public var pendingHoldMinutes: Int?
    /// Stricter battery-hold limits chosen in Settings; nil means the defaults.
    public var limits: UserLimits?
    /// Read-only legacy setting. New configurations cannot request energy-mode changes.
    public var heatGuard: HeatGuardSettings?
    /// Who armed the battery hold: "app", "url", "cli", or "run:<command>".
    public var holdSource: String?
    /// The menu bar app's executable, written by the app at launch. The helper removes itself
    /// once it has been gone a while (the app was dragged to the Trash).
    public var appPath: String?
    /// Detailed logging: the helper logs every check and its reasons, for troubleshooting.
    public var debugLog: Bool?
    /// Optional end of a troubleshooting window; nil preserves legacy indefinite logging.
    public var debugLogUntil: Double?
    public var debugLoggingActive: Bool { DiagnosticRecording.isActive(enabled: debugLog, until: debugLogUntil) }
    /// Read-only legacy setting, removed by schema 3 migration.
    public var holdLowPower: Bool?
    /// Retired wire field. Migration freezes the old battery allowance; decoding
    /// never enables statistical adjustment in the running policy.
    public var autoLimits: Bool?
    // Read-only migration fields. Removed modes never turn into an automatic AC hold.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, enabled, powerCondition, automaticHoldMinutes, sleepNowRequest, batteryHoldUntil, limits, heatGuard,
             holdSource, appPath, debugLog, debugLogUntil, holdLowPower, autoLimits, pendingHoldMinutes
    }
    private enum LegacyKeys: String, CodingKey { case profile, paused }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        powerCondition = try c.decodeIfPresent(PowerCondition.self, forKey: .powerCondition)
        automaticHoldMinutes = try c.decodeIfPresent(Int.self, forKey: .automaticHoldMinutes)
        sleepNowRequest = try c.decodeIfPresent(Double.self, forKey: .sleepNowRequest)
        batteryHoldUntil = try c.decodeIfPresent(Double.self, forKey: .batteryHoldUntil)
        pendingHoldMinutes = try c.decodeIfPresent(Int.self, forKey: .pendingHoldMinutes)
        limits = try c.decodeIfPresent(UserLimits.self, forKey: .limits)
        heatGuard = try c.decodeIfPresent(HeatGuardSettings.self, forKey: .heatGuard)
        holdSource = try c.decodeIfPresent(String.self, forKey: .holdSource)
        appPath = try c.decodeIfPresent(String.self, forKey: .appPath)
        debugLog = try c.decodeIfPresent(Bool.self, forKey: .debugLog)
        debugLogUntil = try c.decodeIfPresent(Double.self, forKey: .debugLogUntil)
        holdLowPower = try c.decodeIfPresent(Bool.self, forKey: .holdLowPower)
        autoLimits = nil  // adaptive statistics are no longer a runtime policy
        let old = try decoder.container(keyedBy: LegacyKeys.self)
        let profile = try old.decodeIfPresent(String.self, forKey: .profile)
        if try old.decodeIfPresent(Bool.self, forKey: .paused) == true || (profile != nil && profile != "cable") {
            enabled = false; batteryHoldUntil = nil; pendingHoldMinutes = nil; holdSource = nil
        }
    }

    public init(enabled: Bool = false, sleepNowRequest: Double? = nil, batteryHoldUntil: Double? = nil,
                limits: UserLimits? = nil, heatGuard: HeatGuardSettings? = nil, holdSource: String? = nil,
                appPath: String? = nil) {
        self.enabled = enabled
        self.sleepNowRequest = sleepNowRequest
        self.batteryHoldUntil = batteryHoldUntil
        self.limits = limits
        self.heatGuard = heatGuard
        self.holdSource = holdSource
        self.appPath = appPath
    }
}

extension Control {
    public var isSupported: Bool {
        (schemaVersion == nil || schemaVersion.map { (1...Self.currentSchema).contains($0) } == true)
            && (sleepNowRequest?.isFinite ?? true) && (batteryHoldUntil?.isFinite ?? true)
            && (debugLogUntil?.isFinite ?? true)
            && (pendingHoldMinutes.map { (1...240).contains($0) } ?? true)
            && !(pendingHoldMinutes != nil && batteryHoldUntil != nil)
            && (holdSource?.utf8.count ?? 0) <= 256 && (appPath?.utf8.count ?? 0) <= 4096
    }

    public var hasRetiredSettings: Bool {
        heatGuard != nil || holdLowPower != nil || autoLimits == true
            || powerCondition == .battery || powerCondition == .any
            || batteryHoldUntil != nil || pendingHoldMinutes != nil
            || limits?.closedLidMaxTemperature != nil || limits?.openLidMaxTemperature != nil
    }

}

public enum ControlStore {
    public static func read(path: String = TetherPaths.controlPath) -> Control {
        JSONFile.read(Control.self, from: path) ?? Control()
    }

    /// Applies a locked read/change/write transaction in place and nudges the helper. Returns
    /// false for a busy, missing, malformed or unwritable file without replacing it with defaults.
    @discardableResult
    public static func update(path: String = TetherPaths.controlPath, _ change: (inout Control) -> Void) -> Bool {
        if path == TetherPaths.controlPath { return ServiceClient().updateControl(change) }
        guard JSONFile.update(Control.self, at: path, change) else { return false }
        DarwinNotification.post(TetherPaths.controlChanged)
        return true
    }

    @discardableResult
    public static func setEnabled(_ on: Bool) -> Bool {
        if on { return (try? ServiceClient().perform(ServiceRequest(.resume))) != nil }
        return (try? ServiceClient().perform(ServiceRequest(.stop))) != nil
    }

    @discardableResult
    public static func sleepNow() -> Bool { (try? ServiceClient().perform(ServiceRequest(.sleep))) != nil }

    @discardableResult
    public static func startHold(minutes: Int, source: String? = nil) -> Bool {
        var request = ServiceRequest(.startHold)
        request.minutes = minutes; request.holdSource = source
        return (try? ServiceClient().perform(request)) != nil
    }

    /// Pushes the running hold's deadline back; the helper keeps the 4-hour cap from its start.
    @discardableResult
    public static func extendHold(minutes: Int) -> Bool {
        update {
            let now = Date().timeIntervalSince1970
            $0.batteryHoldUntil = max($0.batteryHoldUntil ?? now, now) + TimeInterval(minutes * 60)
        }
    }

    @discardableResult
    public static func cancelHold() -> Bool {
        update {
            $0.batteryHoldUntil = nil
            $0.pendingHoldMinutes = nil
            $0.holdSource = nil
        }
    }
}

/// A last-good backup is committed before replacing configuration. A corrupt or newer-schema
/// file is never silently converted to default settings; explicit repair remains possible.
public enum ControlFile {
    public static func save(_ next: Control, previous: Control, path: String) -> Bool {
        guard next.isSupported, !next.hasRetiredSettings, previous.isSupported,
              JSONFile.write(previous, to: path + ".backup", permissions: 0o600, durable: true) else { return false }
        var versioned = next
        versioned.schemaVersion = Control.currentSchema
        return JSONFile.write(versioned, to: path, permissions: 0o644, durable: true)
    }
}
