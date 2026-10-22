import XCTest
@testable import TetherCore

final class SessionTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ temperature: Double?, thermal: Int = 0, battery: Int? = 80) -> SafetyReadings {
        SafetyReadings(temperature: temperature, thermal: thermal, batteryPercent: battery)
    }

    /// Feeds a closed-lid stretch every 30 s for `minutes`, then opens the lid.
    private func run(minutes: Int, _ tracker: inout SessionTracker) -> LidSession? {
        for i in 0...(minutes * 2) {
            let r = reading(30 + Double(i % 7), thermal: i == 5 ? 2 : 0, battery: 80 - i / 20)
            XCTAssertNil(tracker.update(lidClosed: true, clamshellOn: true, readings: r, onBattery: false,
                                        lowPower: false, now: t0.addingTimeInterval(Double(i) * 30)))
        }
        return tracker.update(lidClosed: false, clamshellOn: true, readings: reading(33), onBattery: false,
                              lowPower: false, now: t0.addingTimeInterval(Double(minutes * 60 + 30)))
    }

    func testLongSessionIsReportedWithPeaks() throws {
        var tracker = SessionTracker()
        let session = try XCTUnwrap(run(minutes: 20, &tracker))
        XCTAssertEqual(session.duration, 20 * 60 + 30, accuracy: 0.1)
        XCTAssertEqual(session.maxTemperature, 36)
        XCTAssertEqual(session.maxThermal, 2)
        XCTAssertEqual(session.batteryStart, 80)
        XCTAssertEqual(session.batteryEnd, 78)
        XCTAssertNil(tracker.open)
    }

    func testShortSessionIsNotReported() {
        var tracker = SessionTracker()
        XCTAssertNil(run(minutes: 3, &tracker))
        XCTAssertNil(tracker.open)
    }

    func testNothingWithoutClamshell() {
        var tracker = SessionTracker()
        XCTAssertNil(tracker.update(lidClosed: true, clamshellOn: false, readings: reading(30), onBattery: true,
                                    lowPower: false, now: t0))
        XCTAssertNil(tracker.open)
    }

    func testClamshellEndingWithLidClosedFinishesTheSession() throws {
        var tracker = SessionTracker()
        _ = tracker.update(lidClosed: true, clamshellOn: true, readings: reading(30), onBattery: false,
                           lowPower: false, now: t0)
        _ = tracker.update(lidClosed: true, clamshellOn: true, readings: reading(30), onBattery: false,
                           lowPower: true, now: t0.addingTimeInterval(30))
        tracker.open?.lastSeen = t0.addingTimeInterval(599).timeIntervalSince1970
        let session = try XCTUnwrap(tracker.update(lidClosed: true, clamshellOn: false, readings: reading(30),
                                                   onBattery: true, lowPower: false, now: t0.addingTimeInterval(600)))
        XCTAssertEqual(session.duration, 600, accuracy: 0.1)
        XCTAssertTrue(session.lowPower)
    }

    /// Sleep or a helper restart: the session ends where it was last seen, not when checks resume.
    func testGapClosesTheSessionAtLastSeen() throws {
        var tracker = SessionTracker()
        for i in 0...20 {
            _ = tracker.update(lidClosed: true, clamshellOn: true, readings: reading(30), onBattery: false,
                               lowPower: false, now: t0.addingTimeInterval(Double(i) * 30))
        }
        let later = t0.addingTimeInterval(3 * 3600)
        let session = try XCTUnwrap(tracker.update(lidClosed: false, clamshellOn: true, readings: reading(30),
                                                   onBattery: false, lowPower: false, now: later))
        XCTAssertEqual(session.duration, 600, accuracy: 0.1)
    }

    func testGapWhileStillClosedStartsAFreshSession() throws {
        var tracker = SessionTracker()
        for i in 0...20 {
            _ = tracker.update(lidClosed: true, clamshellOn: true, readings: reading(30), onBattery: false,
                               lowPower: false, now: t0.addingTimeInterval(Double(i) * 30))
        }
        let later = t0.addingTimeInterval(3600)
        XCTAssertNotNil(tracker.update(lidClosed: true, clamshellOn: true, readings: reading(30), onBattery: false,
                                       lowPower: false, now: later))
        XCTAssertEqual(tracker.open?.start, later.timeIntervalSince1970)
    }

    func testUnreadableTemperatureKeepsEarlierPeak() throws {
        var tracker = SessionTracker()
        _ = tracker.update(lidClosed: true, clamshellOn: true, readings: reading(34), onBattery: false,
                           lowPower: false, now: t0)
        _ = tracker.update(lidClosed: true, clamshellOn: true, readings: reading(nil), onBattery: false,
                           lowPower: false, now: t0.addingTimeInterval(30))
        XCTAssertEqual(tracker.open?.maxTemperature, 34)
    }
}

