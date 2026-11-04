import Foundation
import XCTest
@testable import TetherCore

/// Pure policy/transport regressions. These do not call IOKit, power tools or apps.
final class PowerOnlyAutomaticPolicyTests: XCTestCase {
    private func choices(_ condition: PowerCondition = .any,
                         mode: V4AutomaticMode = .acConnected,
                         disconnect: WorkSessionDisconnectPolicy = .endAll,
                         limit: WorkSessionBatteryLimit = .twoHours) -> IdleSessionSettings {
        var settings = IdleSessionSettings()
        settings.automaticEnabled = true
        settings.automaticPowerCondition = condition
        settings.v4.automaticMode = mode
        settings.disconnectPolicy = disconnect
        settings.batteryTimeLimit = limit
        return settings
    }

    private func observe(_ policy: inout IdleSessionPolicy, _ now: Double = 100,
                         power: PowerSource = .ac, thermal: Int? = 0,
                         battery: Int? = 80, gate: Bool? = true) {
        if policy.settings.v4.usesAdvancedAutomaticConditions, let gate {
            policy.setV4AutomaticGate(.init(isSatisfied: gate, validUntil: now + 15,
                                           reason: "selected-policy-fixture"), now: now)
        }
        policy.evaluate(power: power, thermal: thermal, fullWake: true, controllingUser: true,
                        now: now, batteryPercent: battery, lowPowerWarning: false, lowPowerMode: false)
    }

    func testBasicModeUsesACWithoutRewritingSavedPowerOrContinuationChoices() throws {
        for condition in PowerCondition.allCases {
            for disconnect in [WorkSessionDisconnectPolicy.endAll, .endAutomatic, .continueEligible] {
                for legacyStart in [false, true] {
                    var saved = choices(condition, disconnect: disconnect, limit: .fourHours)
                    saved.startAutomaticOnBatteryDisconnect = legacyStart
                    var policy = IdleSessionPolicy(settings: saved, boot: "power-only")
                    observe(&policy, power: .battery)
                    XCTAssertFalse(policy.automaticActive)
                    XCTAssertNil(policy.decision.batteryPermitID)
                    observe(&policy, 101)
                    XCTAssertTrue(policy.automaticActive)
                    XCTAssertEqual(policy.automaticPowerCondition, .ac)
                    XCTAssertEqual(policy.decision.powerScopes, [.ac])
                    observe(&policy, 102, power: .battery)
                    XCTAssertFalse(policy.automaticActive)
                    XCTAssertTrue(policy.decision.reasons.isEmpty)
                    XCTAssertNil(policy.automaticRequestID)
                    let decoded = try JSONDecoder().decode(IdleSessionSettings.self,
                        from: JSONEncoder().encode(policy.settings))
                    XCTAssertEqual(decoded.automaticPowerCondition, condition)
                    XCTAssertEqual(decoded.disconnectPolicy, disconnect)
                    XCTAssertEqual(decoded.batteryTimeLimit, .fourHours)
                    XCTAssertEqual(decoded.startAutomaticOnBatteryDisconnect, legacyStart)
                    XCTAssertEqual(decoded.effectiveAutomaticCondition, .ac)
                }
            }
        }
    }

    func testBasicWireSnapshotCannotProjectItsSavedAnyChoiceOntoBattery() {
        let saved = choices(.any, disconnect: .continueEligible, limit: .fourHours)
        var policy = IdleSessionPolicy(settings: saved, boot: "power-only")
        observe(&policy)
        let lease = WorkSessionLease(sessionID: UUID(), sequence: 1, power: .ac,
            expiry: 115, reasons: [.automatic], settings: policy.settings,
            automaticRequestID: policy.automaticRequestID,
            automaticPowerCondition: policy.automaticPowerCondition)
        XCTAssertEqual(saved.condition, .any)
        XCTAssertEqual(lease.configuration.condition, .ac)
        XCTAssertEqual(lease.effectiveAutomaticPowerCondition, .ac)
        XCTAssertEqual(lease.configuration.effectiveBatteryTimeLimit, .fourHours)
        var gate = WorkSessionLeaseGate()
        XCTAssertTrue(gate.accept(lease, now: 100, attaching: true))
        XCTAssertEqual(gate.reasons(now: 100, power: .ac), [.automatic])
        gate.observeTransition(now: 101, power: .battery)
        XCTAssertTrue(gate.reasons(now: 101, power: .battery).isEmpty)
        XCTAssertNil(policy.currentBatteryPermitID)
    }

