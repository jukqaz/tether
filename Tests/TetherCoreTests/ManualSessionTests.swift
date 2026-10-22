import Foundation
import XCTest
@testable import TetherCore

/// v4 replaces the old automatic/AC-to-battery continuation expectations.
final class ManualSessionTests: XCTestCase {
    func testDefaultIsInactive() {
        let p = ManualSessionPolicy(boot: "manual")
        XCTAssertFalse(p.active); XCTAssertFalse(p.canHold); XCTAssertNil(p.requestID)
    }
    func testUnlimitedOnlyStartsOnKnownAC() {
        var p = ManualSessionPolicy(boot: "manual")
        XCTAssertFalse(p.start(duration: nil, power: .unknown, now: 100))
        XCTAssertFalse(p.start(duration: nil, power: .battery, now: 100))
        XCTAssertTrue(p.start(duration: nil, power: .ac, now: 100))
        p.evaluate(power: .ac, now: 100_000)
        XCTAssertTrue(p.active); XCTAssertNil(p.effectiveDeadline)
    }
    func testEveryACDepartureEndsEvenALegacyOptIn() {
        for legacy in [Int?.none, 15, 120] {
            var p = ManualSessionPolicy(batteryContinuationMinutes: legacy, boot: "manual")
            XCTAssertTrue(p.start(duration: nil, power: .ac, now: 100))
            p.evaluate(power: .unknown, now: 101)
            p.evaluate(power: .battery, now: 102)
            XCTAssertFalse(p.active); XCTAssertEqual(p.endReason, .powerDisconnected)
            p.evaluate(power: .ac, now: 103); XCTAssertFalse(p.active)
        }
    }
    func testBatteryOriginKeepsFirstCeilingOnACAndEndsOnReDeparture() {
        var p = ManualSessionPolicy(boot: "manual")
        XCTAssertTrue(p.start(duration: 1800, power: .battery, now: 100))
        p.evaluate(power: .ac, now: 101)
        XCTAssertEqual(p.requestedDeadline, 1900); XCTAssertEqual(p.batteryDeadline, 7300)
        p.evaluate(power: .battery, now: 102)
        XCTAssertFalse(p.active); XCTAssertEqual(p.endReason, .powerDisconnected)
        XCTAssertTrue(p.start(duration: 1800, power: .battery, now: 102))
        XCTAssertEqual(p.batteryDeadline, 7302)
    }
    func testBatteryRejectsInvalidAndOverTwoHourDurations() {
        var p = ManualSessionPolicy(boot: "manual")
        for duration in [Double.nan, .infinity, -1, 0, 59, 7201] {
            XCTAssertFalse(p.start(duration: duration, power: .battery, now: 100))
        }
        XCTAssertTrue(p.start(duration: 7200, power: .battery, now: 100))
        p.evaluate(power: .battery, now: 7300); XCTAssertFalse(p.active)
    }
    func testDuplicateStartDoesNotReplaceIdentityOrDeadline() {
        var p = ManualSessionPolicy(boot: "manual")
        XCTAssertTrue(p.start(duration: 1800, power: .battery, now: 100))
        let id = p.requestID
        XCTAssertFalse(p.start(duration: 7200, power: .battery, now: 101))
        XCTAssertEqual(p.requestID, id); XCTAssertEqual(p.requestedDeadline, 1900)
    }
    func testWholeExtensionsAddToOriginalDeadlineAndRespectCeiling() {
        var p = ManualSessionPolicy(boot: "manual")
        XCTAssertTrue(p.start(duration: 6300, power: .battery, now: 100))
        XCTAssertFalse(p.extend(duration: 1800, now: 101))
        XCTAssertTrue(p.extend(duration: 900, now: 101))
        XCTAssertEqual(p.requestedDeadline, 7300)
        XCTAssertFalse(p.extend(duration: 900, now: 102))
        XCTAssertFalse(p.extend(duration: 420, now: 102))
    }
    func testExpiredOrUnlimitedRequestsCannotExtend() {
        var p = ManualSessionPolicy(boot: "manual")
        XCTAssertTrue(p.start(duration: nil, power: .ac, now: 100))
        XCTAssertFalse(p.extend(duration: 900, now: 101)); p.end()
        XCTAssertTrue(p.start(duration: 60, power: .ac, now: 101))
        XCTAssertFalse(p.extend(duration: 900, now: 161))
        p.evaluate(power: .ac, now: 161); XCTAssertFalse(p.active)
    }
    func testBackwardClockCannotCreateOrExtendAuthority() {
        var p = ManualSessionPolicy(boot: "manual")
        XCTAssertFalse(p.start(duration: 900, power: .ac, now: .nan))
        XCTAssertTrue(p.start(duration: 900, power: .ac, now: 100))
        XCTAssertFalse(p.extend(duration: 900, now: 99))
        p.evaluate(power: .ac, now: 99); XCTAssertFalse(p.canHold)
    }
    func testReceiptCanTightenCurrentRevisionButNotItsFirstStartCeiling() {
        var p = ManualSessionPolicy(boot: "manual")
        XCTAssertTrue(p.start(duration: 7200, power: .battery, now: 100))
        XCTAssertTrue(p.acceptBatteryPermit(observedAt: 101, deadline: 1900, now: 102))
        XCTAssertEqual(p.requestedDeadline, 1900); XCTAssertEqual(p.batteryDeadline, 7300)
        XCTAssertTrue(p.extend(duration: 900, now: 102))
        XCTAssertFalse(p.acceptBatteryPermit(observedAt: 101, deadline: 1900, now: 103))
        XCTAssertEqual(p.requestedDeadline, 2800)
    }
    func testLegacyBudgetIsEvidenceAndCannotShortenFreshExplicitRequest() {
        var legacy = ProtectionState()
        legacy.prepareBatteryBudget(power: .battery, needed: true, clock: 1, boot: "manual")
        var p = ManualSessionPolicy(batteryBudget: legacy, boot: "manual")
        XCTAssertTrue(p.start(duration: 7200, power: .battery, now: 100))
        XCTAssertEqual(p.effectiveDeadline, 7300); XCTAssertNil(p.savedBatteryBudget)
    }
    func testUnknownBootCannotStartBatteryWork() {
        var p = ManualSessionPolicy(boot: "unknown")
        XCTAssertFalse(p.start(duration: 7200, power: .battery, now: 100))
        XCTAssertTrue(p.start(duration: nil, power: .ac, now: 100))
    }
    func testExplicitTaskEndDoesNotMeanTaskSuccess() {
        var p = ManualSessionPolicy(boot: "manual")
        XCTAssertTrue(p.start(duration: 7200, power: .battery, now: 100))
        p.end(.taskEnded)
        XCTAssertFalse(p.active); XCTAssertEqual(p.endReason, .taskEnded)
    }
}