final class StatsTrackerTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }()

    /// 2027-01-15 12:00 KST.
    private let noon = Date(timeIntervalSince1970: 1_799_982_000)

    func testCreditsTimeToThePreviousState() {
        var stats = StatsTracker()
        stats.tick(now: noon, active: true, calendar: calendar)
        stats.tick(now: noon.addingTimeInterval(30), active: false, calendar: calendar)
        stats.tick(now: noon.addingTimeInterval(60), active: true, calendar: calendar)
        XCTAssertEqual(stats.today(now: noon, calendar: calendar).lidClosedSeconds, 30, accuracy: 0.01)
    }

    func testIgnoresLongGaps() {
        var stats = StatsTracker()
        stats.tick(now: noon, active: true, calendar: calendar)
        stats.tick(now: noon.addingTimeInterval(3600), active: true, calendar: calendar)
        XCTAssertEqual(stats.today(now: noon, calendar: calendar).lidClosedSeconds, 0)
        stats.tick(now: noon.addingTimeInterval(3630), active: true, calendar: calendar)
        XCTAssertEqual(stats.today(now: noon, calendar: calendar).lidClosedSeconds, 30, accuracy: 0.01)
    }

    func testCountsAndDayRollover() {
        var stats = StatsTracker()
        stats.recordSleepRequestAttempt(now: noon, calendar: calendar)
        stats.recordForcedSleep(now: noon, calendar: calendar)
        stats.recordBatteryHold(now: noon, calendar: calendar)
        let tomorrow = noon.addingTimeInterval(86_400)
        stats.recordHeatGuard(now: tomorrow, calendar: calendar)
        XCTAssertEqual(stats.today(now: noon, calendar: calendar).forcedSleeps, 2)
        XCTAssertEqual(stats.today(now: noon, calendar: calendar).batteryHolds, 1)
        XCTAssertEqual(stats.today(now: tomorrow, calendar: calendar).heatGuards, 1)
        XCTAssertEqual(stats.today(now: tomorrow, calendar: calendar).forcedSleeps, 0)
    }

    func testSleepRequestAttemptsPreserveLegacyStorageAndTotals() throws {
        let old = #"{"day":"2027-01-15","lidClosedSeconds":0,"forcedSleeps":5,"batteryHolds":0,"heatGuards":0}"#
        let day = try JSONDecoder().decode(DayStats.self, from: Data(old.utf8))
        XCTAssertEqual(day.sleepRequestAttempts, 5)
        var stats = StatsTracker(days: [day])
        stats.recordSleepRequestAttempt(now: noon, calendar: calendar)
        stats.recordForcedSleep(now: noon, calendar: calendar)
        let current = stats.today(now: noon, calendar: calendar)
        XCTAssertEqual(current.sleepRequestAttempts, 7)
        XCTAssertEqual(current.forcedSleeps, 7)
        let data = try JSONEncoder().encode(stats)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try XCTUnwrap((wire["days"] as? [[String: Any]])?.first)
        XCTAssertEqual(stored["forcedSleeps"] as? Int, 7)
        XCTAssertNil(stored["sleepRequestAttempts"], "usage.json retains its legacy storage schema")
        let restored = try JSONDecoder().decode(StatsTracker.self, from: data)
        XCTAssertEqual(restored.today(now: noon, calendar: calendar).sleepRequestAttempts, 7)
    }

    func testKeepsSevenDaysAndFillsTheWeek() {
        var stats = StatsTracker()
        for day in 0..<10 {
            stats.recordForcedSleep(now: noon.addingTimeInterval(Double(day) * 86_400), calendar: calendar)
        }
        XCTAssertEqual(stats.days.count, StatsTracker.keepDays)
        let last = noon.addingTimeInterval(9 * 86_400)
        XCTAssertEqual(stats.days.last?.day, StatsTracker.dayKey(last, calendar: calendar))

        let sparse = StatsTracker(days: [DayStats(day: StatsTracker.dayKey(noon, calendar: calendar), forcedSleeps: 3)])
        let week = sparse.week(now: noon.addingTimeInterval(2 * 86_400), calendar: calendar)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week[4].forcedSleeps, 3)
        XCTAssertEqual(week.map(\.forcedSleeps).reduce(0, +), 3)
    }

    func testUsageKeepsTheLastTenSessions() {
        var usage = Usage()
        for i in 0..<12 {
            usage.add(LidSession(start: Double(i), end: Double(i) + 400, lastSeen: Double(i) + 400, maxTemperature: nil,
                                 maxThermal: 0, batteryStart: nil, batteryEnd: nil, lowPower: false, onBattery: false))
        }
        XCTAssertEqual(usage.recentSessions.count, Usage.keepSessions)
        XCTAssertEqual(usage.recentSessions.first?.start, 2)
    }
}

