import XCTest
@testable import TetherCore

final class V4ChargerTrendTests: XCTestCase {
    func testShortAndSparseObservationsCannotWarn() {
        var trend = V4ChargerTrend()
        XCTAssertFalse(trend.observe(at: 0, power: .ac, batteryPercent: 80).shouldNotify)
        XCTAssertFalse(trend.observe(at: 100, power: .ac, batteryPercent: 60).shouldNotify)
        XCTAssertFalse(trend.observe(at: 600, power: .ac, batteryPercent: 50).shouldNotify)
        XCTAssertFalse(trend.warningActive)
    }
    func testSixFreshSamplesAndFullWindowWarnOnceForNetThreePoints() {
        var trend = V4ChargerTrend(); var notices = 0
        for index in 0...5 {
            let result = trend.observe(at: Double(index * 120), power: .ac, batteryPercent: index == 5 ? 77 : 80)
            if result.shouldNotify { notices += 1 }
            if index < 5 { XCTAssertFalse(result.shouldNotify) }
        }
        XCTAssertEqual(notices, 1); XCTAssertTrue(trend.warningActive)
        let repeated = trend.observe(at: 720, power: .ac, batteryPercent: 76)
        XCTAssertFalse(repeated.shouldNotify); XCTAssertFalse(repeated.didRecover)
    }
    func testOnlyNetDeclineCountsNotIntermediateDip() {
        var trend = V4ChargerTrend()
        for index in 0...5 {
            let result = trend.observe(at: Double(index * 120), power: .ac, batteryPercent: index == 2 ? 70 : 80)
            XCTAssertFalse(result.shouldNotify)
        }
    }
    func testGapCannotCreateWarningOrCountAsRecovery() {
        var trend = warned()
        let gap = trend.observe(at: 1000, power: .ac, batteryPercent: 77)
        XCTAssertTrue(gap.warningActive); XCTAssertFalse(gap.didRecover); XCTAssertFalse(gap.shouldNotify)
        for index in 1...5 {
            let result = trend.observe(at: 1000 + Double(index * 120), power: .ac, batteryPercent: 77 - index)
            XCTAssertFalse(result.shouldNotify); XCTAssertFalse(result.didRecover)
        }
    }
    func testFreshStableWindowRecoversAndLaterDeclineCanNotifyAgain() {
        var trend = warned()
        var recovered = false
        for index in 1...5 {
            let result = trend.observe(at: 600 + Double(index * 120), power: .ac, batteryPercent: 77)
            recovered = recovered || result.didRecover
            XCTAssertFalse(result.shouldNotify)
        }
        XCTAssertTrue(recovered); XCTAssertFalse(trend.warningActive)
        var notifications = 0
        for index in 1...5 {
            let result = trend.observe(at: 1200 + Double(index * 120), power: .ac, batteryPercent: index == 5 ? 74 : 77)
            if result.shouldNotify { notifications += 1 }
        }
        XCTAssertEqual(notifications, 1)
    }
    func testSleepWakeDiscardsTrendWithoutClaimingRecoveryOrReannouncing() {
        var trend = warned(); trend.resetAfterSleepOrWake()
        for index in 0...5 {
            let result = trend.observe(at: 1000 + Double(index * 120), power: .ac, batteryPercent: 77 - index)
            XCTAssertFalse(result.shouldNotify); XCTAssertFalse(result.didRecover)
        }
        XCTAssertTrue(trend.warningActive)
    }
    func testPowerChangeEndsSegmentButDoesNotClaimRecovery() {
        var trend = warned()
        let battery = trend.observe(at: 601, power: .battery, batteryPercent: 77)
        XCTAssertFalse(battery.didRecover); XCTAssertFalse(battery.warningActive)
        for index in 0...5 {
            let result = trend.observe(at: 602 + Double(index * 120), power: .ac, batteryPercent: index == 5 ? 74 : 77)
            XCTAssertEqual(result.shouldNotify, index == 5)
        }
    }
    func testDuplicateBadAndRegressedReadingsDoNotFabricateEvidence() {
        var trend = V4ChargerTrend()
        for percent in [80, 70, 60, 50, 40, 30] { XCTAssertFalse(trend.observe(at: 0, power: .ac, batteryPercent: percent).shouldNotify) }
        XCTAssertFalse(trend.observe(at: 600, power: .ac, batteryPercent: 20).shouldNotify)
        XCTAssertEqual(trend.observe(at: 599, power: .ac, batteryPercent: 20).state, .unavailable)
        for value in [Int?(-1), 101, nil] { XCTAssertFalse(trend.observe(at: 700, power: .ac, batteryPercent: value).shouldNotify) }
        XCTAssertFalse(trend.observe(at: .nan, power: .ac, batteryPercent: 0).shouldNotify)
    }
    func testSourceChangeAtDuplicateTimestampStillDiscardsACWindow() {
        var trend = warned()
        let ended = trend.observe(at: 600, power: .battery, batteryPercent: 77)
        XCTAssertFalse(ended.warningActive); XCTAssertFalse(ended.didRecover)
        XCTAssertFalse(trend.observe(at: 601, power: .ac, batteryPercent: 70).shouldNotify)
    }
    private func warned() -> V4ChargerTrend {
        var trend = V4ChargerTrend()
        for index in 0...5 { _ = trend.observe(at: Double(index * 120), power: .ac, batteryPercent: index == 5 ? 77 : 80) }
        XCTAssertTrue(trend.warningActive)
        return trend
    }
}
