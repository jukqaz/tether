import Foundation

/// Bounded local summaries. These records never restore a work session or permission.
@MainActor
public final class UsageStatisticsStore {
    public static let storageKey = "tether.usage-statistics.v1"
    public private(set) var stats = StatsTracker()
    public private(set) var issue: String?

    private struct Stored: Codable {
        var version: Int = 1
        var days: [DayStats]
        var thermalEpisodeActive: Bool
    }

    private let defaults: UserDefaults?
    private var thermalEpisodeActive = false
    private var preservesUnreadableRecord = false
    private var dirty = false
    private var lastSavedAt: Date?

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        guard let defaults, let original = defaults.object(forKey: Self.storageKey) else { return }
        guard let data = original as? Data, data.count <= 32_768,
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == 1, Self.valid(stored.days) else {
            preservesUnreadableRecord = true
            issue = "stored-statistics-unreadable"
            return
        }
        // Transient sampling state is deliberately not persisted: reopening cannot fill downtime.
        stats = StatsTracker(days: stored.days)
        thermalEpisodeActive = stored.thermalEpisodeActive
    }

    public func observe(now: Date, lidClosed: Bool?, clamshellConfirmed: Bool,
                        holding: Bool, onBattery: Bool, protectionReason: String?) {
        guard now.timeIntervalSince1970.isFinite else { return }
        if lidClosed == nil {
            // An unknown lid reading cannot extend the previous confirmed closed interval.
            stats.lastSample?.lidClosed = false
            stats.lastSample?.clamshellOn = false
        }
        let previous = stats
        stats.tick(now: now, sample: UsageSample(
            lidClosed: lidClosed == true,
            clamshellOn: lidClosed == true && clamshellConfirmed && holding,
            holdingOnBattery: holding && onBattery))
        let wasThermal = thermalEpisodeActive
        if protectionReason == "thermal", !thermalEpisodeActive {
            stats.recordHeatGuard(now: now)
            thermalEpisodeActive = true
        } else if protectionReason == nil {
            thermalEpisodeActive = false
        }
        dirty = dirty || stats.days != previous.days || wasThermal != thermalEpisodeActive
        // Persist a new protection event immediately, otherwise at most once a minute.
        if wasThermal != thermalEpisodeActive || lastSavedAt.map({ now.timeIntervalSince($0) >= 60 }) != false {
            flush()
            lastSavedAt = now
        }
    }

    public func flush() {
        guard dirty, let defaults, !preservesUnreadableRecord else { return }
        let stored = Stored(days: stats.days, thermalEpisodeActive: thermalEpisodeActive)
        guard Self.valid(stored.days), let data = try? JSONEncoder().encode(stored), data.count <= 32_768 else {
            issue = "statistics-save-failed"
            return
        }
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.data(forKey: Self.storageKey) == data else {
            issue = "statistics-save-failed"
            return
        }
        dirty = false
        issue = nil
    }

    private static func valid(_ days: [DayStats]) -> Bool {
        guard days.count <= StatsTracker.keepDays, Set(days.map(\.day)).count == days.count,
              days.map(\.day) == days.map(\.day).sorted() else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return days.allSatisfy { day in
            guard day.day.count == 10, let date = formatter.date(from: day.day),
                  formatter.string(from: date) == day.day else { return false }
            let durations = [day.lidClosedSeconds, day.holdSeconds ?? 0]
            return durations.allSatisfy { $0.isFinite && (0...86_400).contains($0) }
                && [day.forcedSleeps, day.batteryHolds, day.heatGuards].allSatisfy { (0...1_000_000).contains($0) }
        }
    }
}