final class CommandTests: XCTestCase {
    override func setUp() { Localization.current = .korean }
    override func tearDown() { Localization.current = .preferred }

    func testHoldDurations() {
        XCTAssertEqual(HoldDuration.minutes("90"), 90)
        XCTAssertEqual(HoldDuration.minutes("45m"), 45)
        XCTAssertEqual(HoldDuration.minutes("1h"), 60)
        XCTAssertEqual(HoldDuration.minutes("1h30m"), 90)
        XCTAssertEqual(HoldDuration.minutes("1.5h"), 90)
        XCTAssertEqual(HoldDuration.minutes("2H"), 120)
        XCTAssertNil(HoldDuration.minutes("4H"))
        XCTAssertEqual(HoldDuration.minutes("1시간 30분"), 90)
        XCTAssertEqual(HoldDuration.minutes("30분"), 30)
    }

    func testHoldDurationLimits() {
        XCTAssertNil(HoldDuration.minutes("0"))
        XCTAssertNil(HoldDuration.minutes("5h"))
        XCTAssertNil(HoldDuration.minutes("241"))
        XCTAssertNil(HoldDuration.minutes("abc"))
        XCTAssertNil(HoldDuration.minutes("1h30"))
        XCTAssertNil(HoldDuration.minutes(""))
    }

    func testWords() {
        XCTAssertEqual(TetherCommand.parse([]), .status)
        XCTAssertEqual(TetherCommand.parse(["status"]), .status)
        XCTAssertEqual(TetherCommand.parse(["on"]), .on)
        XCTAssertEqual(TetherCommand.parse(["OFF"]), .off)
        XCTAssertEqual(TetherCommand.parse(["toggle"]), .toggle)
        XCTAssertEqual(TetherCommand.parse(["sleep"]), .sleep)
        XCTAssertNil(TetherCommand.parse(["blank"]), "screen off was removed")
        XCTAssertEqual(TetherCommand.parse(["hold", "2h"]), .hold(minutes: 120))
        XCTAssertEqual(TetherCommand.parse(["hold", "1h", "30m"]), .hold(minutes: 90))
        XCTAssertEqual(TetherCommand.parse(["hold", "off"]), .cancelHold)
        XCTAssertNil(TetherCommand.parse(["hold"]))
        XCTAssertNil(TetherCommand.parse(["hold", "9h"]))
        XCTAssertNil(TetherCommand.parse(["reboot"]))
    }

