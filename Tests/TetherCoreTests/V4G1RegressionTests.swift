import Foundation
import XCTest
@testable import TetherCore

final class V4G1RegressionTests: XCTestCase {
    private func observe(_ policy: inout IdleSessionPolicy, _ power: PowerSource = .ac, at now: Double) {
        policy.evaluate(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: now, batteryPercent: 80, lowPowerWarning: false)
    }
    private func ready(_ power: PowerSource = .ac, automatic: Bool = false) -> IdleSessionPolicy {
        var settings = IdleSessionSettings(); settings.automaticEnabled = automatic
        var policy = IdleSessionPolicy(settings: settings, boot: "v4-g1")
        observe(&policy, power, at: 100); return policy
    }

    func testEveryDepartureConsumesLegacyContinuationAndBatteryOriginRoundTrips() {
        for legacy in [Int?.none, 30, 120] {
            var manual = ManualSessionPolicy(batteryContinuationMinutes: legacy, boot: "v4-g1")
            XCTAssertTrue(manual.start(duration: nil, power: .ac, now: 100))
            manual.evaluate(power: .unknown, now: 101)
            manual.evaluate(power: .battery, now: 102)
            XCTAssertFalse(manual.active); XCTAssertEqual(manual.endReason, .powerDisconnected)
            manual.evaluate(power: .ac, now: 103); XCTAssertFalse(manual.active)
        }
        var policy = ready(.battery)
        XCTAssertTrue(policy.start(duration: 1800, now: 100))
        let id = policy.manualRequestID
        observe(&policy, .ac, at: 101)
        XCTAssertEqual(policy.manualRequestID, id)
        XCTAssertEqual(policy.manualDeadline, 1900)
        observe(&policy, .battery, at: 102)
        XCTAssertFalse(policy.manualActive)
        XCTAssertEqual(policy.manualEndReason, .powerDisconnected)
        XCTAssertTrue(policy.start(duration: 1800, now: 102))
        XCTAssertNotEqual(policy.manualRequestID, id)
    }

    func testBatteryExtensionKeepsFirstCapButACMayExtendTheOriginalRequestPastIt() {
        var policy = ready(.battery)
        XCTAssertTrue(policy.start(duration: 1800, now: 100))
        let id = policy.manualRequestID
        for (index, amount) in [900.0, 1800, 1800, 900].enumerated() {
            observe(&policy, index == 0 ? .battery : .ac, at: 101 + Double(index))
            XCTAssertTrue(policy.extend(duration: amount, now: 101 + Double(index)))
            XCTAssertEqual(policy.manualRequestID, id)
            XCTAssertEqual(policy.manualBatteryDeadline, 7300)
        }
        XCTAssertEqual(policy.manualDeadline, 7300)
        XCTAssertTrue(policy.canExtend(duration: 900, now: 104))
        XCTAssertTrue(policy.extend(duration: 900, now: 104))
        XCTAssertEqual(policy.manualDeadline, 8200); XCTAssertEqual(policy.manualBatteryDeadline, 7300)
        XCTAssertFalse(policy.extend(duration: 420, now: 104))
        observe(&policy, .ac, at: 7300)
        XCTAssertTrue(policy.manualActive)
        observe(&policy, .ac, at: 8200)
        XCTAssertFalse(policy.manualActive)
    }

    func testPreparationDoesNotExtendAndCommitCopiesOnlyCurrentManualRevision() throws {
        var policy = ready()
        XCTAssertTrue(policy.start(duration: 1800, now: 100))
        let original = policy
        var proposed = policy
        XCTAssertTrue(proposed.extend(duration: 900, now: 100))
        let extensionID = try XCTUnwrap(proposed.manualExtensionID)
        XCTAssertEqual(policy.manualDeadline, 1900)
        policy.setAutomatic(true)
        XCTAssertTrue(policy.commitPreparedManualExtension(proposed, now: 101))
        XCTAssertEqual(policy.manualDeadline, 2800)
        XCTAssertTrue(policy.settings.automaticEnabled)
        XCTAssertTrue(policy.restoreManualRevision(from: original, expectedExtensionID: extensionID, now: 102))
        XCTAssertEqual(policy.manualDeadline, 1900)
        XCTAssertTrue(policy.settings.automaticEnabled)
        policy.endManual(); observe(&policy, at: 103)
        XCTAssertTrue(policy.start(duration: 600, now: 103))
        let newID = policy.manualRequestID
        XCTAssertFalse(policy.restoreManualRevision(from: original, expectedExtensionID: extensionID, now: 103))
        XCTAssertEqual(policy.manualRequestID, newID)
    }

