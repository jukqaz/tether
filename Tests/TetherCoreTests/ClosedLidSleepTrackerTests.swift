import XCTest
@testable import TetherCore

final class ClosedLidSleepTrackerTests: XCTestCase {
    private let owned = Snapshot(power: .ac, lidClosed: false, sleepDisabled: true)
    private let released = Snapshot(power: .battery, lidClosed: true, sleepDisabled: false)

    private func managed() -> ClosedLidSleepTracker {
        var tracker = ClosedLidSleepTracker()
        tracker.recordManagedWork(snapshot: owned, ownsOverride: true, workRequested: true)
        return tracker
    }

    func testReleaseKeepsResponsibilityAfterGlobalOwnershipHasEnded() {
        var tracker = managed()
        XCTAssertTrue(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 100))
        XCTAssertTrue(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 105))
        XCTAssertEqual(tracker.retryDeadline, 100 + IdleSessionPolicy.healthTTL)
        XCTAssertEqual(Policy.actions(for: released, triggers: [.timer], enabled: true, sleepNowPending: false,
            ownsOverride: false, releaseNeedsSleep: true), [.sleepSystem])
    }

    func testNativeHandoffPreservesOnlyPreviouslyManagedWork() {
        var native = Snapshot(power: .ac, lidClosed: false, sleepDisabled: false, externalDisplay: true)
        native.nativeDisplayVerified = true
        var tracker = managed()
        XCTAssertFalse(tracker.update(snapshot: native, ownsOverride: false, workRequested: true, now: 100))
        native.lidClosed = true
        XCTAssertFalse(tracker.update(snapshot: native, ownsOverride: false, workRequested: true, now: 101))
        XCTAssertTrue(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 102))
        var nativeOnly = ClosedLidSleepTracker()
        XCTAssertFalse(nativeOnly.update(snapshot: native, ownsOverride: false, workRequested: true, now: 100))
        XCTAssertFalse(nativeOnly.update(snapshot: released, ownsOverride: false, workRequested: false, now: 102))
    }

    func testOpeningOrPowerReturnCannotExecuteTheOldSleep() {
        for changed in [Snapshot(power: .battery, lidClosed: false, sleepDisabled: false),
                        Snapshot(power: .ac, lidClosed: true, sleepDisabled: false)] {
            var tracker = managed()
            XCTAssertTrue(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 100))
            XCTAssertFalse(tracker.update(snapshot: changed, ownsOverride: false, workRequested: false, now: 101))
            XCTAssertNil(tracker.retryDeadline)
            XCTAssertFalse(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 102))
        }
    }

    func testNewBatteryWorkCancelsOldSleepWithoutSpendingItsTime() {
        var tracker = managed()
        XCTAssertTrue(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 100))
        XCTAssertFalse(tracker.update(snapshot: released, ownsOverride: false, workRequested: true, now: 101))
        XCTAssertNil(tracker.retryDeadline)
        XCTAssertFalse(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 102))
    }

    func testForeignGlobalOverrideCancelsOurReleaseResponsibility() {
        var tracker = managed()
        XCTAssertTrue(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 100))
        var foreign = released; foreign.sleepDisabled = true
        XCTAssertFalse(tracker.update(snapshot: foreign, ownsOverride: false, workRequested: false, now: 101))
        XCTAssertFalse(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 102))
    }

    func testUnconfirmedObservationsAndDarkWakeCannotAuthorizeOldSleep() {
        var observations = [released, released, released, released]
        observations[0].power = .unknown
        observations[1].observedLidClosed = nil
        observations[2].observedFullWake = nil
        observations[3].fullWake = false
        for snapshot in observations {
            var tracker = managed()
            XCTAssertFalse(tracker.update(snapshot: snapshot, ownsOverride: false, workRequested: false, now: 100))
            XCTAssertFalse(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 101))
        }
    }

    func testExpiryAndInvalidClockCannotRearmAReleasedSession() {
        for clock in [100 + IdleSessionPolicy.healthTTL, 99, Double.nan, Double.infinity] {
            var tracker = managed()
            XCTAssertTrue(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 100))
            XCTAssertFalse(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: clock))
            XCTAssertFalse(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 200))
        }
    }

    func testSystemSleepResetDoesNotResumeAnOldRequestAfterWake() {
        var tracker = managed()
        XCTAssertTrue(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 100))
        tracker.reset()
        XCTAssertFalse(tracker.update(snapshot: released, ownsOverride: false, workRequested: false, now: 101))
    }
}
