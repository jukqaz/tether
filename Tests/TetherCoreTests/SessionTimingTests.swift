import XCTest
@testable import TetherCore

final class SessionTimingTests: XCTestCase {
    func testUnlimitedManualCannotBeRetimedAndOnlyExplicitReplacementGetsANewIdentity() {
        var session = ManualSessionPolicy(boot: "fixture")
        XCTAssertTrue(session.start(duration: nil, power: .ac, now: 100))
        let originalID = session.requestID
        let now = 100.0 + 30 * 86_400
        XCTAssertFalse(session.reschedule(duration: 900, now: now))
        XCTAssertFalse(session.extend(duration: 60, now: now + 1))
        session.evaluate(power: .ac, now: now + 2)
        XCTAssertTrue(session.active); XCTAssertEqual(session.startedAt, 100)
        XCTAssertNil(session.requestedDeadline); XCTAssertNil(session.effectiveDeadline)
        XCTAssertEqual(session.requestID, originalID)
        XCTAssertFalse(session.start(duration: 900, power: .ac, now: now + 2))
        session.end()
        XCTAssertTrue(session.start(duration: 900, power: .ac, now: now + 3))
        XCTAssertNotEqual(session.requestID, originalID)
        XCTAssertEqual(session.effectiveDeadline, now + 903)
    }

    func testACTimedRequestCanExceedTwentyFourHoursAndOnlyFullApprovedIntervalsExtendIt() {
        var session = ManualSessionPolicy(boot: "fixture")
        XCTAssertTrue(session.start(duration: 172_800, power: .ac, now: 100))
        let original = session
        for duration in [60.0, 86_400, 172_800] {
            XCTAssertFalse(session.reschedule(duration: duration, now: 200))
            XCTAssertFalse(session.extend(duration: duration, now: 200))
            XCTAssertEqual(session, original)
        }
        XCTAssertFalse(session.reschedule(duration: 900, now: 200))
        XCTAssertTrue(session.extend(duration: 900, now: 200))
        let firstExtension = session.extensionID
        XCTAssertNotNil(firstExtension)
        XCTAssertEqual(session.requestedDeadline, 173_800)
        XCTAssertTrue(session.extend(duration: 1800, now: 201))
        XCTAssertNotEqual(session.extensionID, firstExtension)
        XCTAssertEqual(session.startedAt, original.startedAt)
        XCTAssertEqual(session.requestID, original.requestID)
        session.evaluate(power: .ac, now: 86_501)
        XCTAssertTrue(session.active); XCTAssertEqual(session.requestedDeadline, 175_600)
        XCTAssertEqual(session.requestID, original.requestID)
        session.evaluate(power: .ac, now: 172_900)
        XCTAssertTrue(session.active)
        session.evaluate(power: .ac, now: 175_600)
        XCTAssertFalse(session.active); XCTAssertEqual(session.endReason, .time)
    }

    func testFinishInIsRejectedWithoutMovingTheOriginalTimedExpiryOrIdentity() {
        var session = ManualSessionPolicy(boot: "fixture")
        XCTAssertTrue(session.start(duration: 3600, power: .ac, now: 100))
        let originalID = session.requestID
        XCTAssertFalse(session.reschedule(duration: 900, now: 200))
        XCTAssertEqual(session.startedAt, 100); XCTAssertEqual(session.requestedDeadline, 3700)
        session.evaluate(power: .ac, now: 1100)
        XCTAssertTrue(session.active); XCTAssertEqual(session.requestID, originalID)
        session.evaluate(power: .ac, now: 3700)
        XCTAssertFalse(session.active); XCTAssertEqual(session.endReason, .time)
    }

    func testObservedManualAndBatteryExpiryCannotBeRevivedByRejectedRetiming() {
        var timed = ManualSessionPolicy(boot: "fixture")
        XCTAssertTrue(timed.start(duration: 60, power: .ac, now: 100))
        timed.evaluate(power: .ac, now: 160)
        let expiredTimed = timed
        XCTAssertFalse(timed.reschedule(duration: 900, now: 160))
        XCTAssertFalse(timed.extend(duration: 900, now: 160))
        XCTAssertEqual(timed, expiredTimed); XCTAssertFalse(timed.active)
        XCTAssertEqual(timed.endReason, .time)
        var battery = ManualSessionPolicy(boot: "fixture")
        XCTAssertTrue(battery.start(duration: 7200, power: .battery, now: 100))
        XCTAssertEqual(battery.batteryDeadline, 7300)
        battery.evaluate(power: .battery, now: 7300)
        let expiredBattery = battery
        XCTAssertFalse(battery.reschedule(duration: 900, now: 7300))
        XCTAssertFalse(battery.extend(duration: 1800, now: 7300))
        XCTAssertEqual(battery, expiredBattery); XCTAssertFalse(battery.active)
        XCTAssertEqual(battery.endReason, .time)
        XCTAssertNil(battery.requestID); XCTAssertNil(battery.effectiveDeadline)
    }

