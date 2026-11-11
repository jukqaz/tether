import Foundation

/// Compact remaining time for the status item. The session's actual deadline and policy
/// remain outside this presentation value.
public struct MenuBarCountdown: Hashable, Sendable {
    public let remainingSeconds: TimeInterval?

    public init(remaining seconds: TimeInterval) {
        // Validate second-level conversion separately from the compact display. AC
        // sessions can exceed a day; they must not overflow or widen the status item.
        guard seconds.isFinite, seconds <= ManualSessionPolicy.maximumTimedDuration,
              Int(exactly: max(0, seconds).rounded(.up)) != nil else {
            remainingSeconds = nil
            return
        }
        remainingSeconds = max(0, seconds)
    }

    /// Round up so even the last second reads as one remaining minute.
    public var minutes: Int? {
        remainingSeconds.map { Int(($0 / 60).rounded(.up)) }
    }

    public var text: String {
        guard let minutes else { return "—" }
        return minutes > 9999 ? Self.widthReference : Self.text(minutes: minutes)
    }

    /// A presentation bound only. VoiceOver retains the actual second-level value.
    /// Every countdown, including an unreadable one, keeps this same slot.
    public static var widthReference: String {
        L("9999m+", "9999분+")
    }

    /// VoiceOver keeps the second-level precision hidden by the compact minute display.
    public var accessibilityValue: String {
        guard let remainingSeconds else {
            return L("Remaining time unavailable", "남은 시간 확인 중")
        }
        let countdown = Texts.countdown(remainingSeconds)
        return L("\(countdown) remaining", "\(countdown) 남음")
    }

    private static func text(minutes: Int) -> String {
        L("\(minutes)m", "\(minutes)분")
    }
}
