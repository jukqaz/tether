import Foundation
import TetherCore

/// Made-up records for screenshots and design checks (`--render-preview --sample --hold`).
enum SampleData {
    /// A week of lid-closed hours and temperatures, three lid sessions and three sleeps.
    static func usage(now: Date = Date()) -> Usage {
        var stats = StatsTracker()
        let hours = [3.2, 0, 5.5, 1.1, 7.8, 2.4, 4.6]
        let closedPeaks = [34.8, 0, 36.1, 33.2, 37.4, 34.0, 35.2]
        let openPeaks = [37.9, 36.4, 39.2, 35.8, 38.6, 37.1, 36.8]
        for offset in 0..<7 {
            let day = now.addingTimeInterval(Double(offset - 6) * 86_400)
            var closed = TempStats()
            if hours[offset] > 0 {
                closed.add(closedPeaks[offset] - 3, seconds: hours[offset] * 3000)
                closed.add(closedPeaks[offset], seconds: hours[offset] * 600)
            }
            var open = TempStats()
            open.add(openPeaks[offset] - 5, seconds: 5 * 3600)
            open.add(openPeaks[offset], seconds: 1800)
            stats.days.append(DayStats(day: StatsTracker.dayKey(day), lidClosedSeconds: hours[offset] * 3600,
                                       forcedSleeps: offset == 6 ? 2 : 0, heatGuards: offset == 4 ? 1 : 0,
                                       closedTemps: hours[offset] > 0 ? closed : nil, openTemps: open,
                                       holdSeconds: offset == 3 ? 5400 : nil, holdDrain: offset == 3 ? 18 : nil,
                                       closedMaxThermal: offset == 4 ? 2 : 1))
        }
        let end = now.addingTimeInterval(-600).timeIntervalSince1970
        let sessions = [
            LidSession(start: end - 86_400 * 2 - 7200, end: end - 86_400 * 2, lastSeen: end - 86_400 * 2,
                       maxTemperature: 36.1, maxThermal: 1, batteryStart: 80, batteryEnd: 80, lowPower: false,
                       onBattery: false),
            LidSession(start: end - 86_400 - 5400, end: end - 86_400, lastSeen: end - 86_400, maxTemperature: 33.2,
                       maxThermal: 0, batteryStart: 80, batteryEnd: 62, lowPower: true, onBattery: true),
            LidSession(start: end - 83 * 60, end: end, lastSeen: end, maxTemperature: 38.2, maxThermal: 1,
                       batteryStart: 80, batteryEnd: 80, lowPower: true, onBattery: false),
        ]
        var sleeps = SleepLog()
        for (daysAgo, hours, before, after, reason, tether, wake) in [
            (2.0, 7.5, 84, 81, "Clamshell Sleep", false, "EC.LidOpen"),
            (1.0, 3.2, 80, 69, "Software Sleep", true, "smc.sysState.Wake wifibt"),
            (0.4, 8.1, 80, 77, "Clamshell Sleep", false, "UserActivity Assertion"),
        ] as [(Double, Double, Int, Int, String, Bool, String)] {
            let sleptAt = now.timeIntervalSince1970 - daysAgo * 86_400 - hours * 3600
            var record = SleepRecord(sleptAt: sleptAt, percentBefore: before, onBatteryBefore: true, byTether: tether)
            record.wokeAt = sleptAt + hours * 3600
            record.percentAfter = after
            record.onBatteryAfter = true
            record.sleepReason = reason
            record.wakeReason = wake
            record.darkWakes = tether ? 4 : 1
            sleeps.recent.append(record)
        }
        return Usage(stats: stats, recentSessions: sessions, sleepLog: sleeps)
    }

    /// The status with a battery hold armed 19 seconds ago, running for half an hour.
    static func holding(_ status: Status, now: Date = Date()) -> Status {
        var fake = status
        let t = now.timeIntervalSince1970
        fake.updatedAt = t
        fake.batteryHoldUntil = t + 30 * 60 - 19
        fake.batteryHoldSince = t - 19
        return fake
    }
}