    func testBasicModeRejectsLegacyOppositePowerAutomaticReceipt() {
        var policy = IdleSessionPolicy(settings: choices(.any, disconnect: .continueEligible), boot: "power-only")
        observe(&policy)
        let legacy = WorkSessionPowerTransition(token: UUID(), issuedAt: 100,
            power: .battery, expiry: 115, reasons: [.automatic], manualDeadline: nil,
            batteryDeadline: 7300, manualBudgetStart: nil, automaticBudgetStart: 100)
        XCTAssertFalse(policy.acceptPowerTransition(legacy, now: 101))
        XCTAssertNil(policy.automaticBatteryDeadline)
        observe(&policy, 102, power: .battery)
        XCTAssertFalse(policy.automaticActive)
    }

    func testBasicSelectionReleasesOnlyBatteryAutomaticDuringObservationGap() throws {
        var policy = IdleSessionPolicy(settings: choices(mode: .advanced, disconnect: .continueEligible), boot: "power-only")
        observe(&policy, power: .battery)
        XCTAssertTrue(policy.automaticActive)
        XCTAssertTrue(policy.start(duration: 600, now: 100))
        observe(&policy, 100.5, power: .battery)
        let manualID = try XCTUnwrap(policy.manualRequestID)
        let cap = policy.manualBatteryDeadline
        var changed = policy.settings.v4; changed.automaticMode = .acConnected
        XCTAssertTrue(policy.setV4Settings(changed))
        observe(&policy, 101, power: .battery, thermal: nil)
        XCTAssertFalse(policy.automaticActive)
        XCTAssertEqual(policy.decision.reasons, [.manual])
        XCTAssertEqual(policy.manualRequestID, manualID)
        XCTAssertEqual(policy.manualDeadline, 700)
        XCTAssertEqual(policy.manualBatteryDeadline, cap)
        XCTAssertFalse(policy.decision.renewalAllowed)
        XCTAssertEqual(policy.settings.automaticPowerCondition, .any)
    }

    func testSameUnplugAndAdvancedRuleEdgeCannotStartBatteryAutomatic() {
        var saved = choices(.battery, mode: .advanced, disconnect: .continueEligible)
        saved.startAutomaticOnBatteryDisconnect = true
        var policy = IdleSessionPolicy(settings: saved, boot: "power-only")
        observe(&policy, gate: false)
        observe(&policy, 101, power: .battery, gate: true)
        XCTAssertFalse(policy.automaticActive)
        XCTAssertNil(policy.automaticRequestID)
        XCTAssertEqual(policy.markers.automaticRestartBlocked, true)
        observe(&policy, 102, power: .battery)
        policy.resumeAutomatic()
        observe(&policy, 103, power: .battery)
        XCTAssertFalse(policy.automaticActive)
        XCTAssertTrue(policy.settings.startAutomaticOnBatteryDisconnect)
    }

    func testDormantAdvancedMarkerIsNotExistingWorkAtUnplug() {
        var saved = choices(mode: .advanced, disconnect: .continueEligible)
        saved.startAutomaticOnBatteryDisconnect = true
        var policy = IdleSessionPolicy(settings: saved, boot: "power-only")
        observe(&policy)
        XCTAssertTrue(policy.automaticActive)
        observe(&policy, 101, gate: false)
        XCTAssertFalse(policy.automaticActive)
        XCTAssertNotNil(policy.markers.automaticActivation)
        observe(&policy, 102, power: .battery, gate: true)
        XCTAssertFalse(policy.automaticActive)
        XCTAssertEqual(policy.markers.automaticRestartBlocked, true)
    }

