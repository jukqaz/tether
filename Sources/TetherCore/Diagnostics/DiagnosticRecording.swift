import Foundation

/// A troubleshooting window never changes power policy. Old indefinite choices remain readable.
public enum DiagnosticRecording {
    public static let choices = [15, 60, 240]
    public static let maximumDuration: TimeInterval = 4 * 3600

    public static func isActive(enabled: Bool?, until: Double?, now: Date = Date()) -> Bool {
        guard enabled == true else { return false }
        guard let until else { return true } // Preserve a legacy explicit setting.
        return until.isFinite && until > now.timeIntervalSince1970
    }

    public static func deadline(minutes: Int, now: Date = Date()) -> Double {
        now.timeIntervalSince1970 + Double(min(240, max(1, minutes))) * 60
    }

    public static func reportHours(_ hours: Double) -> Double {
        hours.isFinite && hours > 0 ? min(72, max(1.0 / 60, hours)) : 24
    }
}
