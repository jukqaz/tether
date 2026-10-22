import Foundation

/// Resolve the next local clock time once, then pass its duration to the continuous
/// session clock. Later wall-clock/time-zone changes never move the work deadline.
public enum SessionEndTime {
    public static func next(hour: Int, minute: Int, after now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard (0..<24).contains(hour), (0..<60).contains(minute), now.timeIntervalSince1970.isFinite else { return nil }
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                 matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }

    public static func duration(until: Date, now: Date, maximum: TimeInterval) -> TimeInterval? {
        let duration = until.timeIntervalSince(now)
        guard now.timeIntervalSince1970.isFinite, until.timeIntervalSince1970.isFinite,
              maximum.isFinite, maximum > 0, duration.isFinite, duration > 0,
              duration <= min(maximum, ManualSessionPolicy.maximumTimedDuration) else { return nil }
        return duration
    }
}
