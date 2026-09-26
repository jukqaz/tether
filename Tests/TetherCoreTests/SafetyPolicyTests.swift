import XCTest
@testable import TetherCore

final class SafetyPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var later: Date { now.addingTimeInterval(3600) }

    private func verdict(_ temp: Double?, thermal: Int = 0, battery: Int? = 80, closed: Bool = true,
                         warmFor: TimeInterval? = nil, until: Date? = nil) -> HoldEnd? {
        SafetyPolicy.verdict(SafetyReadings(temperature: temp, thermal: thermal, batteryPercent: battery),
                             lidClosed: closed, now: now, holdUntil: until ?? later,
                             warmSince: warmFor.map { now.addingTimeInterval(-$0) })
    }

    // Closed lid (maybe in a bag): strict.
    func testClosedLidHardTemperatureEndsImmediately() {
        XCTAssertEqual(verdict(43.0), .heat)
    }

    func testClosedLidWarmButNotYetSustainedKeepsHolding() {
        XCTAssertNil(verdict(41.0, warmFor: 30))
    }

    func testClosedLidWarmForAMinuteEnds() {
        XCTAssertEqual(verdict(41.0, warmFor: 61), .heat)
    }

    func testClosedLidCriticalThermalEndsImmediately() {
        XCTAssertEqual(verdict(30.0, thermal: 3), .thermal)
    }

    func testClosedLidSeriousThermalForAMinuteEnds() {
        XCTAssertEqual(verdict(30.0, thermal: 2, warmFor: 61), .thermal)
    }

    // Open lid (in use, normal airflow): only the hard limits.
    func testOpenLidToleratesWhatClosedLidWouldNot() {
        XCTAssertNil(verdict(44.0, closed: false))
        XCTAssertNil(verdict(41.0, thermal: 2, closed: false, warmFor: 600))
        XCTAssertFalse(SafetyPolicy.isWarm(SafetyReadings(temperature: 44, thermal: 2, batteryPercent: 80),
                                           lidClosed: false))
    }

    func testOpenLidHardLimitsStillEnd() {
        XCTAssertEqual(verdict(45.0, closed: false), .heat)
        XCTAssertEqual(verdict(30.0, thermal: 3, closed: false), .thermal)
    }

    // Common limits.
    func testUnreadableTemperatureFailsSafe() {
        XCTAssertEqual(verdict(nil), .sensor)
        XCTAssertEqual(verdict(nil, closed: false), .sensor)
    }

    func testBatteryFloor() {
        XCTAssertEqual(verdict(30.0, battery: 20), .battery)
        XCTAssertNil(verdict(30.0, battery: 21))
    }

    func testTimeIsUp() {
        XCTAssertEqual(verdict(30.0, until: now), .time)
    }

    func testCoolAndChargedKeepsHolding() {
        XCTAssertNil(verdict(30.0))
    }

    // Deadline bookkeeping.
    func testRequestIsCappedAtFourHoursFromWhenItWasSeen() {
        let seen = now.timeIntervalSince1970
        let requested = seen + 10 * 3600
        let state = HelperState(holdValue: requested, holdSeenAt: seen)
        XCTAssertEqual(state.holdDeadline(requested: requested, now: now),
                       now.addingTimeInterval(SafetyPolicy.maxHold))
    }

    func testConsumedOrUnknownRequestIsNotAHold() {
        let requested = now.timeIntervalSince1970 + 600
        XCTAssertNil(HelperState(holdValue: requested, holdSeenAt: requested - 600, consumedHold: requested)
            .holdDeadline(requested: requested, now: now))
        XCTAssertNil(HelperState(holdValue: requested + 1, holdSeenAt: requested - 600)
            .holdDeadline(requested: requested, now: now))
        XCTAssertNil(HelperState().holdDeadline(requested: nil, now: now))
    }

    // Rule engine with a hold.
    func testBatteryHoldKeepsClamshellWithLidClosed() {
        let s = Snapshot(power: .battery, lidClosed: true, sleepDisabled: true)
        XCTAssertEqual(Policy.actions(for: s, triggers: [.power], enabled: true, sleepNowPending: false,
                                      batteryHold: true), [])
    }

    func testEndedHoldOnBatteryWithLidClosedSleeps() {
        let s = Snapshot(power: .battery, lidClosed: true, sleepDisabled: true)
        XCTAssertEqual(Policy.actions(for: s, triggers: [.thermal], enabled: true, sleepNowPending: false,
                                      batteryHold: false), [.setSleepDisabled(false), .sleepSystem])
    }
}
