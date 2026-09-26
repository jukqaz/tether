import XCTest
@testable import TetherCore

final class TempStatsTests: XCTestCase {
    func testWeightedAveragePeakAndPercentile() {
        var stats = TempStats()
        stats.add(30.4, seconds: 90)   // 90 % of the time at 30 °C
        stats.add(38.7, seconds: 10)
        XCTAssertEqual(stats.seconds, 100)
        XCTAssertEqual(stats.average!, 31.23, accuracy: 0.01)
        XCTAssertEqual(stats.max, 38.7)
        XCTAssertEqual(stats.percentile(0.5), 31)      // top of the 30 °C bucket
        XCTAssertEqual(stats.percentile(0.95), 38.7)   // capped at the peak
        XCTAssertNil(TempStats().percentile(0.5))
    }

    func testOutOfRangeTemperaturesLandInTheEndBuckets() {
        var stats = TempStats()
        stats.add(12, seconds: 5)
        stats.add(60, seconds: 5)
        XCTAssertEqual(stats.buckets.first, 5)
        XCTAssertEqual(stats.buckets.last, 5)
    }

    func testMerge() {
        var a = TempStats()
        a.add(30, seconds: 60)
        var b = TempStats()
        b.add(40, seconds: 60)
        a.merge(b)
        XCTAssertEqual(a.seconds, 120)
        XCTAssertEqual(a.average, 35)
        XCTAssertEqual(a.max, 40)
    }
}

final class SampleTickTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_799_982_000)
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }()

    func testClosedAndOpenTemperaturesAreKeptApart() {
        var stats = StatsTracker()
        stats.tick(now: t0, sample: UsageSample(lidClosed: true, clamshellOn: true, temperature: 33, thermal: 1),
                   calendar: calendar)
        stats.tick(now: t0.addingTimeInterval(30), sample: UsageSample(lidClosed: false, clamshellOn: true, temperature: 36),
                   calendar: calendar)
        stats.tick(now: t0.addingTimeInterval(60), sample: UsageSample(lidClosed: false, clamshellOn: true, temperature: 36),
                   calendar: calendar)
        let day = stats.today(now: t0, calendar: calendar)
        XCTAssertEqual(day.closedTemps?.seconds, 30)
        XCTAssertEqual(day.closedTemps?.max, 33)
        XCTAssertEqual(day.openTemps?.seconds, 30)
        XCTAssertEqual(day.closedMaxThermal, 1)
        XCTAssertEqual(day.lidClosedSeconds, 30)
    }

    /// A closed lid without clamshell means the Mac was on its way to sleep: nothing to learn.
    func testClosedLidWithoutClamshellIsNotMeasured() {
        var stats = StatsTracker()
        stats.tick(now: t0, sample: UsageSample(lidClosed: true, clamshellOn: false, temperature: 33), calendar: calendar)
        stats.tick(now: t0.addingTimeInterval(30), sample: UsageSample(lidClosed: true, clamshellOn: false, temperature: 33),
                   calendar: calendar)
        let day = stats.today(now: t0, calendar: calendar)
        XCTAssertNil(day.closedTemps)
        XCTAssertNil(day.openTemps)
    }

    func testHoldDrain() {
        var stats = StatsTracker()
        var t = t0
        for percent in [80, 80, 79, 78] {
            stats.tick(now: t, sample: UsageSample(lidClosed: true, clamshellOn: true, holdingOnBattery: true,
                                                   temperature: 32, batteryPercent: percent), calendar: calendar)
            t = t.addingTimeInterval(30)
        }
        let day = stats.today(now: t0, calendar: calendar)
        XCTAssertEqual(day.holdSeconds, 90)
        XCTAssertEqual(day.holdDrain, 2)
    }

    /// Stats written by 1.8 (no measurements, `lastActive`) still load.
    func testOlderUsageFileLoads() throws {
        let json = """
        {"recentSessions":[],"stats":{"days":[{"batteryHolds":0,"day":"2026-09-26","forcedSleeps":2,
         "heatGuards":0,"lidClosedSeconds":0}],"lastActive":false,"lastTick":1790410894.2},"tracker":{}}
        """
        let usage = try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.stats.days.first?.forcedSleeps, 2)
        XCTAssertNil(usage.stats.days.first?.closedTemps)
        XCTAssertNil(usage.stats.lastSample)
    }
}