    func testAlreadyRunningAdvancedContinuationKeepsIdentityAndOriginalBatteryLimit() throws {
        var policy = IdleSessionPolicy(settings: choices(mode: .advanced,
            disconnect: .continueEligible, limit: .thirtyMinutes), boot: "power-only")
        observe(&policy)
        let id = try XCTUnwrap(policy.automaticRequestID)
        observe(&policy, 101, power: .battery)
        XCTAssertTrue(policy.automaticActive)
        XCTAssertEqual(policy.automaticRequestID, id)
        XCTAssertEqual(policy.automaticBatteryDeadline, 1901)
        policy.setBatteryTimeLimit(.fourHours)
        observe(&policy, 110)
        observe(&policy, 111, power: .battery)
        XCTAssertEqual(policy.automaticRequestID, id)
        XCTAssertEqual(policy.automaticBatteryDeadline, 1901)
        XCTAssertEqual(policy.automaticBatteryTimeLimit, .thirtyMinutes)
        XCTAssertEqual(policy.settings.batteryTimeLimit, .fourHours)
    }

    func testExpiredACGrantCannotBecomeNewBatteryContinuation() {
        var policy = IdleSessionPolicy(settings: choices(mode: .advanced, disconnect: .continueEligible), boot: "power-only")
        observe(&policy)
        XCTAssertEqual(policy.expiry, 115)
        observe(&policy, 115, power: .battery)
        XCTAssertFalse(policy.automaticActive)
        XCTAssertNil(policy.automaticRequestID)
    }

    func testConsumedAdvancedAutomaticIsNotRestoredByWakeOrTogglesOnBattery() {
        var policy = IdleSessionPolicy(settings: choices(mode: .advanced), boot: "power-only")
        observe(&policy)
        XCTAssertTrue(policy.start(duration: 600, now: 100))
        observe(&policy, 101, power: .battery)
        XCTAssertFalse(policy.manualActive)
        XCTAssertFalse(policy.automaticActive)
        policy.consumeSystemSleep(observedAt: 102)
        observe(&policy, 103, power: .battery)
        policy.setAutomatic(false); policy.setAutomatic(true); policy.resumeAutomatic()
        observe(&policy, 104, power: .battery)
        XCTAssertFalse(policy.manualActive)
        XCTAssertFalse(policy.automaticActive)
        XCTAssertEqual(policy.markers.automaticRestartBlocked, true)
    }

    func testAllStopRejectsNewManualAndPreparedExtensionAcrossRuleChanges() throws {
        var policy = IdleSessionPolicy(settings: choices(), boot: "power-only")
        observe(&policy)
        XCTAssertTrue(policy.start(duration: 600, now: 100))
        let original = policy
        var proposed = policy
        XCTAssertTrue(proposed.extend(duration: 900, now: 100))
        let extensionID = try XCTUnwrap(proposed.manualExtensionID)
        policy.stopCurrent()
        policy.setAutomatic(false); policy.setAutomatic(true); policy.resumeAutomatic()
        var rules = policy.settings.v4; rules.automaticMode = .advanced
        XCTAssertTrue(policy.setV4Settings(rules))
        observe(&policy, 101)
        XCTAssertFalse(policy.start(duration: 600, now: 101))
        XCTAssertFalse(policy.extend(duration: 900, now: 101))
        XCTAssertFalse(policy.commitPreparedManualExtension(proposed, now: 101))
        XCTAssertFalse(policy.restoreManualRevision(from: original, expectedExtensionID: extensionID, now: 101))
        XCTAssertEqual(policy.markers.pauseReason, .userStop)
        XCTAssertTrue(policy.decision.reasons.isEmpty)
        XCTAssertTrue(policy.resume(thermal: 0))
        observe(&policy, 102)
        XCTAssertTrue(policy.automaticActive)
        XCTAssertFalse(policy.manualActive)
    }

