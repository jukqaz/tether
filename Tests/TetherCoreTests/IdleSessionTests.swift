import Foundation
import XCTest
@testable import TetherCore

final class IdleSessionTests: XCTestCase {
    private func observe(_ p: inout IdleSessionPolicy, at now: Double = 100, power: PowerSource = .ac,
                         thermal: Int? = 0, awake: Bool? = true, owner: Bool = true,
                         battery: Int? = 80, warning: Bool? = false, lowMode: Bool? = false) {
        p.evaluate(power: power, thermal: thermal, fullWake: awake, controllingUser: owner,
                   now: now, batteryPercent: battery, lowPowerWarning: warning, lowPowerMode: lowMode)
    }
    private func ready(_ power: PowerSource = .ac, automatic: Bool = false) -> IdleSessionPolicy {
        var s = IdleSessionSettings(); s.automaticEnabled = automatic
        var p = IdleSessionPolicy(settings: s, boot: "idle")
        observe(&p, power: power); return p
    }
    func testDefaultsDoNotStartAnyRequest() {
        let p = ready()
        XCTAssertFalse(p.settings.automaticEnabled); XCTAssertFalse(p.settings.allowClosedLid)
        XCTAssertFalse(p.manualActive); XCTAssertNil(p.expiry)
    }
    func testOneGeneralLeaseCombinesAutomaticAndManualWithoutChangingDeadline() {
        var p = ready(automatic: true)
        XCTAssertTrue(p.start(duration: 600, now: 100)); observe(&p, at: 101)
        XCTAssertEqual(p.decision.reasons, [.automatic, .manual])
        XCTAssertEqual(p.manualDeadline, 700); XCTAssertEqual(p.expiry, 116)
        p.endManual(); observe(&p, at: 102)
        XCTAssertEqual(p.decision.reasons, [.automatic])
    }
    func testAutomaticOffDoesNotConsumeManual() {
        var p = ready(automatic: true)
        XCTAssertTrue(p.start(duration: 600, now: 100))
        p.setAutomatic(false); observe(&p, at: 101)
        XCTAssertTrue(p.manualActive); XCTAssertEqual(p.manualDeadline, 700)
        XCTAssertEqual(p.decision.reasons, [.manual])
    }
    func testManualExpiryDoesNotEndIndependentACAutomatic() {
        var p = ready(automatic: true)
        XCTAssertTrue(p.start(duration: 600, now: 100)); observe(&p, at: 700)
        XCTAssertFalse(p.manualActive); XCTAssertTrue(p.automaticActive)
    }
    func testUnplugConsumesBothAndReconnectOnlyReevaluatesACAutomatic() {
        var p = ready(automatic: true)
        XCTAssertTrue(p.start(duration: 600, now: 100))
        observe(&p, at: 101, power: .battery)
        XCTAssertFalse(p.manualActive); XCTAssertFalse(p.automaticActive); XCTAssertNil(p.expiry)
        observe(&p, at: 102)
        XCTAssertFalse(p.manualActive); XCTAssertTrue(p.automaticActive)
    }
    func testBatteryManualMayVisitACButNotSurviveReDeparture() {
        var p = ready(.battery)
        XCTAssertTrue(p.start(duration: 600, now: 100))
        observe(&p, at: 101); XCTAssertEqual(p.effectiveManualDeadline, 700)
        observe(&p, at: 102, power: .battery); XCTAssertFalse(p.manualActive)
    }
    func testUnknownPowerConsumesWorkForProtectionWithoutInventingAnACBoundary() {
        var p = ready(automatic: true)
        XCTAssertTrue(p.start(duration: 600, now: 100))
        observe(&p, at: 101, power: .unknown)
        XCTAssertFalse(p.manualActive); XCTAssertEqual(p.markers.protectionReason, "sensor")
        observe(&p, at: 102); XCTAssertNil(p.expiry)
        XCTAssertTrue(p.resume(thermal: 0)); observe(&p, at: 103)
        XCTAssertTrue(p.automaticActive); XCTAssertFalse(p.manualActive)
    }
    func testDarkWakeCannotGrantOrRenewWork() {
        var p = ready(automatic: true)
        observe(&p, at: 101, awake: false); XCTAssertNil(p.expiry)
        observe(&p, at: 102, awake: nil); XCTAssertNil(p.expiry)
    }
    func testActualSleepConsumesManualAndPreservesAllowedACChoice() {
        var p = ready(automatic: true)
        XCTAssertTrue(p.start(duration: 600, now: 100))
        p.consumeSystemSleep(observedAt: 101); observe(&p, at: 102)
        XCTAssertFalse(p.manualActive); XCTAssertTrue(p.automaticActive)
    }
    func testOwnSleepPauseRequiresAnObservedSleepAndFullWake() {
        var p = ready(automatic: true)
        p.pauseForUserSleep(now: 101); observe(&p, at: 102)
        XCTAssertEqual(p.markers.pauseReason, .userSleep); XCTAssertNil(p.expiry)
        p.consumeSystemSleep(observedAt: 103); observe(&p, at: 104, awake: false)
        XCTAssertNil(p.expiry)
        observe(&p, at: 105); XCTAssertNil(p.markers.pauseReason); XCTAssertTrue(p.automaticActive)
    }
    func testGlobalPauseAndProtectionSurviveRestartAndAutomaticToggles() throws {
        for protecting in [false, true] {
            var p = ready(automatic: true)
            if protecting { p.acceptProtection("thermal") } else { p.stopCurrent() }
            p.setAutomatic(false); p.setAutomatic(true)
            let data = try JSONEncoder().encode(p.settings)
            var next = IdleSessionPolicy(settings: try JSONDecoder().decode(IdleSessionSettings.self, from: data), boot: "idle")
            observe(&next, at: 101); XCTAssertNil(next.expiry); XCTAssertFalse(next.manualActive)
            XCTAssertTrue(next.resume(thermal: 0)); observe(&next, at: 102); XCTAssertTrue(next.automaticActive)
        }
    }
    func testOwnerChangeConsumesTemporaryIntent() {
        var p = ready(automatic: true)
        XCTAssertTrue(p.start(duration: 600, now: 100))
        observe(&p, at: 101, owner: false)
        XCTAssertFalse(p.manualActive); XCTAssertEqual(p.markers.pauseReason, .ownerEnded)
        observe(&p, at: 102); XCTAssertNil(p.expiry)
    }
    func testBatteryProtectionAndMissingRequiredReadingsStopOnlyOwnWork() {
        for facts in [(Int?.none, Bool?.some(false)), (Int?.some(20), Bool?.some(false)),
                      (Int?.some(80), Bool?.none), (Int?.some(80), Bool?.some(true))] {
            var p = ready(.battery)
            XCTAssertTrue(p.start(duration: 600, now: 100))
            observe(&p, at: 101, power: .battery, battery: facts.0, warning: facts.1)
            XCTAssertFalse(p.manualActive); XCTAssertNil(p.expiry)
        }
    }
    func testLowPowerModeOptionAppliesAtStartAndDuringBatteryWorkOnly() {
        var p = ready(.battery)
        var s = p.settings.v4; s.stopOnLowPowerMode = true
        XCTAssertTrue(p.setV4Settings(s))
        observe(&p, at: 101, power: .battery, lowMode: true)
        XCTAssertFalse(p.start(duration: 600, now: 101))
        observe(&p, at: 102, power: .battery, lowMode: false)
        XCTAssertTrue(p.start(duration: 600, now: 102))
        observe(&p, at: 103, power: .battery, lowMode: true)
        XCTAssertFalse(p.manualActive); XCTAssertEqual(p.markers.protectionReason, "lowPowerMode")
        XCTAssertFalse(p.resume(thermal: 0))
        observe(&p, at: 104, power: .battery, lowMode: false)
        XCTAssertTrue(p.resume(thermal: 0))
    }
    func testACDoesNotRequireAnInternalBatteryReadingOrLPMStop() {
        var p = ready(automatic: true)
        var s = p.settings.v4; s.stopOnLowPowerMode = true
        XCTAssertTrue(p.setV4Settings(s))
        observe(&p, at: 101, battery: nil, warning: nil, lowMode: true)
        XCTAssertTrue(p.automaticActive); XCTAssertTrue(p.start(duration: nil, now: 101))
    }
    func testSeriousThermalAndUnavailableThermalNeverBecomeNominal() {
        for thermal in [Int?.none, -1, 2, 3, 4] {
            var p = ready(automatic: true)
            XCTAssertTrue(p.start(duration: nil, now: 100))
            observe(&p, at: 101, thermal: thermal)
            XCTAssertFalse(p.manualActive); XCTAssertNil(p.expiry)
            observe(&p, at: 102); XCTAssertNil(p.expiry)
        }
    }
    func testFreshStartAfterExpiryDoesNotRequireAWholeSessionResume() {
        var p = ready(.battery)
        XCTAssertTrue(p.start(duration: 600, now: 100)); observe(&p, at: 700, power: .battery)
        XCTAssertFalse(p.manualActive); XCTAssertTrue(p.start(duration: 600, now: 700))
    }
    func testLegacyContinuationAndOppositePowerDecisionsCannotAuthorizeV4() {
        var p = ready()
        XCTAssertFalse(p.setManualBatteryContinuationMinutes(30, now: 100))
        let decision = WorkSessionPowerTransition(token: UUID(), issuedAt: 100, power: .battery, expiry: 120,
            reasons: [.manual], manualDeadline: 700, batteryDeadline: nil, manualBudgetStart: 100, automaticBudgetStart: nil)
        XCTAssertFalse(p.acceptPowerTransition(decision, now: 101))
        XCTAssertNil(p.expiry)
    }
    func testNewManualIsNotSerializedWithSettings() throws {
        var p = ready(.battery); XCTAssertTrue(p.start(duration: 600, now: 100))
        let data = try JSONEncoder().encode(p.settings)
        var next = IdleSessionPolicy(settings: try JSONDecoder().decode(IdleSessionSettings.self, from: data), boot: "idle")
        observe(&next, at: 101, power: .battery)
        XCTAssertFalse(next.manualActive); XCTAssertNil(next.expiry)
    }
}