    func testHoldDurationRoundingBoundaries() {
        XCTAssertNil(HoldDuration.minutes("0.49m"))
        XCTAssertEqual(HoldDuration.minutes("0.5m"), 1)
        XCTAssertEqual(HoldDuration.minutes("1.5m"), 2)
        XCTAssertEqual(HoldDuration.minutes("120.49m"), 120)
        XCTAssertNil(HoldDuration.minutes("120.5m"))
        XCTAssertEqual(HoldDuration.minutes("0.25m0.25m"), 1)
        XCTAssertNil(HoldDuration.minutes("1.5"))
    }

    func testOversizedHoldDurationsAreRejectedAcrossEntryPoints() throws {
        let large = String(repeating: "9", count: 308)
        let inputs = [
            "9223372036854775808m",                    // Finite, but outside Int's range.
            String(repeating: "9", count: 400) + "m", // Double parsing overflow.
            large + "h",                             // Hour-to-minute overflow.
            large + "m" + large + "m",                // Accumulation overflow.
            "999999999999999999999시간",
            String(repeating: "9", count: 400) + "분",
        ]
        for input in inputs {
            XCTAssertNil(HoldDuration.minutes(input))
            XCTAssertNil(TetherCommand.parse(["hold", input]))
            XCTAssertNil(TetherCommand.parse(["hold", "+" + input]))
            for prefix in ["tether://hold/", "tether://hold/+", "tether://hold?minutes=", "tether://hold?minutes=+"] {
                let url = try XCTUnwrap(URL(string: prefix + input))
                XCTAssertNil(TetherCommand.parse(url: url))
            }
        }
        XCTAssertNil(TetherCommand.parse(["hold", "+1시간", "30분"]))
        XCTAssertEqual(TetherCommand.parse(url: try XCTUnwrap(URL(string: "tether://hold?minutes=1%EC%8B%9C%EA%B0%84%2030%EB%B6%84"))), .hold(minutes: 90))
    }

    func testURLs() {
        func parse(_ s: String) -> TetherCommand? { TetherCommand.parse(url: URL(string: s)!) }
        XCTAssertEqual(parse("tether://sleep"), .sleep)
        XCTAssertNil(parse("tether://blank"))
        XCTAssertEqual(parse("tether://on"), .on)
        XCTAssertEqual(parse("tether://hold/90m"), .hold(minutes: 90))
        XCTAssertEqual(parse("tether://hold?minutes=45"), .hold(minutes: 45))
        XCTAssertEqual(parse("tether://hold/off"), .cancelHold)
        XCTAssertNil(parse("tether://"))
        XCTAssertNil(parse("tether://format-disk"))
        XCTAssertNil(parse("https://sleep"))
    }

    func testTexts() {
        XCTAssertEqual(Texts.duration(30), "30초")
        XCTAssertEqual(Texts.duration(42 * 60), "42분")
        XCTAssertEqual(Texts.duration(3600), "1시간")
        XCTAssertEqual(Texts.duration(83 * 60), "1시간 23분")
        XCTAssertEqual(Texts.total(0), "0분")
        XCTAssertEqual(Texts.total(59), "0분")
        XCTAssertEqual(Texts.total(185 * 60), "3시간 5분")
        XCTAssertEqual(Texts.countdown(83 * 60), "1:23:00")
        XCTAssertEqual(Texts.countdown(29 * 60 + 41), "29:41")
        XCTAssertEqual(Texts.countdown(9.2), "0:10")
        XCTAssertEqual(Texts.countdown(3599.5), "1:00:00")
        XCTAssertEqual(Texts.countdown(-5), "0:00")
    }

    func testEnglish() {
        Localization.current = .english
        XCTAssertEqual(Texts.duration(83 * 60), "1 h 23 min")
        XCTAssertEqual(Texts.duration(42 * 60), "42 min")
        XCTAssertEqual(Texts.total(30), "0 min")
        XCTAssertEqual(Texts.thermal(2), "serious")
        XCTAssertEqual(L("on", "켜짐"), "on")
        Localization.current = .korean
        XCTAssertEqual(L("on", "켜짐"), "켜짐")
    }
}