final class AdvisorTests: XCTestCase {
    private func summary(closedAt closed: Double? = nil, closedFor: TimeInterval = 3600,
                         openAt open: Double? = nil, openFor: TimeInterval = 7200,
                         holdSeconds: Double = 0, holdDrain: Double = 0, heatGuards: Int = 0,
                         maxThermal: Int = 0, sessions: [LidSession] = []) -> UsageSummary {
        var day = DayStats(day: "2027-01-15", lidClosedSeconds: closedFor, heatGuards: heatGuards,
                           holdSeconds: holdSeconds, holdDrain: holdDrain, closedMaxThermal: maxThermal)
        if let closed {
            var stats = TempStats()
            stats.add(closed, seconds: closedFor)
            day.closedTemps = stats
        }
        if let open {
            var stats = TempStats()
            stats.add(open, seconds: openFor)
            day.openTemps = stats
        }
        return UsageSummary(week: [day], sessions: sessions)
    }

    func testCoolMacGetsATighterClosedLimit() {
        // Usually at or below 33 °C (the bucket top): 33 + 4 = 37, so the tightest choice, 38 °C.
        XCTAssertEqual(Advisor.closedLidLimit(summary(closedAt: 32.5))?.value, 38)
        // 36 °C bucket top 37 + 4 = 41.
        XCTAssertEqual(Advisor.closedLidLimit(summary(closedAt: 36.2))?.value, 41)
    }

    func testHotMacKeepsTheDefault() {
        XCTAssertEqual(Advisor.closedLidLimit(summary(closedAt: 41))?.value, SafetyPolicy.closedLid.hardTemperature)
        XCTAssertEqual(Advisor.openLidLimit(summary(openAt: 43))?.value, SafetyPolicy.openLid.hardTemperature)
    }

    func testNoAdviceWithoutEnoughData() {
        XCTAssertNil(Advisor.closedLidLimit(summary(closedAt: 30, closedFor: 600)))
        XCTAssertNil(Advisor.openLidLimit(summary(openAt: 30, openFor: 600)))
        XCTAssertNil(Advisor.maxHold(summary(), floor: 20))
        XCTAssertNil(Advisor.heatGuardLevel(summary(closedFor: 60)))
    }

    func testMaxHoldFromDrain() {
        // 20 %/h from a full charge to 20 %: 4 h fits.
        XCTAssertEqual(Advisor.maxHold(summary(holdSeconds: 3600, holdDrain: 20), floor: 20)?.value, 4)
        // 30 %/h: 80 / 30 = 2.7 h, so 2 h.
        XCTAssertEqual(Advisor.maxHold(summary(holdSeconds: 3600, holdDrain: 30), floor: 20)?.value, 2)
        // Starting at 80 % (charge limit) with a 40 % floor at 30 %/h: 1.3 h, so 1 h.
        let session = LidSession(start: 0, end: 3600, lastSeen: 3600, maxTemperature: 30, maxThermal: 0,
                                 batteryStart: 80, batteryEnd: 50, lowPower: true, onBattery: true)
        XCTAssertEqual(Advisor.maxHold(summary(holdSeconds: 3600, holdDrain: 30, sessions: [session]), floor: 40)?.value, 1)
    }

    func testHeatGuardLevel() {
        XCTAssertEqual(Advisor.heatGuardLevel(summary())?.value, 2)
        XCTAssertEqual(Advisor.heatGuardLevel(summary(heatGuards: 3))?.value, 1)
        XCTAssertEqual(Advisor.heatGuardLevel(summary(maxThermal: 3))?.value, 1)
    }

    // MARK: Auto-adjust

    /// A cool Mac: lid closed around 32.5 °C, open around 35 °C, holds using 30 % an hour.
    private var coolWeek: UsageSummary { summary(closedAt: 32.5, openAt: 35, holdSeconds: 3600, holdDrain: 30) }

