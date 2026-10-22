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

    func testSeriousAndCriticalStopWithEitherLidState() {
        for closed in [true, false] {
            for thermal in [2, 3] { XCTAssertEqual(verdict(nil, thermal: thermal, closed: closed), .thermal) }
        }
    }

    func testCelsiusReadingsAreNotSafetyThresholds() {
        for value in [nil, 30.0, 43.0, 80.0, Double.nan, Double.infinity] {
            XCTAssertNil(verdict(value))
            XCTAssertNil(verdict(value, closed: false))
        }
    }

    func testMissingChargeOrInvalidThermalFailsSafe() {
        XCTAssertEqual(verdict(nil, battery: nil), .sensor)
        XCTAssertEqual(verdict(30, thermal: -1), .sensor)
        XCTAssertEqual(verdict(30, thermal: 4), .sensor)
    }

    func testBatteryFloor() {
        XCTAssertEqual(verdict(30.0, battery: 20), .battery)
        XCTAssertNil(verdict(30.0, battery: 21))
    }

    func testExplicitReserveCanBeLowerThanDefaultWithoutDisablingOSWarning() {
        XCTAssertEqual(SafetyPolicy.floor(nil), 20)
        for floor in SafetyPolicy.floorChoices {
            XCTAssertEqual(SafetyPolicy.floor(UserLimits(batteryFloor: floor)), floor)
        }
        let lowReserve = UserLimits(batteryFloor: 5)
        XCTAssertTrue(SafetyPolicy.canStartHold(batteryPercent: 10, user: lowReserve))
        XCTAssertFalse(SafetyPolicy.canStartHold(batteryPercent: 10, user: lowReserve, lowPowerWarning: true))
        XCTAssertFalse(SafetyPolicy.canStartHold(batteryPercent: 5, user: lowReserve))
        XCTAssertEqual(SafetyPolicy.floor(UserLimits(batteryFloor: 80)), 80, "Do not weaken an old stricter reserve")
    }

    func testOSBatteryWarningEndsBatteryHoldAboveTheReserveAndUnknownFailsClosed() {
        for warning in [Bool?.some(true), nil] {
            let readings = SafetyReadings(temperature: nil, thermal: 0, batteryPercent: 80, lowPowerWarning: warning)
            XCTAssertEqual(SafetyPolicy.verdict(readings, lidClosed: true, now: now,
                holdUntil: later, warmSince: nil), warning == true ? .battery : .sensor)
            XCTAssertFalse(SafetyPolicy.canStartHold(batteryPercent: 80, lowPowerWarning: warning))
        }
        XCTAssertTrue(SafetyPolicy.canStartHold(batteryPercent: 80, lowPowerWarning: false))
        XCTAssertEqual(SafetyReadings(temperature: nil, thermal: 0, batteryPercent: 80).lowPowerWarning, false)
    }

    func testPublicBatteryWarningValuesPreserveNoneEarlyFinalAndUnknown() {
        XCTAssertEqual(SystemProbe.lowBatteryWarning(level: 1), false)
        XCTAssertEqual(SystemProbe.lowBatteryWarning(level: 2), true)
        XCTAssertEqual(SystemProbe.lowBatteryWarning(level: 3), true)
        for value in [Int.min, -1, 0, 4, Int.max] { XCTAssertNil(SystemProbe.lowBatteryWarning(level: value)) }
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
