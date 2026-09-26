import Foundation

/// Written by the helper to `usage.json` (world-readable), read by the app and the CLI.
public struct Usage: Codable, Equatable, Sendable {
    public var stats: StatsTracker
    public var tracker: SessionTracker
    /// Finished sessions worth reporting, oldest first.
    public var recentSessions: [LidSession]
    /// Absent in files from before 1.10.
    public var sleepLog: SleepLog?

    public static let keepSessions = 10

    public init(stats: StatsTracker = StatsTracker(), tracker: SessionTracker = SessionTracker(),
                recentSessions: [LidSession] = [], sleepLog: SleepLog? = nil) {
        self.stats = stats
        self.tracker = tracker
        self.recentSessions = recentSessions
        self.sleepLog = sleepLog
    }

    public var sleeps: SleepLog {
        get { sleepLog ?? SleepLog() }
        set { sleepLog = newValue }
    }

    public mutating func add(_ session: LidSession) {
        recentSessions.append(session)
        if recentSessions.count > Self.keepSessions {
            recentSessions.removeFirst(recentSessions.count - Self.keepSessions)
        }
    }
}