    func testPreparedExtensionPreservesExactDeadlineAcrossContinuousClockPrecisionBoundary() throws {
        for (start, duration) in [(30_070.0.nextUp, 900.0), (29_370.0.nextUp, 1_800.0)] {
            var policy = ready()
            observe(&policy, at: start)
            XCTAssertTrue(policy.start(duration: 1_800, now: start))
            let original = try XCTUnwrap(policy.manualDeadline)
            let expected = original + duration
            XCTAssertNotEqual(expected - original, duration,
                              "Crossing the 32,768-second precision boundary makes subtraction inexact")

            var proposed = policy
            XCTAssertTrue(proposed.extend(duration: duration, now: start + 1))
            let preparation = WorkSessionExtensionPreparation(id: try XCTUnwrap(proposed.manualExtensionID),
                requestID: try XCTUnwrap(policy.manualRequestID), currentDeadline: original,
                proposedDeadline: try XCTUnwrap(proposed.manualDeadline), expiresAt: start + 5)
            XCTAssertEqual(preparation.proposedDeadline, expected)
            XCTAssertTrue(preparation.isValid(now: start + 1))
            XCTAssertEqual(policy.manualDeadline, original)

            var unapproved = preparation
            unapproved.proposedDeadline = expected.nextUp
            XCTAssertFalse(unapproved.isValid(now: start + 1), "Even one representable step past the approved deadline must fail")
            unapproved.proposedDeadline = original + 420
            XCTAssertFalse(unapproved.isValid(now: start + 1))
            XCTAssertFalse(policy.extend(duration: 420, now: start + 1))

            XCTAssertTrue(policy.commitPreparedManualExtension(proposed, now: start + 2))
            XCTAssertEqual(policy.manualDeadline, expected)
        }
    }

    func testLateBatteryAcknowledgementCannotShortenAnApprovedExtension() throws {
        var policy = ready(.battery)
        XCTAssertTrue(policy.start(duration: 1800, now: 100))
        observe(&policy, .battery, at: 101)
        let id = try XCTUnwrap(policy.decision.batteryPermitID)
        XCTAssertTrue(policy.recordBatteryPermitIssued(id: id, now: 101))
        XCTAssertTrue(policy.extend(duration: 900, now: 101))
        XCTAssertFalse(policy.acceptBatteryPermit(id: id, observedAt: 101, deadline: 1900, now: 102))
        XCTAssertEqual(policy.manualDeadline, 2800)
    }

    func testAutomaticIsACOnlyAndOldBatteryOnlyMigrationDoesNotBecomeACOn() throws {
        for condition in [PowerCondition.ac, .battery, .any] {
            var settings = IdleSessionSettings(); settings.automaticEnabled = true; settings.powerCondition = condition
            var policy = IdleSessionPolicy(settings: settings, boot: "v4-g1")
            observe(&policy, .battery, at: 100)
            XCTAssertFalse(policy.automaticActive); XCTAssertNil(policy.expiry)
        }
        var old = IdleSessionSettings(); old.version = 5; old.powerCondition = .battery
        old.automaticEnabled = true; old.allowClosedLid = true; old.keepDisplayAwake = true
        old.runtimeMarkers = RuntimeMarkers(pauseReason: .userStop, protectionReason: "thermal")
        let migrated = try XCTUnwrap(old.migratedToCurrentVersion)
        XCTAssertFalse(migrated.automaticEnabled)
        XCTAssertTrue(migrated.allowClosedLid); XCTAssertTrue(migrated.keepDisplayAwake)
        XCTAssertEqual(migrated.runtimeMarkers, old.runtimeMarkers)
    }

    func testAdvancedUnknownNeverFallsBackAndPreservesUnrelatedManual() {
        var policy = ready(automatic: true)
        var settings = policy.settings.v4; settings.automaticMode = .advanced
        XCTAssertTrue(policy.setV4Settings(settings))
        observe(&policy, at: 101)
        XCTAssertFalse(policy.automaticActive)
        XCTAssertTrue(policy.start(duration: 600, now: 101))
        policy.setV4AutomaticGate(.init(isSatisfied: true, validUntil: 105, reason: "selected"), now: 101)
        observe(&policy, at: 102); XCTAssertTrue(policy.automaticActive)
        observe(&policy, at: 105)
        XCTAssertFalse(policy.automaticActive); XCTAssertTrue(policy.manualActive)
    }

    func testManualChoicesAreCapturedAndGlobalSwitchOnlyCapsExecution() {
        var policy = ready()
        XCTAssertTrue(policy.start(duration: 600, now: 100))
        observe(&policy, at: 101)
        XCTAssertFalse(policy.decision.closedLidRequired); XCTAssertFalse(policy.decision.displayRequired)
        policy.setAllowClosedLid(true); policy.setKeepDisplayAwake(true)
        var settings = policy.settings.v4; settings.nextManualOptions = .init(display: false, closedLid: false)
        XCTAssertTrue(policy.setV4Settings(settings))
        observe(&policy, at: 102)
        XCTAssertTrue(policy.decision.closedLidRequired); XCTAssertTrue(policy.decision.displayRequired)
        policy.setAllowClosedLid(false); policy.setKeepDisplayAwake(false)
        observe(&policy, at: 103)
        XCTAssertFalse(policy.decision.closedLidRequired); XCTAssertFalse(policy.decision.displayRequired)
        XCTAssertEqual(policy.manualDeadline, 700)
    }

