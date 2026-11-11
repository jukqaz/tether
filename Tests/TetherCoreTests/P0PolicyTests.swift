import Foundation
import XCTest
@testable import TetherCore

final class P0PolicyTests: XCTestCase {
    private func observe(_ policy: inout IdleSessionPolicy, _ now: Double,
                         power: PowerSource = .ac, thermal: Int? = 0, battery: Int? = 80,
                         lowMode: Bool? = false, owner: Bool = true) {
        if policy.settings.v4.usesAdvancedAutomaticConditions,
           policy.settings.automaticPowerCondition?.includesBattery == true {
            policy.setV4AutomaticGate(.init(isSatisfied: true, validUntil: now + 15,
                                           reason: "explicit-advanced-fixture"), now: now)
        }
        policy.evaluate(power: power, thermal: thermal, fullWake: true, controllingUser: owner,
            now: now, batteryPercent: battery, lowPowerWarning: false, lowPowerMode: lowMode)
    }
    private func ready(_ settings: IdleSessionSettings = .init(), power: PowerSource = .ac) -> IdleSessionPolicy {
        var policy = IdleSessionPolicy(settings: settings, boot: "p0")
        observe(&policy, 100, power: power); return policy
    }
    private func stable(_ policy: inout IdleSessionPolicy, from start: Double,
                        power: PowerSource = .ac, battery: Int? = 80) {
        for offset in stride(from: 0.0, through: 60.0, by: 10) {
            observe(&policy, start + offset, power: power, battery: battery)
        }
    }
    func testDefaultUnplugConsumesAllAndNeverRestoresManualOnReconnect() {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        var policy = ready(settings)
        XCTAssertTrue(policy.start(duration: 600, now: 100))
        observe(&policy, 101, power: .battery)
        XCTAssertFalse(policy.manualActive); XCTAssertFalse(policy.automaticActive)
        observe(&policy, 102)
        XCTAssertTrue(policy.automaticActive); XCTAssertFalse(policy.manualActive)
    }
    func testEndAutomaticPreservesOnlyEligibleSameManualIdentity() {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        settings.disconnectPolicy = .endAutomatic; settings.automaticPowerCondition = .any
        var policy = ready(settings)
        XCTAssertTrue(policy.start(duration: 600, now: 100)); let id = policy.manualRequestID
        observe(&policy, 101, power: .battery)
        XCTAssertTrue(policy.manualActive); XCTAssertEqual(policy.manualRequestID, id)
        XCTAssertFalse(policy.automaticActive)
        policy.consumeSystemSleep(observedAt: 102); observe(&policy, 103, power: .battery)
        XCTAssertFalse(policy.automaticActive, "A Wake cannot bypass the unplug stop")
    }
    func testContinueEligibleUsesOriginalIdentityAndAnchor() {
        var settings = IdleSessionSettings(); settings.disconnectPolicy = .continueEligible
        var policy = ready(settings)
        XCTAssertTrue(policy.start(duration: 6000, now: 100)); let id = policy.manualRequestID
        observe(&policy, 110, power: .battery)
        XCTAssertEqual(policy.manualRequestID, id); XCTAssertEqual(policy.manualBatteryStartedAt, 110)
        observe(&policy, 120); observe(&policy, 130, power: .battery)
        XCTAssertEqual(policy.manualBatteryDeadline, 7310); XCTAssertEqual(policy.manualRequestID, id)
    }
    func testACExtensionCanCrossBatteryCapWithoutRefillingIt() {
        var manual = ManualSessionPolicy(boot: "p0", disconnectPolicy: .continueEligible)
        XCTAssertTrue(manual.start(duration: 6300, power: .battery, now: 100))
        manual.evaluate(power: .ac, now: 200)
        XCTAssertTrue(manual.extend(duration: 1800, now: 200))
        XCTAssertEqual(manual.requestedDeadline, 8200); XCTAssertEqual(manual.batteryDeadline, 7300)
        manual.evaluate(power: .ac, now: 7300); XCTAssertTrue(manual.active)
        XCTAssertEqual(manual.effectiveDeadline, 8200)
        manual.evaluate(power: .battery, now: 7301)
        XCTAssertFalse(manual.active); XCTAssertEqual(manual.endReason, .batteryBudget)
    }
    func testDefaultLimitChangesAffectOnlyTheNextManualRequest() {
        var policy = ready(power: .battery)
        XCTAssertTrue(policy.start(duration: 3600, now: 100))
        policy.setBatteryTimeLimit(.thirtyMinutes)
        XCTAssertEqual(policy.manualBatteryDeadline, 7300)
        XCTAssertEqual(policy.manualBatteryTimeLimit, .twoHours)
    }
    func testExplicitUnlimitedBatteryStillHasFiniteHealthPermission() {
        var settings = IdleSessionSettings(); settings.batteryTimeLimit = .unlimited
        var policy = ready(settings, power: .battery)
        XCTAssertTrue(policy.start(duration: nil, now: 100)); observe(&policy, 101, power: .battery)
        XCTAssertNil(policy.manualDeadline); XCTAssertNil(policy.manualBatteryDeadline)
        XCTAssertEqual(policy.decision.expiry, 116)
        observe(&policy, 102, power: .battery, thermal: 3)
        XCTAssertFalse(policy.manualActive); XCTAssertNil(policy.expiry)
    }
    func testUnknownRetainsOnlyIssuedExpiryAndBlocksNewAuthorityUntilExactBoundary() {
        var policy = ready()
        XCTAssertTrue(policy.start(duration: 600, now: 100)); observe(&policy, 101)
        let expiry = policy.expiry
        observe(&policy, 102, power: .unknown)
        XCTAssertTrue(policy.manualActive); XCTAssertEqual(policy.expiry, expiry)
        XCTAssertFalse(policy.decision.renewalAllowed); XCTAssertFalse(policy.canExtend(duration: 900, now: 102))
        observe(&policy, 115, power: .unknown); XCTAssertTrue(policy.manualActive)
        observe(&policy, 116, power: .unknown)
        XCTAssertFalse(policy.manualActive); XCTAssertEqual(policy.markers.protectionReason, "sensor")
        observe(&policy, 117); XCTAssertFalse(policy.manualActive); XCTAssertNil(policy.expiry)
    }
    func testShortUnknownIsNotAnUnplugButKnownBatteryStillConsumesOnce() {
        var policy = ready(); XCTAssertTrue(policy.start(duration: 600, now: 100))
        observe(&policy, 101); let id = policy.manualRequestID
        observe(&policy, 102, power: .unknown); observe(&policy, 103)
        XCTAssertEqual(policy.manualRequestID, id)
        observe(&policy, 104, power: .unknown); observe(&policy, 105, power: .battery)
        XCTAssertFalse(policy.manualActive); XCTAssertEqual(policy.manualEndReason, .powerDisconnected)
    }
    func testKnownOwnerLossAndThermalHazardNeverReceiveUnknownGrace() {
        for ownerLoss in [false, true] {
            var policy = ready(); XCTAssertTrue(policy.start(duration: 600, now: 100)); observe(&policy, 101)
            observe(&policy, 102, power: .unknown, thermal: ownerLoss ? nil : 3, owner: !ownerLoss)
            XCTAssertFalse(policy.manualActive); XCTAssertNil(policy.expiry)
        }
    }
    func testAutomaticOffDuringUnknownKeepsOnlyManualWorkAndItsCapturedOutputs() {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        settings.allowClosedLid = true; settings.keepDisplayAwake = true
        settings.v4.nextManualOptions = .init(display: false, closedLid: false)
        var policy = ready(settings)
        XCTAssertTrue(policy.start(duration: 600, now: 100)); observe(&policy, 101)
        let id = policy.manualRequestID, deadline = policy.manualDeadline, expiry = policy.expiry
        XCTAssertTrue(policy.decision.displayRequired); XCTAssertTrue(policy.decision.closedLidRequired)

        policy.setAutomatic(false); observe(&policy, 102, thermal: nil)
        XCTAssertTrue(policy.manualActive); XCTAssertEqual(policy.manualRequestID, id)
        XCTAssertEqual(policy.manualDeadline, deadline); XCTAssertEqual(policy.expiry, expiry)
        XCTAssertEqual(policy.decision.reasons, [.manual]); XCTAssertFalse(policy.automaticActive)
        XCTAssertNil(policy.decision.automaticRequestID)
        XCTAssertFalse(policy.decision.displayRequired); XCTAssertFalse(policy.decision.closedLidRequired)
        XCTAssertFalse(policy.decision.renewalAllowed)
    }
    func testOutputOptOutDuringUnknownReleasesOnlyThoseOutputsWithoutRenewal() {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        settings.allowClosedLid = true; settings.keepDisplayAwake = true
        var policy = ready(settings)
        let id = policy.automaticRequestID, expiry = policy.expiry
        XCTAssertTrue(policy.decision.displayRequired); XCTAssertTrue(policy.decision.closedLidRequired)

        policy.setAllowClosedLid(false); policy.setKeepDisplayAwake(false)
        observe(&policy, 101, power: .unknown)
        XCTAssertTrue(policy.automaticActive); XCTAssertEqual(policy.automaticRequestID, id)
        XCTAssertEqual(policy.expiry, expiry); XCTAssertTrue(policy.decision.generalAssertionRequired)
        XCTAssertFalse(policy.decision.displayRequired); XCTAssertFalse(policy.decision.closedLidRequired)
        XCTAssertFalse(policy.decision.renewalAllowed)
    }
    func testOutputOptInDuringUnknownCannotExpandThePreviouslyIssuedPermission() {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        var policy = ready(settings)
        let id = policy.automaticRequestID, expiry = policy.expiry

        policy.setAllowClosedLid(true); policy.setKeepDisplayAwake(true)
        observe(&policy, 101, thermal: nil)
        XCTAssertTrue(policy.automaticActive); XCTAssertEqual(policy.automaticRequestID, id)
        XCTAssertEqual(policy.expiry, expiry)
        XCTAssertFalse(policy.decision.displayRequired); XCTAssertFalse(policy.decision.closedLidRequired)
        XCTAssertFalse(policy.decision.renewalAllowed)
    }
    func testUnknownThermalOnACDoesNotEnforceOrShortenTheCapturedBatteryCap() {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        settings.automaticPowerCondition = .any; settings.disconnectPolicy = .continueEligible
        settings.v4.automaticMode = .advanced
        var policy = ready(settings, power: .battery)
        let id = policy.automaticRequestID, cap = policy.automaticBatteryDeadline
        XCTAssertEqual(cap, 7300)
        observe(&policy, 7290)
        XCTAssertEqual(policy.expiry, 7305)
        observe(&policy, 7295, thermal: nil)
        XCTAssertEqual(policy.expiry, 7305, "A battery-only cap cannot shorten already issued AC work")
        observe(&policy, 7300, thermal: nil)
        XCTAssertTrue(policy.automaticActive); XCTAssertEqual(policy.automaticRequestID, id)
        XCTAssertNil(policy.markers.protectionReason)
        XCTAssertFalse(policy.markers.automaticActivation?.batteryExpired ?? true)
        XCTAssertEqual(policy.expiry, 7305); XCTAssertFalse(policy.decision.renewalAllowed)

        observe(&policy, 7301)
        XCTAssertTrue(policy.automaticActive); XCTAssertEqual(policy.automaticBatteryDeadline, cap)
        observe(&policy, 7302, power: .battery)
        XCTAssertFalse(policy.automaticActive)
        XCTAssertEqual(policy.markers.automaticActivation?.batteryExpired, true)
    }
    func testExplicitSleepLatchSurvivesWakeAndFailureUntilNewRealEvent() {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        var policy = ready(settings); policy.pauseForUserSleep(now: 101)
        observe(&policy, 102); XCTAssertEqual(policy.markers.pauseReason, .userSleep)
        policy.consumeSystemSleep(observedAt: 103); observe(&policy, 104)
        XCTAssertEqual(policy.markers.pauseReason, .userSleep); XCTAssertFalse(policy.automaticActive)
        observe(&policy, 105, power: .battery); observe(&policy, 106)
        XCTAssertNil(policy.markers.pauseReason); XCTAssertTrue(policy.automaticActive)
    }
    func testConditionEdgeObservedBeforeExplicitSleepCannotClearItsRestartBlock() {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        settings.v4.automaticMode = .advanced
        var policy = ready(settings)
        policy.setV4AutomaticGate(.init(isSatisfied: false, validUntil: 200, reason: "not running"), now: 101)
        policy.setV4AutomaticGate(.init(isSatisfied: true, validUntil: 200, reason: "running"), now: 102)
        policy.pauseForUserSleep(now: 102)
        observe(&policy, 103)
        XCTAssertEqual(policy.markers.pauseReason, .userSleep)
        XCTAssertFalse(policy.automaticActive, "An old unprocessed edge is not a new post-Sleep event")

        policy.setV4AutomaticGate(.init(isSatisfied: false, validUntil: 200, reason: "not running"), now: 104)
        observe(&policy, 104)
        policy.setV4AutomaticGate(.init(isSatisfied: true, validUntil: 200, reason: "running"), now: 105)
        observe(&policy, 105)
        XCTAssertNil(policy.markers.pauseReason); XCTAssertTrue(policy.automaticActive)
    }
    func testStopAllSurvivesFreshPowerEvents() {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        var policy = ready(settings); policy.stopCurrent()
        observe(&policy, 101, power: .battery); observe(&policy, 102)
        XCTAssertEqual(policy.markers.pauseReason, .userStop); XCTAssertFalse(policy.automaticActive)
    }
    func testOrdinaryWakeUsesNewAutomaticIDAndOriginalBatteryCap() {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        settings.automaticPowerCondition = .any; settings.disconnectPolicy = .continueEligible
        settings.v4.automaticMode = .advanced
        var policy = ready(settings, power: .battery)
        let first = policy.automaticRequestID, deadline = policy.automaticBatteryDeadline
        XCTAssertNotNil(first); XCTAssertEqual(deadline, 7300)
        policy.consumeSystemSleep(observedAt: 110); observe(&policy, 120, power: .battery)
        XCTAssertTrue(policy.automaticActive); XCTAssertNotEqual(policy.automaticRequestID, first)
        XCTAssertEqual(policy.automaticBatteryDeadline, deadline)
        observe(&policy, 7300, power: .battery)
        policy.consumeSystemSleep(observedAt: 7301); observe(&policy, 7302, power: .battery)
        XCTAssertFalse(policy.automaticActive)
    }
    func testBatteryDisconnectStartFlagCannotCreateNewAutomaticWork() {
        for explicitStart in [false, true] {
            var settings = IdleSessionSettings(); settings.automaticEnabled = true
            settings.automaticPowerCondition = .battery; settings.disconnectPolicy = .continueEligible
            settings.v4.automaticMode = .advanced
            settings.startAutomaticOnBatteryDisconnect = explicitStart
            var policy = ready(settings); observe(&policy, 101, power: .battery)
            XCTAssertFalse(policy.automaticActive)
            XCTAssertEqual(policy.settings.startAutomaticOnBatteryDisconnect, explicitStart)
        }
    }
    func testWakeReceiptCannotConsumeNewExecutionUsingTheOldActivationAnchor() throws {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        settings.automaticPowerCondition = .any; settings.disconnectPolicy = .continueEligible
        settings.v4.automaticMode = .advanced
        var policy = ready(settings, power: .battery)
        let oldID = try XCTUnwrap(policy.decision.batteryPermitID)
        XCTAssertTrue(policy.recordBatteryPermitIssued(id: oldID, now: 100))
        policy.consumeSystemSleep(observedAt: 110); observe(&policy, 120, power: .battery)
        let newID = try XCTUnwrap(policy.decision.batteryPermitID)
        XCTAssertNotEqual(newID, oldID)
        XCTAssertTrue(policy.recordBatteryPermitIssued(id: newID, now: 120))
        XCTAssertTrue(policy.acceptBatteryPermit(id: newID, observedAt: 120, deadline: 7320, now: 120))
        XCTAssertTrue(policy.automaticActive); XCTAssertEqual(policy.automaticBatteryDeadline, 7300)
    }
    func testExplicitCriticalOnlyThermalOptionNeverDisablesCriticalProtection() {
        var settings = IdleSessionSettings(); settings.stopOnSeriousThermal = false
        var policy = ready(settings)
        observe(&policy, 101, thermal: 2)
        XCTAssertTrue(policy.start(duration: 1800, now: 101))
        observe(&policy, 102, thermal: 2)
        XCTAssertTrue(policy.manualActive); XCTAssertTrue(policy.canExtend(duration: 900, now: 102))
        observe(&policy, 103, thermal: 3)
        XCTAssertFalse(policy.manualActive); XCTAssertEqual(policy.markers.protectionReason, "thermal")
    }
    func testProtectionNeedsSixtySecondsOfFreshThermalAndPowerSamples() {
        var policy = ready(); XCTAssertTrue(policy.start(duration: 600, now: 100))
        observe(&policy, 101, thermal: 2)
        stable(&policy, from: 102)
        XCTAssertTrue(policy.canResume(thermal: 0)); XCTAssertTrue(policy.resume(thermal: 0))
        XCTAssertFalse(policy.manualActive, "A spent manual request is never resumed")
    }
    func testUnknownGapAndSleepResetProtectionRecoveryWindow() {
        var policy = ready(); policy.acceptProtection("thermal")
        for now in [101.0, 111, 121, 131] { observe(&policy, now) }
        observe(&policy, 132, thermal: nil); observe(&policy, 141)
        XCTAssertFalse(policy.canResume(thermal: 0))
        observe(&policy, 161); XCTAssertFalse(policy.canResume(thermal: 0), "Gap > 15s breaks stability")
        policy.consumeSystemSleep(observedAt: 162)
        stable(&policy, from: 163)
        XCTAssertTrue(policy.canResume(thermal: 0))
    }
    func testACRecoveryRequiresSelectedLowPowerModeConditionToClear() {
        var settings = IdleSessionSettings(); settings.v4.stopOnLowPowerMode = true
        var policy = ready(settings); policy.acceptProtection("thermal")
        for now in stride(from: 101.0, through: 171.0, by: 10) { observe(&policy, now, lowMode: true) }
        XCTAssertFalse(policy.canResume(thermal: 0))
        observe(&policy, 172, lowMode: nil); XCTAssertFalse(policy.canResume(thermal: 0))
        stable(&policy, from: 173); XCTAssertTrue(policy.canResume(thermal: 0))
    }
    func testOptionalAutomaticRecoveryPreservesActivationBudgetAndNeverRevivesManual() {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        settings.automaticPowerCondition = .any; settings.disconnectPolicy = .continueEligible
        settings.v4.automaticMode = .advanced
        settings.automaticallyResumeAfterProtection = true
        var policy = ready(settings, power: .battery)
        XCTAssertTrue(policy.start(duration: 600, now: 100)); let cap = policy.automaticBatteryDeadline
        observe(&policy, 101, power: .battery, thermal: 2)
        stable(&policy, from: 102, power: .battery)
        XCTAssertTrue(policy.automaticActive); XCTAssertFalse(policy.manualActive)
        XCTAssertEqual(policy.automaticBatteryDeadline, cap)
    }
    func testVersionSixLegacyPowerChoiceCannotBecomeBatteryPermissionDuringMigration() throws {
        var old = IdleSessionSettings(); old.version = 6; old.powerCondition = .any; old.automaticEnabled = true
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(IdleSessionSettings.self, from: data)
        let migrated = try XCTUnwrap(decoded.migratedToCurrentVersion)
        XCTAssertEqual(migrated.condition, .ac); XCTAssertEqual(migrated.powerCondition, .any)
        XCTAssertEqual(migrated.disconnectPolicy, .endAll); XCTAssertEqual(migrated.batteryTimeLimit, .twoHours)
    }
    func testCurrentSchemaLegacyBatteryChoiceCannotBecomeACPermissionWithoutExplicitSelection() {
        var settings = IdleSessionSettings(); settings.powerCondition = .battery; settings.automaticEnabled = true
        var policy = ready(settings)
        XCTAssertFalse(policy.settings.automaticEnabled); XCTAssertFalse(policy.automaticActive)
        policy.setAutomatic(true); observe(&policy, 101)
        XCTAssertEqual(policy.settings.automaticPowerCondition, .ac); XCTAssertTrue(policy.automaticActive)
        var restarted = IdleSessionPolicy(settings: policy.settings, boot: "p0")
        observe(&restarted, 102)
        XCTAssertTrue(restarted.settings.automaticEnabled); XCTAssertTrue(restarted.automaticActive)
    }
}