    func testProtectionRequiresStableExplicitResumeAndNeverRestoresOldManual() {
        var policy = IdleSessionPolicy(settings: choices(), boot: "power-only")
        observe(&policy)
        XCTAssertTrue(policy.start(duration: 600, now: 100))
        observe(&policy, 101, thermal: 3)
        policy.setAutomatic(false); policy.setAutomatic(true); policy.resumeAutomatic()
        observe(&policy, 102)
        XCTAssertFalse(policy.start(duration: 600, now: 102))
        XCTAssertFalse(policy.extend(duration: 900, now: 102))
        XCTAssertFalse(policy.resume(thermal: 0))
        for time in stride(from: 112.0, through: 162.0, by: 10) { observe(&policy, time) }
        XCTAssertTrue(policy.resume(thermal: 0))
        observe(&policy, 163)
        XCTAssertTrue(policy.automaticActive)
        XCTAssertFalse(policy.manualActive)
    }

    func testModeEditCannotReplayPendingAdvancedEdgeThroughExplicitSleepBlock() {
        var policy = IdleSessionPolicy(settings: choices(.ac, mode: .advanced), boot: "power-only")
        observe(&policy)
        policy.pauseForUserSleep(now: 101)
        observe(&policy, 102, gate: false)
        policy.setV4AutomaticGate(.init(isSatisfied: true, validUntil: 118, reason: "old-mode-edge"), now: 103)
        var basic = policy.settings.v4; basic.automaticMode = .acConnected
        XCTAssertTrue(policy.setV4Settings(basic))
        observe(&policy, 103)
        XCTAssertEqual(policy.markers.pauseReason, .userSleep)
        XCTAssertFalse(policy.automaticActive)
    }

    func testApprovedUnlimitedManualChoiceSurvivesBasicModeAndAutomaticEdits() throws {
        var policy = IdleSessionPolicy(settings: choices(.battery,
            disconnect: .continueEligible, limit: .unlimited), boot: "power-only")
        observe(&policy, power: .battery)
        XCTAssertFalse(policy.automaticActive)
        XCTAssertTrue(policy.start(duration: nil, now: 100))
        let id = try XCTUnwrap(policy.manualRequestID)
        XCTAssertTrue(policy.setV4Settings(policy.settings.v4))
        policy.setAutomatic(false); policy.setAutomatic(true)
        observe(&policy, 101, power: .battery)
        XCTAssertEqual(policy.manualRequestID, id)
        XCTAssertEqual(policy.manualBatteryTimeLimit, .unlimited)
        XCTAssertNil(policy.manualDeadline)
        XCTAssertNil(policy.manualBatteryDeadline)
        XCTAssertEqual(policy.decision.expiry, 116)
        XCTAssertEqual(policy.settings.automaticPowerCondition, .battery)
    }

    func testBasicRuleEngineIgnoresLegacyPowerChoiceButKeepsWorkSafetyGate() {
        for condition in PowerCondition.allCases {
            var context = V4Fixture.context()
            context.automaticPowerCondition = condition
            XCTAssertTrue(V4Fixture.evaluate(V4Settings(), context).gate.isSatisfied)
            context.power = .battery
            XCTAssertFalse(V4Fixture.evaluate(V4Settings(), context).gate.isSatisfied)
            context.power = .ac; context.protectionActive = true
            XCTAssertFalse(V4Fixture.evaluate(V4Settings(), context).gate.isSatisfied)
            context.protectionActive = false; context.paused = true
            XCTAssertFalse(V4Fixture.evaluate(V4Settings(), context).gate.isSatisfied)
        }
    }

    func testExpiryNoticeMinuteRangeUsesSharedSettingsChoices() {
        for minutes in V4Settings.expiryNoticeMinuteChoices {
            var settings = V4Settings(); settings.expiryNoticeMinutes = minutes
            XCTAssertFalse(V4RuleEngine.validate(settings).contains("invalid-expiry-notice-minutes"))
        }
        for minutes in [-1, 0, 3, 60, Int.max] {
            var settings = V4Settings(); settings.expiryNoticeMinutes = minutes
            XCTAssertTrue(V4RuleEngine.validate(settings).contains("invalid-expiry-notice-minutes"))
        }
    }
}