    func testSleepOwnerEndAndReconnectNeverRestoreManual() {
        var policy = ready(automatic: true)
        XCTAssertTrue(policy.start(duration: 600, now: 100))
        policy.consumeSystemSleep(observedAt: 101)
        observe(&policy, at: 102)
        XCTAssertFalse(policy.manualActive); XCTAssertTrue(policy.automaticActive)
        XCTAssertTrue(policy.start(duration: 600, now: 102))
        policy.loseGUIAuthority(); observe(&policy, at: 103)
        XCTAssertFalse(policy.manualActive); XCTAssertFalse(policy.automaticActive)
        observe(&policy, .battery, at: 104); observe(&policy, .ac, at: 105)
        XCTAssertFalse(policy.manualActive)
    }

    func testNewManualAndExtensionNeedConfirmedFullWakeAndCurrentOwner() {
        var policy = ready()
        policy.evaluate(power: .ac, thermal: 0, fullWake: false, controllingUser: true, now: 101)
        XCTAssertFalse(policy.start(duration: 600, now: 101))
        observe(&policy, at: 102)
        XCTAssertTrue(policy.start(duration: 600, now: 102))
        policy.evaluate(power: .ac, thermal: 0, fullWake: nil, controllingUser: true, now: 103)
        XCTAssertFalse(policy.canExtend(duration: 900, now: 103))
        XCTAssertFalse(policy.extend(duration: 900, now: 103))
        XCTAssertEqual(policy.manualDeadline, 702)
        policy.evaluate(power: .ac, thermal: 0, fullWake: true, controllingUser: false, now: 104)
        XCTAssertFalse(policy.start(duration: 600, now: 104))
        observe(&policy, at: 105)
        XCTAssertTrue(policy.start(duration: 600, now: 105))
    }

    func testRetriesFitOneTerminalWindowAndSkipMissedSlots() {
        XCTAssertEqual(SleepRequestPolicy.nextRestoreRetry(observedAt: 100, failedAttempts: 1, now: 100), 102)
        XCTAssertEqual(SleepRequestPolicy.nextRestoreRetry(observedAt: 100, failedAttempts: 2, now: 102), 105)
        XCTAssertEqual(SleepRequestPolicy.nextRestoreRetry(observedAt: 100, failedAttempts: 3, now: 105), 135)
        XCTAssertEqual(SleepRequestPolicy.nextRestoreRetry(observedAt: 100, failedAttempts: 1, now: 103), 105)
        XCTAssertEqual(SleepRequestPolicy.nextRestoreRetry(observedAt: 100, failedAttempts: 1, now: 161), 191,
                       "Late ownership recovery remains useful, but cannot issue the expired end action")
    }

    func testExtensionWirePreparationIsBoundToOldRequestDeadlineAndClock() {
        var settings = IdleSessionSettings(); settings.allowClosedLid = true
        let request = UUID(), session = UUID(), extensionID = UUID()
        let old = WorkSessionLease(sessionID: session, sequence: 1, power: .ac, expiry: 115,
            reasons: [.manual], manualDeadline: 700, settings: settings, manualRequestID: request,
            manualBatteryMaximumDeadline: 1200)
        var prepared = old; prepared.sequence = 2
        let pending = WorkSessionExtensionPreparation(id: extensionID, requestID: request,
            currentDeadline: 700, proposedDeadline: 1600, expiresAt: 105)
        prepared.extensionPreparation = pending
        XCTAssertTrue(pending.matches(current: old, incoming: prepared, now: 100), "AC may extend without resetting the battery cap")
        var battery = old; battery.power = .battery
        var batteryPreparation = prepared; batteryPreparation.power = .battery
        XCTAssertFalse(pending.matches(current: battery, incoming: batteryPreparation, now: 100), "The captured ceiling is still enforced on battery")
        var uncapped = old; uncapped.manualBatteryMaximumDeadline = nil
        XCTAssertTrue(pending.matches(current: uncapped, incoming: prepared, now: 100))
        XCTAssertFalse(pending.isValid(now: 105))
        var commit = uncapped; commit.sequence = 3; commit.manualDeadline = 1600; commit.manualExtensionID = extensionID
        let receipt = WorkSessionExtensionPreparationReceipt(sessionID: session, sequence: 2,
            observedAt: 100, preparation: pending)
        prepared.manualBatteryMaximumDeadline = nil
        XCTAssertTrue(receipt.permitsCommit(current: prepared, incoming: commit, now: 101))
        commit.manualRequestID = UUID()
        XCTAssertFalse(receipt.permitsCommit(current: prepared, incoming: commit, now: 101))
    }
}