    func testRemainingBatteryTimeAndFirstCapAreNotRefilledByRejectedRetiming() {
        var session = ManualSessionPolicy(boot: "fixture")
        XCTAssertTrue(session.start(duration: 7200, power: .battery, now: 100))
        let originalID = session.requestID
        XCTAssertFalse(session.reschedule(duration: 1800, now: 7240))
        XCTAssertFalse(session.reschedule(duration: 60, now: 7240))
        XCTAssertFalse(session.extend(duration: 60, now: 7240))
        XCTAssertFalse(session.extend(duration: 900, now: 7240))
        XCTAssertFalse(session.extend(duration: 1800, now: 7240))
        XCTAssertEqual(session.startedAt, 100); XCTAssertEqual(session.requestID, originalID)
        XCTAssertEqual(session.requestedDeadline, 7300); XCTAssertEqual(session.batteryDeadline, 7300)
        XCTAssertNil(session.savedBatteryBudget)
        XCTAssertEqual(session.batteryRemaining(now: 7240), 60)
        session.evaluate(power: .battery, now: 7241)
        XCTAssertEqual(session.batteryRemaining(now: 7241), 59)
        XCTAssertEqual(session.effectiveDeadline, 7300)
    }

    func testLegacyTimeLimitCannotReplaceTheCapturedBatteryDeadline() {
        let limits = UserLimits(batteryFloor: 30, maxHoldHours: 1)
        var session = ManualSessionPolicy(boot: "fixture")
        XCTAssertTrue(session.start(duration: 7200, power: .battery, now: 100, user: limits))
        let originalID = session.requestID
        XCTAssertFalse(session.reschedule(duration: 601, now: 3100, user: limits))
        XCTAssertFalse(session.reschedule(duration: 600, now: 3100, user: limits))
        XCTAssertEqual(session.effectiveDeadline, 7300); XCTAssertEqual(session.batteryDeadline, 7300)
        XCTAssertEqual(session.requestID, originalID)
        session.end()
        XCTAssertFalse(session.start(duration: 10_800, power: .battery, now: 3101,
            user: UserLimits(maxHoldHours: 3)))
    }

    func testBatteryRequestKeepsItsFirstCapDuringACVisitAndIsConsumedByTheNextUnplug() {
        var session = ManualSessionPolicy(boot: "fixture")
        XCTAssertTrue(session.start(duration: 7200, power: .battery, now: 100))
        let originalID = session.requestID
        session.evaluate(power: .ac, now: 500)
        XCTAssertFalse(session.reschedule(duration: 7200, now: 500))
        XCTAssertEqual(session.effectiveDeadline, 7300)
        session.evaluate(power: .unknown, now: 520)
        XCTAssertTrue(session.active); XCTAssertFalse(session.canHold)
        XCTAssertFalse(session.reschedule(duration: 900, now: 521))
        XCTAssertFalse(session.extend(duration: 900, now: 521))
        XCTAssertEqual(session.requestID, originalID)
        XCTAssertEqual(session.effectiveDeadline, 7300)
        session.evaluate(power: .battery, now: 522)
        XCTAssertFalse(session.active)
        XCTAssertEqual(session.endReason, .powerDisconnected)
        XCTAssertNil(session.requestID); XCTAssertNil(session.effectiveDeadline)
        XCTAssertFalse(session.extend(duration: 900, now: 522))
        XCTAssertTrue(session.start(duration: 1800, power: .battery, now: 523))
        XCTAssertNotEqual(session.requestID, originalID)
        XCTAssertEqual(session.startedAt, 523)
        XCTAssertEqual(session.effectiveDeadline, 2323)
        XCTAssertEqual(session.batteryDeadline, 7723)
    }

    func testMalformedBackwardAndArbitraryEditsPreserveTheRequestWhileApprovedExtensionsKeepItsIdentity() {
        var session = ManualSessionPolicy(boot: "fixture")
        XCTAssertTrue(session.start(duration: 3600, power: .ac, now: 100))
        for (duration, now) in [(Double.nan, 200.0), (.infinity, 200), (0, 200), (-1, 200),
                                (86_401, 200), (900, .nan), (900, 99), (60, 200)] {
            let previous = session
            XCTAssertFalse(session.reschedule(duration: duration, now: now))
            XCTAssertFalse(session.extend(duration: duration, now: now))
            XCTAssertEqual(session, previous)
        }
        let originalID = session.requestID
        XCTAssertTrue(session.extend(duration: 900, now: 200))
        XCTAssertEqual(session.requestedDeadline, 4600)
        XCTAssertTrue(session.extend(duration: 1800, now: 201))
        XCTAssertEqual(session.requestedDeadline, 6400)
        XCTAssertEqual(session.requestID, originalID)
        XCTAssertEqual(session.startedAt, 100)
    }

