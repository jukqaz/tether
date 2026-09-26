import CoreGraphics
import Foundation

/// Mouse, trackpad and keyboard activity as the window server sees it (local or remote desktop).
public enum UserInput {
    // kCGAnyInputEventType (~0) is a C macro; imported C enums accept any raw value.
    private static let anyInput = CGEventType(rawValue: UInt32.max)!

    public static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    /// No modifier key is held, e.g. a hotkey's keys have been let go.
    public static var modifiersReleased: Bool {
        CGEventSource.flagsState(.hidSystemState)
            .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }

    /// Nothing for `quiet` seconds and no modifier held. Any input during powerd's ~5 s pre-sleep
    /// window cancels a sleep, so "sleep now" waits for this: otherwise the finger lifting after
    /// the click, or the hotkey being released, wakes the Mac right back up.
    public static func settled(quiet: Double = 0.6) -> Bool {
        idleSeconds >= quiet && modifiersReleased
    }
}
