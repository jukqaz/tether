import Foundation

public enum ScreenAction: Equatable, Sendable {
    case none, dim, restore
}

/// When the menu bar app darkens the built-in panel instead of sleeping it (display sleep
/// locks this Mac immediately).
public enum ScreenPolicy {
    /// `blank` means the screens should be dark while someone could see them: idle for a while in
    /// clamshell mode (display sleep would lock), or "screen off". Any input clears it, which
    /// restores. Blanking itself (gamma) is the caller's; this only decides the built-in panel.
    public static func action(clamshellActive: Bool, lidClosed: Bool, externalDisplay: Bool,
                              dimmed: Bool, blank: Bool = false) -> ScreenAction {
        if clamshellActive, lidClosed, !externalDisplay {
            return dimmed ? .none : .dim
        }
        if !lidClosed, blank {
            return dimmed ? .none : .dim
        }
        guard dimmed else { return .none }
        // Restore only once the panel can be seen again. Restoring while the lid is still shut
        // (power just pulled) races macOS's own battery dimming and the Mac is about to sleep.
        // With an external display attached macOS turns the built-in panel off by itself.
        return !lidClosed || externalDisplay ? .restore : .none
    }

    /// A screen is in view: the lid is open, or an external display is attached.
    public static func screenVisible(lidClosed: Bool, externalDisplay: Bool) -> Bool {
        !lidClosed || externalDisplay
    }

    /// Idle long enough in clamshell mode, with a screen in view, to blank it instead of sleeping it.
    public static func isIdleBlank(clamshellActive: Bool, lidClosed: Bool, externalDisplay: Bool,
                                   idleSeconds: Double, thresholdMinutes: Int) -> Bool {
        clamshellActive && screenVisible(lidClosed: lidClosed, externalDisplay: externalDisplay)
            && thresholdMinutes > 0 && idleSeconds >= Double(thresholdMinutes * 60)
    }

    /// Never save a level that is already dark, or a later restore would leave the panel black.
    public static func worthSaving(_ level: Float) -> Bool { level > 0.05 }
}
