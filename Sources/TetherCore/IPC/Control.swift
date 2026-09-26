import Foundation

/// Written by the menu bar app, read by the helper.
public struct Control: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// A new timestamp asks the helper to sleep the Mac now.
    public var sleepNowRequest: Double?
    /// Keep clamshell mode on battery until this time (capped at 4 h, safety limits apply).
    public var batteryHoldUntil: Double?
    /// Stricter battery-hold limits chosen in Settings; nil means the defaults.
    public var limits: UserLimits?
    /// The AC heat guard; nil means on, from "serious".
    public var heatGuard: HeatGuardSettings?
    /// Who armed the battery hold: "app", "url", "cli", or "run:<command>".
    public var holdSource: String?
    /// The menu bar app's executable, written by the app at launch. The helper removes itself
    /// once it has been gone a while (the app was dragged to the Trash).
    public var appPath: String?
    /// Detailed logging: the helper logs every check and its reasons, for troubleshooting.
    public var debugLog: Bool?

    public init(enabled: Bool = true, sleepNowRequest: Double? = nil, batteryHoldUntil: Double? = nil,
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

public enum ControlStore {
    public static func read(path: String = TetherPaths.controlPath) -> Control {
        JSONFile.read(Control.self, from: path) ?? Control()
    }

    /// Applies a change to the control file and nudges the helper. Returns false when it cannot
    /// be written, e.g. the helper was never installed so the folder does not exist.
    @discardableResult
    public static func update(path: String = TetherPaths.controlPath, _ change: (inout Control) -> Void) -> Bool {
        var control = read(path: path)
        change(&control)
        guard JSONFile.write(control, to: path, permissions: 0o664) else { return false }
        DarwinNotification.post(TetherPaths.controlChanged)
        return true
    }

    @discardableResult
    public static func setEnabled(_ on: Bool) -> Bool { update { $0.enabled = on } }

    @discardableResult
    public static func sleepNow() -> Bool { update { $0.sleepNowRequest = Date().timeIntervalSince1970 } }

    @discardableResult
    public static func startHold(minutes: Int, source: String? = nil) -> Bool {
        update {
            $0.batteryHoldUntil = Date().addingTimeInterval(TimeInterval(minutes * 60)).timeIntervalSince1970
            $0.holdSource = source
        }
    }

    @discardableResult
    public static func cancelHold() -> Bool {
        update {
            $0.batteryHoldUntil = nil
            $0.holdSource = nil
        }
    }
}