    func testAutomaticTriggerSurvivesTheOriginalManualExpiryAfterRetimingIsRejected() {
        var policy = IdleSessionPolicy(boot: "fixture")
        policy.setAutomatic(true)
        policy.evaluate(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: 100)
        XCTAssertTrue(policy.start(duration: 900, now: 100))
        let saved = policy.settings
        XCTAssertFalse(policy.rescheduleManual(duration: 7200, now: 200))
        policy.evaluate(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: 1000)
        XCTAssertFalse(policy.manualActive); XCTAssertTrue(policy.automaticActive)
        XCTAssertEqual(policy.settings, saved); XCTAssertEqual(policy.decision.reasons, [.automatic])
        XCTAssertGreaterThan(policy.expiry ?? 0, 1000)
    }

    func testSavedChoicesDoNotRestoreManualIdentityDeadlineOrConsumedBudget() throws {
        var policy = IdleSessionPolicy(boot: "fixture")
        policy.evaluate(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: 100, batteryPercent: 80)
        XCTAssertTrue(policy.start(duration: 3600, now: 100))
        let originalID = policy.currentBatteryPermitID
        XCTAssertFalse(policy.rescheduleManual(duration: 900, now: 200))
        policy.evaluate(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: 200, batteryPercent: 80)
        XCTAssertEqual(policy.effectiveManualDeadline, 3700)
        let saved = try JSONDecoder().decode(IdleSessionSettings.self, from: JSONEncoder().encode(policy.settings))
        var restarted = IdleSessionPolicy(settings: saved, boot: "fixture")
        restarted.evaluate(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: 200, batteryPercent: 80)
        XCTAssertFalse(restarted.manualActive); XCTAssertNil(restarted.manualDeadline)
        XCTAssertNil(restarted.effectiveManualDeadline); XCTAssertNil(restarted.currentBatteryPermitID)
        XCTAssertEqual(restarted.manualBatteryRemaining, 7200)
        XCTAssertTrue(restarted.start(duration: 3600, now: 200))
        XCTAssertNotEqual(restarted.currentBatteryPermitID, originalID)
        XCTAssertEqual(restarted.effectiveManualDeadline, 3800)
    }
}

/// Retained date utility coverage only; v4 exposes fixed extensions, not arbitrary end-time editing.

final class SessionEndTimeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }
    private func date(_ hour: Int, _ minute: Int, day: Int = 2) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    func testUpcomingTimeTodayAndPassedTimeTomorrow() {
        let now = date(10, 0)
        XCTAssertEqual(SessionEndTime.next(hour: 18, minute: 0, after: now, calendar: calendar), date(18, 0))
        XCTAssertEqual(SessionEndTime.next(hour: 9, minute: 0, after: now, calendar: calendar), date(9, 0, day: 3))
        XCTAssertEqual(SessionEndTime.next(hour: 10, minute: 0, after: now, calendar: calendar), date(10, 0, day: 3))
    }
    func testPastOrOutOfAllowanceTimeDoesNotBecomeUnlimited() {
        let now = date(10, 0)
        XCTAssertEqual(SessionEndTime.duration(until: date(11, 0), now: now, maximum: 3600), 3600)
        XCTAssertNil(SessionEndTime.duration(until: date(9, 0), now: now, maximum: 3600))
        XCTAssertNil(SessionEndTime.duration(until: now, now: now, maximum: 3600))
        XCTAssertNil(SessionEndTime.duration(until: date(12, 0), now: now, maximum: 3600))
        XCTAssertEqual(SessionEndTime.duration(until: date(10, 0, day: 4), now: now, maximum: 172_800), 172_800)
        XCTAssertNil(SessionEndTime.duration(until: Date(timeIntervalSince1970: .nan), now: now, maximum: 3600))
        XCTAssertNil(SessionEndTime.next(hour: 24, minute: 0, after: now, calendar: calendar))
        XCTAssertNil(SessionEndTime.next(hour: 12, minute: 60, after: now, calendar: calendar))
    }
    func testDaylightSavingGapResolvesToActualNextLocalTime() throws {
        var local = Calendar(identifier: .gregorian); local.timeZone = TimeZone(identifier: "America/New_York")!
        let now = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30)))
        let end = try XCTUnwrap(SessionEndTime.next(hour: 2, minute: 30, after: now, calendar: local))
        XCTAssertEqual(local.component(.hour, from: end), 3)
        XCTAssertEqual(local.component(.minute, from: end), 0)
        XCTAssertEqual(SessionEndTime.duration(until: end, now: now, maximum: 7200), 1800)
    }
}
