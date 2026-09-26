import Foundation

/// Decides when the helper should remove itself because the menu bar app is gone (dragged to the
/// Trash without "Uninstall"), so an orphaned root helper never keeps a Mac awake.
public struct AppPresence: Sendable {
    /// Long enough to ride out an update or a move between folders.
    public static let grace: TimeInterval = 600

    public var missingSince: Date?

    public init() {}

    /// `path` is the app executable the app last reported. Translocated paths (an app opened
    /// straight from Downloads) are temporary by design and never count.
    public mutating func shouldRetire(path: String?, exists: Bool, now: Date) -> Bool {
        guard let path, !path.contains("/AppTranslocation/"), !exists else {
            missingSince = nil
            return false
        }
        let since = missingSince ?? now
        missingSince = since
        return now.timeIntervalSince(since) >= Self.grace
    }
}
