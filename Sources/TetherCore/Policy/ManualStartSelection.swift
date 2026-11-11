import Foundation

/// A draft is inert. Resolve it at the explicit Start action, then let the
/// common policy approve power, safety and the original battery budget.
public enum ManualStartSelection: Equatable, Sendable {
    case minutes(Int)
    case until(Date)

    public static func parseMinutes(_ text: String) -> Self? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let minutes = Int(value), minutes > 0 else { return nil }
        return .minutes(minutes)
    }

    public func duration(at now: Date, maximum: TimeInterval) -> TimeInterval? {
        guard now.timeIntervalSince1970.isFinite, maximum.isFinite, maximum > 0 else { return nil }
        let seconds: Double
        switch self {
        case .minutes(let value):
            guard value > 0 else { return nil }
            seconds = Double(value) * 60
        case .until(let date):
            guard date.timeIntervalSince1970.isFinite else { return nil }
            seconds = date.timeIntervalSince(now)
        }
        guard seconds.isFinite, seconds > 0, seconds <= maximum,
              seconds <= ManualSessionPolicy.maximumTimedDuration else { return nil }
        return seconds
    }
}