    func testRecommendationsSetOnlyTheLimitsTheyCover() {
        let r = Recommendations(coolWeek, floor: 30)
        XCTAssertTrue(r.coversLimits)
        // 32.5 + 4 → 38 °C; 35 + 4 → 40 °C; 70 points at 30 %/h is 2.3 h → 2 h. The floor stays.
        XCTAssertEqual(r.applied(to: UserLimits(batteryFloor: 30)),
                       UserLimits(batteryFloor: 30, closedLidMaxTemperature: 38, openLidMaxTemperature: 40, maxHoldHours: 2))
        XCTAssertFalse(Recommendations(UsageSummary(week: [], sessions: []), floor: 20).coversLimits)
    }

    func testAutoAdjustOffKeepsTheChosenLimits() {
        let chosen = UserLimits(batteryFloor: 30, closedLidMaxTemperature: 41)
        XCTAssertEqual(Advisor.limitsInForce(chosen, auto: false, summary: coolWeek), chosen)
    }

    func testAutoAdjustFollowsTheMeasurements() {
        let result = Advisor.limitsInForce(UserLimits(closedLidMaxTemperature: 41), auto: true, summary: coolWeek)
        XCTAssertEqual(result?.closedLidMaxTemperature, 38)
        XCTAssertEqual(result?.openLidMaxTemperature, 40)
        XCTAssertEqual(result?.maxHoldHours, 2)
        XCTAssertEqual(SafetyPolicy.limits(lidClosed: true, user: result).hardTemperature, 38)
    }

    func testAutoAdjustWaitsForData() {
        let chosen = UserLimits(closedLidMaxTemperature: 41)
        XCTAssertEqual(Advisor.limitsInForce(chosen, auto: true, summary: UsageSummary(week: [], sessions: [])), chosen)
        // Half an hour closed isn't there yet: the chosen closed-lid limit stays, the open one follows.
        let partial = Advisor.limitsInForce(chosen, auto: true, summary: summary(closedAt: 30, closedFor: 600, openAt: 35))
        XCTAssertEqual(partial?.closedLidMaxTemperature, 41)
        XCTAssertEqual(partial?.openLidMaxTemperature, 40)
    }

    /// A Mac that runs hot gets the defaults back, even over a stricter choice, and never more.
    func testAutoAdjustIsNeverLooserThanTheDefaults() {
        let hot = summary(closedAt: 41, openAt: 43)
        let result = Advisor.limitsInForce(UserLimits(closedLidMaxTemperature: 40), auto: true, summary: hot)
        XCTAssertNil(result)
        XCTAssertEqual(SafetyPolicy.limits(lidClosed: true, user: result).hardTemperature, SafetyPolicy.closedLid.hardTemperature)
        XCTAssertEqual(SafetyPolicy.limits(lidClosed: false, user: result).hardTemperature, SafetyPolicy.openLid.hardTemperature)
        XCTAssertEqual(SafetyPolicy.maxHold(result), SafetyPolicy.maxHold)
    }

    func testControlLimitsInForce() {
        var control = Control(limits: UserLimits(batteryFloor: 25))
        XCTAssertEqual(control.limitsInForce(coolWeek), control.limits)
        control.autoLimits = true
        XCTAssertEqual(control.limitsInForce(coolWeek)?.closedLidMaxTemperature, 38)
        XCTAssertEqual(control.limitsInForce(coolWeek)?.batteryFloor, 25)
    }

    func testSummaryFromUsageFile() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var usage = Usage()
        usage.stats.tick(now: now.addingTimeInterval(-30), sample: UsageSample(lidClosed: true, clamshellOn: true, temperature: 33))
        usage.stats.tick(now: now, sample: UsageSample(lidClosed: true, clamshellOn: true, temperature: 33))
        XCTAssertEqual(UsageSummary(usage, now: now).closed.seconds, 30)
        XCTAssertEqual(UsageSummary(usage, now: now).lidClosedSeconds, 30)
        XCTAssertEqual(UsageSummary(nil, now: now).lidClosedSeconds, 0)
    }

    func testTypicalSessionNeedsAFew() {
        let s = { (d: Double) in LidSession(start: 0, end: d, lastSeen: d, maxTemperature: nil, maxThermal: 0,
                                           batteryStart: nil, batteryEnd: nil, lowPower: false, onBattery: false) }
        XCTAssertNil(summary(sessions: [s(600), s(1200)]).typicalSession)
        XCTAssertEqual(summary(sessions: [s(600), s(3600), s(1200)]).typicalSession, 1200)
    }
}
