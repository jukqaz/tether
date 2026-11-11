import XCTest
@testable import TetherCore

/// Surviving v3 safety contracts plus explicit retirement of battery automation.
/// Deterministic policy transitions never prove physical Sleep or hardware behavior.
final class V3SessionTests: XCTestCase {
    private func ready(_ power: PowerSource = .ac, condition: PowerCondition = .ac,
                       automatic: Bool = false, at now: Double = 100) -> IdleSessionPolicy {
        var settings = IdleSessionSettings()
        settings.automaticEnabled = automatic; settings.powerCondition = condition
        var policy = IdleSessionPolicy(settings: settings, boot: "v3-contract")
        observe(&policy, power: power, at: now)
        return policy
    }
    private func observe(_ policy: inout IdleSessionPolicy, power: PowerSource = .ac,
                         at now: Double, thermal: Int? = 0, awake: Bool? = true,
                         battery: Int? = 80, lowWarning: Bool? = false) {
        policy.evaluate(power: power, thermal: thermal, fullWake: awake, controllingUser: true,
            now: now, batteryPercent: battery, lowPowerWarning: lowWarning)
    }
    private func restarted(_ policy: IdleSessionPolicy) throws -> IdleSessionPolicy {
        let data = try JSONEncoder().encode(policy.settings)
        return IdleSessionPolicy(settings: try JSONDecoder().decode(IdleSessionSettings.self, from: data), boot: "v3-contract")
    }
    func testR3_002GeneralManualDecisionDoesNotRequireRoot() {
        var p = ready(); XCTAssertTrue(p.start(duration: 180, now: 100))
        observe(&p, at: 101)
        XCTAssertEqual(p.decision.reasons, [.manual]); XCTAssertTrue(p.decision.generalAssertionRequired)
        XCTAssertFalse(p.settings.allowClosedLid)
    }
    func testR3_003FreshSettingsDoNotActivateEitherExecutor() {
        let p = ready(); XCTAssertFalse(p.settings.automaticEnabled); XCTAssertFalse(p.settings.allowClosedLid)
        XCTAssertFalse(p.decision.generalAssertionRequired); XCTAssertNil(p.expiry)
    }
    func testR3_004ACSupplyDoesNotDependOnChargingOrPercent() {
        var p = ready(automatic: true)
        observe(&p, at: 101, battery: 100); XCTAssertTrue(p.automaticActive)
        observe(&p, at: 102, battery: nil); XCTAssertTrue(p.automaticActive)
    }
    func testR3_007DarkWakeCannotStartOrRenewWork() {
        var p = ready(automatic: true); observe(&p, at: 101, awake: false)
        XCTAssertNil(p.expiry); XCTAssertFalse(p.automaticActive)
        observe(&p, at: 102, awake: nil); XCTAssertNil(p.expiry)
    }
    func testRetiredAnyPowerSettingCannotAuthorizeAutomaticBatteryWork() {
        var p = ready(condition: .any, automatic: true)
        XCTAssertTrue(p.automaticActive)
        observe(&p, power: .battery, at: 110)
        XCTAssertNil(p.batteryDeadline); XCTAssertEqual(p.decision.reasons, [])
        observe(&p, at: 111); XCTAssertEqual(p.decision.reasons, [.automatic])
    }
    func testR3_013DefaultACManualEndsOnUnplug() {
        var p = ready(); XCTAssertTrue(p.start(duration: nil, now: 100))
        observe(&p, power: .battery, at: 101)
        XCTAssertFalse(p.manualActive); XCTAssertEqual(p.manualEndReason, .powerDisconnected); XCTAssertNil(p.expiry)
    }
    func testFirstBatteryACKCanOnlyTightenTheCurrentManualDeadline() throws {
        var p = ready(.battery); XCTAssertTrue(p.start(duration: 1800, now: 100))
        observe(&p, power: .battery, at: 101)
        let permit = try XCTUnwrap(p.decision.batteryPermitID)
        XCTAssertTrue(p.recordBatteryPermitIssued(id: permit, now: 101))
        XCTAssertTrue(p.acceptBatteryPermit(id: permit, observedAt: 101, deadline: 1890, now: 110))
        XCTAssertEqual(p.effectiveManualDeadline, 1890)
        XCTAssertTrue(p.acceptBatteryPermit(id: permit, observedAt: 111, deadline: 1900, now: 112))
        XCTAssertEqual(p.effectiveManualDeadline, 1890); XCTAssertEqual(p.manualBatteryDeadline, 7300)
    }
    func testUnissuedOrPreParticipationReceiptCannotConsumeNewIntent() throws {
        var p = ready(.battery); XCTAssertTrue(p.start(duration: 7200, now: 100))
        observe(&p, power: .battery, at: 101)
        let permit = try XCTUnwrap(p.decision.batteryPermitID)
        XCTAssertFalse(p.acceptBatteryPermit(id: permit, observedAt: 101, deadline: 1900, now: 102))
        XCTAssertTrue(p.recordBatteryPermitIssued(id: permit, now: 101))
        XCTAssertFalse(p.acceptBatteryPermit(id: UUID(), observedAt: 101, deadline: 1900, now: 102))
        XCTAssertFalse(p.acceptBatteryPermit(id: permit, observedAt: 100.5, deadline: 1900, now: 102))
        XCTAssertEqual(p.effectiveManualDeadline, 7300)
    }
    func testEndedPermitHistoryIsFreedAndCannotCapANewManualRequest() throws {
        var p = ready(.battery)
        var first: UUID?
        for index in 0..<129 {
            let now = 100 + Double(index)
            observe(&p, power: .battery, at: now)
            XCTAssertTrue(p.start(duration: 1800, now: now))
            observe(&p, power: .battery, at: now)
            let permit = try XCTUnwrap(p.decision.batteryPermitID)
            if first == nil { first = permit }
            XCTAssertTrue(p.recordBatteryPermitIssued(id: permit, now: now))
            p.endManual()
        }
        XCTAssertFalse(p.recognizesBatteryPermit(id: try XCTUnwrap(first), observedAt: 110))
        observe(&p, power: .battery, at: 230); XCTAssertTrue(p.start(duration: 1800, now: 230))
        XCTAssertFalse(p.acceptBatteryPermit(id: try XCTUnwrap(first), observedAt: 110, deadline: 1900, now: 230))
        XCTAssertEqual(p.manualDeadline, 2030)
    }
    func testOldBatteryACKCannotCrossSleepOrExecutorEnd() throws {
        for systemSleep in [false, true] {
            var p = ready(.battery); XCTAssertTrue(p.start(duration: 1800, now: 100))
            observe(&p, power: .battery, at: 101)
            let permit = try XCTUnwrap(p.decision.batteryPermitID)
            XCTAssertTrue(p.recordBatteryPermitIssued(id: permit, now: 101))
            if systemSleep { p.consumeSystemSleep(observedAt: 102) }
            else { p.consumeExecutorEnd(observedAt: 102) }
            observe(&p, power: .battery, at: 103)
            XCTAssertTrue(p.start(duration: 1800, now: 103))
            let newID = p.manualRequestID
            XCTAssertFalse(p.acceptBatteryPermit(id: permit, observedAt: 101, deadline: 1900, now: 104))
            XCTAssertEqual(p.manualRequestID, newID); XCTAssertEqual(p.manualDeadline, 1903)
            var next = try restarted(p); observe(&next, power: .battery, at: 105)
            XCTAssertFalse(next.manualActive); XCTAssertNil(next.expiry)
        }
    }
    func testR3_015BatteryManualRejectsOverTwoHoursAndFreezesDefaults() {
        var p = ready(.battery)
        XCTAssertFalse(p.start(duration: 10_800, now: 100)); XCTAssertFalse(p.start(duration: nil, now: 100))
        XCTAssertFalse(p.start(duration: 59, now: 100)); XCTAssertTrue(p.start(duration: 7200, now: 100))
        XCTAssertTrue(p.selectManualDuration(10_800)); XCTAssertFalse(p.setManualBatteryContinuationMinutes(30, now: 101))
        observe(&p, power: .battery, at: 102)
        XCTAssertEqual(p.effectiveManualDeadline, 7300); XCTAssertNil(p.manualBatteryContinuationMinutes)
    }
    func testR3_016ManualExpiryKeepsSeparateACAutomaticReason() {
        var p = ready(.battery, automatic: true)
        XCTAssertTrue(p.start(duration: 180, now: 100))
        observe(&p, at: 130); XCTAssertTrue(p.manualActive); XCTAssertTrue(p.automaticActive)
        observe(&p, at: 310); XCTAssertFalse(p.manualActive); XCTAssertTrue(p.automaticActive)
        observe(&p, power: .battery, at: 320); XCTAssertNil(p.expiry); XCTAssertFalse(p.manualActive)
    }
    func testBatteryFirstCeilingSurvivesACVisitButDepartureConsumesTheRequest() {
        var p = ready(.battery); XCTAssertTrue(p.start(duration: 7200, now: 100))
        observe(&p, at: 200); XCTAssertEqual(p.effectiveManualDeadline, 7300)
        observe(&p, at: 201); observe(&p, power: .battery, at: 600)
        XCTAssertFalse(p.manualActive); XCTAssertEqual(p.manualEndReason, .powerDisconnected)
        observe(&p, at: 601); XCTAssertFalse(p.manualActive)
    }
    func testBatteryOnlySavedAutomaticIsRetiredAcrossRestart() throws {
        var p = ready(.battery, condition: .battery, automatic: true)
        observe(&p, power: .battery, at: 3701); XCTAssertNil(p.expiry)
        var next = try restarted(p); observe(&next, at: 3800)
        XCTAssertFalse(next.settings.automaticEnabled); XCTAssertNil(next.expiry)
    }
    func testR3_020EndingOneReasonPreservesTheOther() {
        var p = ready(automatic: true); XCTAssertTrue(p.start(duration: 180, now: 100))
        p.endManual(); observe(&p, at: 101); XCTAssertEqual(p.decision.reasons, [.automatic])
        XCTAssertTrue(p.start(duration: 180, now: 102)); p.setAutomatic(false)
        observe(&p, at: 103); XCTAssertEqual(p.decision.reasons, [.manual]); XCTAssertEqual(p.effectiveManualDeadline, 282)
    }
    func testR3_021GlobalPauseIsDurableAcrossEventsAndRestart() throws {
        var p = ready(automatic: true); XCTAssertTrue(p.start(duration: 180, now: 100)); p.stopCurrent()
        p.setAutomatic(false); p.setAutomatic(true)
        observe(&p, power: .battery, at: 101); observe(&p, at: 102)
        var next = try restarted(p); observe(&next, at: 110)
        XCTAssertNil(next.expiry); XCTAssertEqual(next.markers.pauseReason, .userStop); XCTAssertFalse(next.manualActive)
    }
    func testR3_022SleepConsumesManualInsteadOfPausingItsClock() {
        var p = ready(automatic: true); XCTAssertTrue(p.start(duration: 180, now: 100))
        p.consumeSystemSleep(observedAt: 110); observe(&p, at: 3700)
        XCTAssertFalse(p.manualActive); XCTAssertNil(p.effectiveManualDeadline); XCTAssertTrue(p.automaticActive)
    }
    func testR3_023LockIsNotAnInputThatConsumesManualWork() {
        var p = ready(); XCTAssertTrue(p.start(duration: 180, now: 100)); observe(&p, at: 101)
        XCTAssertTrue(p.manualActive)
        p.consumeSystemSleep(observedAt: 102); observe(&p, at: 103)
        XCTAssertFalse(p.manualActive)
    }
    func testR3_024FairSurvivesAndSeriousLatchesUntilSafeResume() throws {
        var p = ready(automatic: true); XCTAssertTrue(p.start(duration: nil, now: 100))
        observe(&p, at: 101, thermal: 1); XCTAssertTrue(p.manualActive)
        observe(&p, at: 102, thermal: 2); XCTAssertFalse(p.manualActive); XCTAssertNil(p.expiry)
        observe(&p, at: 103, thermal: 0); p.setAutomatic(false); p.setAutomatic(true)
        var next = try restarted(p); observe(&next, at: 104)
        XCTAssertNil(next.expiry); XCTAssertEqual(next.markers.protectionReason, "thermal")
        XCTAssertNil(next.markers.pauseReason)
        XCTAssertFalse(next.resume(thermal: 2)); XCTAssertFalse(next.resume(thermal: 0))
        for now in stride(from: 114.0, through: 164.0, by: 10) { observe(&next, at: now) }
        XCTAssertTrue(next.resume(thermal: 0))
        observe(&next, at: 165); XCTAssertTrue(next.automaticActive); XCTAssertFalse(next.manualActive)
    }
    func testR3_025BatteryReserveAndOSWarningConsumeManualException() {
        for warning in [false, true] {
            var p = ready(.battery); XCTAssertTrue(p.start(duration: 7200, now: 100))
            observe(&p, power: .battery, at: 101, battery: warning ? 80 : 19, lowWarning: warning)
            XCTAssertFalse(p.manualActive); XCTAssertNil(p.expiry); XCTAssertEqual(p.markers.protectionReason, "battery")
        }
    }
    func testR3_026UnknownObservationsNeverBecomeHealthyValues() {
        var p = ready(automatic: true)
        observe(&p, power: .unknown, at: 101)
        XCTAssertEqual(p.expiry, 115); XCTAssertFalse(p.decision.renewalAllowed)
        observe(&p, at: 102, thermal: nil); XCTAssertNil(p.markers.protectionReason)
        observe(&p, at: 115, thermal: nil)
        XCTAssertNil(p.expiry); XCTAssertEqual(p.markers.protectionReason, "sensor")
        var battery = ready(.battery); XCTAssertTrue(battery.start(duration: 180, now: 100))
        observe(&battery, power: .battery, at: 101, battery: nil); XCTAssertNil(battery.expiry)
        XCTAssertTrue(battery.manualActive)
        observe(&battery, power: .battery, at: 115, battery: nil)
        XCTAssertEqual(battery.markers.protectionReason, "sensor")
    }
    func testR3_031RepeatedUnrelatedObservationsDoNotChangeRequestDeadline() {
        var p = ready(); XCTAssertTrue(p.start(duration: 180, now: 100))
        for now in [101.0, 110, 150, 170] { observe(&p, at: now); XCTAssertEqual(p.effectiveManualDeadline, 280) }
        observe(&p, at: 281); XCTAssertFalse(p.manualActive)
    }
    func testR3_040MigrationPreservesStopsChoicesAndDiscardsLedgers() throws {
        var old = IdleSessionSettings(); old.version = 4; old.enabled = false; old.blockReason = "thermal"
        old.automaticHoldMinutes = 240; old.powerCondition = .any
        var ledger = ProtectionState(); ledger.prepareBatteryBudget(power: .battery, needed: true, clock: 1, boot: "v3-contract")
        old.manualBatteryBudget = ledger; old.automaticBatteryBudget = ledger
        let migrated = try XCTUnwrap(old.migratedToCurrentVersion)
        XCTAssertFalse(migrated.enabled); XCTAssertFalse(migrated.automaticEnabled)
        XCTAssertEqual(migrated.condition, .ac); XCTAssertEqual(migrated.automaticMinutes, 120)
        XCTAssertEqual(migrated.powerCondition, .any, "The saved choice remains migration evidence")
        XCTAssertEqual(migrated.runtimeMarkers?.protectionReason, "thermal")
        XCTAssertNil(migrated.manualBatteryBudget); XCTAssertNil(migrated.automaticBatteryBudget)
    }
    func testR3_047OwnSleepPauseSurvivesWakeUntilANewConfirmedPowerEvent() {
        var p = ready(automatic: true); XCTAssertTrue(p.start(duration: 180, now: 100))
        p.pauseForUserSleep(now: 101); observe(&p, at: 102)
        XCTAssertEqual(p.markers.pauseReason, .userSleep); XCTAssertNil(p.expiry)
        p.consumeSystemSleep(observedAt: 103); observe(&p, at: 104, awake: false)
        XCTAssertNil(p.expiry); observe(&p, at: 105)
        XCTAssertEqual(p.markers.pauseReason, .userSleep); XCTAssertFalse(p.automaticActive); XCTAssertFalse(p.manualActive)
        observe(&p, power: .battery, at: 106); observe(&p, at: 107)
        XCTAssertNil(p.markers.pauseReason); XCTAssertTrue(p.automaticActive); XCTAssertFalse(p.manualActive)
    }
    func testR3_048RestartCannotInventThePriorSleepWakePair() throws {
        var p = ready(automatic: true); p.pauseForUserSleep(now: 101)
        var next = try restarted(p); observe(&next, at: 102)
        next.consumeSystemSleep(observedAt: 103); observe(&next, at: 104)
        XCTAssertEqual(next.markers.pauseReason, .userSleep); XCTAssertNil(next.expiry)
        XCTAssertTrue(next.resume(thermal: 0)); observe(&next, at: 105); XCTAssertTrue(next.automaticActive)
    }
    func testR3_050AutomaticToggleDoesNotChangeManualOrClearWholePause() {
        var p = ready(condition: .any, automatic: true); XCTAssertTrue(p.start(duration: 180, now: 100))
        p.setAutomatic(false); observe(&p, at: 101); XCTAssertEqual(p.effectiveManualDeadline, 280)
        p.setAutomatic(true); observe(&p, at: 102); XCTAssertEqual(p.effectiveManualDeadline, 280)
        XCTAssertEqual(p.settings.condition, .ac); p.stopCurrent(); p.setAutomatic(false); p.setAutomatic(true)
        observe(&p, at: 103); XCTAssertNil(p.expiry); XCTAssertEqual(p.markers.pauseReason, .userStop)
    }
    func testR3_051And052ThermalProtectsACUnlimitedAndBatteryException() {
        for power in [PowerSource.ac, .battery] {
            var p = ready(power, condition: .any, automatic: true)
            XCTAssertFalse(p.setManualBatteryContinuationMinutes(120, now: 100))
            XCTAssertTrue(p.start(duration: power == .ac ? nil : 7200, now: 100))
            observe(&p, power: power, at: 101, thermal: 3)
            XCTAssertFalse(p.manualActive); XCTAssertNil(p.expiry); XCTAssertEqual(p.markers.protectionReason, "thermal")
            observe(&p, power: power, at: 102, thermal: 0); XCTAssertNil(p.expiry)
        }
    }
}
