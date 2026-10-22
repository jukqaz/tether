import Foundation
import XCTest
@testable import TetherCore

final class P0RecoveryTests: XCTestCase {
    func testPreP0HelperCannotAdvertiseReadinessForP0PowerContracts() {
        let now = Date(timeIntervalSince1970: 100)
        var control = Control(); control.schemaVersion = Control.currentSchema
        var reply = ServiceReply(id: UUID(), ok: true, epoch: "p0", revision: 1, control: control,
            protection: ProtectionStatus(reason: nil, error: nil, dryRun: true))
        var status = Status(updatedAt: 100, version: TetherPaths.version, enabled: false, power: .ac,
            lidClosed: false, sleepDisabled: false, lastEvent: nil, lastEventAt: nil)
        status.build = TetherPaths.build; status.workSessionCoordinatorVersion = 8; reply.status = status
        XCTAssertFalse(reply.isCurrentHelperReady(now: now), "The same build number cannot hide an old coordinator contract")
        reply.status?.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
        XCTAssertTrue(reply.isCurrentHelperReady(now: now))
    }

    func testCleanupConsumesNoExtraWorkAndIssuesOnlyAfterCleanupWithinSixtySeconds() {
        var value = EndActionAuthority(causeID: UUID(), observedAt: 100)
        XCTAssertEqual(value.cleanupDeadline, 160)
        XCTAssertFalse(value.canDispatch(now: 101))
        XCTAssertTrue(value.issue(now: 159))
        XCTAssertEqual(value.issuedAt, 159)
        XCTAssertEqual(value.actionDeadline, 174)
        XCTAssertFalse(value.issue(now: 159.5), "One cause never mints a second action")
        XCTAssertTrue(value.consume(now: 160), "The 15-second action window starts after cleanup")
        XCTAssertFalse(value.consume(now: 161))
        XCTAssertTrue(value.canDispatch(now: 173.999))
        XCTAssertFalse(value.canDispatch(now: 174))
    }

    func testExactCleanupBoundaryAndLateRestorationCannotMintSleep() {
        for now in [160.0, 160.001, 1000] {
            var value = EndActionAuthority(causeID: UUID(), observedAt: 100)
            XCTAssertFalse(value.issue(now: now))
            XCTAssertNil(value.actionID)
            XCTAssertFalse(value.consume(now: now))
        }
    }

    func testCancellationBeforeOrAfterIssueNeverReissuesEvenAfterNormalFactsReturn() {
        for issued in [false, true] {
            var value = EndActionAuthority(causeID: UUID(), observedAt: 100)
            if issued { XCTAssertTrue(value.issue(now: 101)) }
            value.cancel()
            XCTAssertFalse(value.issue(now: 102))
            XCTAssertFalse(value.consume(now: 102))
            XCTAssertFalse(value.canDispatch(now: 102))
        }
    }

    func testInvalidClockAndUnrepresentableDeadlinesNeverGrantAction() {
        for origin in [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude] {
            var value = EndActionAuthority(causeID: UUID(), observedAt: origin)
            XCTAssertFalse(value.issue(now: origin))
        }
        var value = EndActionAuthority(causeID: UUID(), observedAt: 100)
        for now in [Double.nan, .infinity, -.infinity, 99] { XCTAssertFalse(value.issue(now: now)) }
    }

    func testPersistedEndReceiptIsEvidenceWithoutExecutableAuthority() throws {
        var receipt = WorkSessionEndReceipt(bootID: "boot", sessionID: UUID(), sequence: 1,
            observedAt: 100, kind: .disconnect, action: .sleepIfClosed)
        receipt.cleanupDeadline = 160; receipt.actionID = UUID()
        receipt.actionIssuedAt = 110; receipt.actionDeadline = 125; receipt.phase = .consumed
        let decoded = try JSONDecoder().decode(WorkSessionEndReceipt.self, from: JSONEncoder().encode(receipt))
        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(decoded.phase, .consumed)
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
        let legacy = old.filter { !["cleanupDeadline", "actionID", "actionIssuedAt", "actionDeadline"].contains($0.key) }
        let legacyReceipt = try JSONDecoder().decode(WorkSessionEndReceipt.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(legacyReceipt.actionID)
        XCTAssertEqual(legacyReceipt.phase, .consumed)
    }

    func testBatteryBudgetMayExpireOnACWithoutInvalidatingACWork() {
        var settings = IdleSessionSettings(); settings.allowClosedLid = true
        let id = UUID()
        let permit = WorkSessionLidPermit(powerScopes: [.ac, .battery], batteryPermitID: id,
            batteryDuration: 7200, batteryDeadline: 150, batteryMaximumDeadline: 150)
        let lease = WorkSessionLease(sessionID: UUID(), sequence: 1, power: .ac, expiry: 210,
            reasons: [.manual], manualDeadline: 400, settings: settings, lidPermit: permit,
            manualRequestID: id, manualBatteryMaximumDeadline: 150)
        XCTAssertTrue(lease.isValid(now: 200))
        XCTAssertFalse(permit.isValid(now: 200, source: .battery))
    }

    func testOnlyExplicitUnlimitedBatteryOptionAllowsMissingDeadline() {
        var settings = IdleSessionSettings(); settings.batteryTimeLimit = .unlimited
        let id = UUID()
        let permit = WorkSessionLidPermit(powerScopes: [.battery], batteryPermitID: id, batteryTimeLimit: .unlimited)
        let lease = WorkSessionLease(sessionID: UUID(), sequence: 1, power: .battery, expiry: 115,
            reasons: [.manual], settings: settings, lidPermit: permit, manualRequestID: id)
        XCTAssertTrue(lease.isValid(now: 100))
        XCTAssertTrue(permit.isValid(now: 100, source: .battery, batteryLimit: .twoHours),
                       "The captured explicit cap, not a later default, controls a valid permit")
        XCTAssertFalse(WorkSessionLidPermit(powerScopes: [.battery], batteryPermitID: id).isValid(now: 100, source: .battery))
    }

    func testAdvancedContinuePreservesOnlyEligibleFiniteRequestsAcrossUnplug() {
        var settings = IdleSessionSettings(); settings.disconnectPolicy = .continueEligible
        let id = UUID()
        let lease = WorkSessionLease(sessionID: UUID(), sequence: 1, power: .ac, expiry: 115,
            reasons: [.manual], manualDeadline: 300, settings: settings,
            manualRequestID: id, manualBatteryMaximumDeadline: 250)
        var gate = WorkSessionLeaseGate()
        XCTAssertTrue(gate.accept(lease, now: 100, attaching: true))
        gate.observeTransition(now: 101, power: .battery)
        XCTAssertEqual(gate.reasons(now: 102, power: .battery), [.manual])
        XCTAssertEqual(gate.current?.manualRequestID, id)
        XCTAssertEqual(gate.current?.manualBatteryMaximumDeadline, 250)
        gate.observeTransition(now: 103, power: .ac)
        XCTAssertEqual(gate.reasons(now: 104, power: .ac), [.manual])
        XCTAssertEqual(gate.reasons(now: 115, power: .ac), [])
    }

    func testFirstAutomaticBatteryAnchorUsesExplicitDualScopeWithoutRenewingGrant() {
        var settings = IdleSessionSettings()
        settings.automaticEnabled = true; settings.automaticPowerCondition = .any
        settings.disconnectPolicy = .continueEligible
        let id = UUID()
        let permit = WorkSessionLidPermit(powerScopes: [.ac, .battery], batteryPermitID: id,
            batteryDuration: 7200, batteryTimeLimit: .twoHours)
        let lease = WorkSessionLease(sessionID: UUID(), sequence: 1, power: .ac, expiry: 115,
            reasons: [.automatic], settings: settings, lidPermit: permit, automaticRequestID: id)
        var gate = WorkSessionLeaseGate()
        XCTAssertTrue(gate.accept(lease, now: 100, attaching: true))
        gate.observeTransition(now: 101, power: .battery)
        XCTAssertEqual(gate.reasons(now: 101, power: .battery), [.automatic])
        XCTAssertEqual(gate.current?.expiry, 115)
        XCTAssertEqual(gate.reasons(now: 115, power: .battery), [])
    }

    func testCapturedManualScopeAndLimitSurviveChangingNextDefaults() {
        var settings = IdleSessionSettings()
        settings.manualPowerCondition = .ac; settings.batteryTimeLimit = .thirtyMinutes
        let id = UUID()
        let permit = WorkSessionLidPermit(powerScopes: [.battery], batteryPermitID: id,
            batteryDuration: 14400, batteryDeadline: 14500, batteryMaximumDeadline: 14500,
            batteryTimeLimit: .fourHours)
        let lease = WorkSessionLease(sessionID: UUID(), sequence: 1, power: .battery, expiry: 115,
            reasons: [.manual], manualDeadline: 14500, settings: settings, lidPermit: permit,
            manualRequestID: id, manualBatteryMaximumDeadline: 14500,
            manualPowerCondition: .any, manualBatteryTimeLimit: .fourHours)
        XCTAssertTrue(lease.isValid(now: 100))
        var gate = WorkSessionLeaseGate()
        XCTAssertTrue(gate.accept(lease, now: 100, attaching: true))
        XCTAssertEqual(gate.reasons(now: 101, power: .battery), [.manual])
    }

    func testSameManualIDCannotWidenCapturedScopeOrCapThroughRefresh() {
        var settings = IdleSessionSettings(); settings.manualPowerCondition = .ac
        settings.batteryTimeLimit = .thirtyMinutes
        let lease = WorkSessionLease(sessionID: UUID(), sequence: 1, power: .ac, expiry: 115,
            reasons: [.manual], manualDeadline: 300, settings: settings, manualRequestID: UUID(),
            manualPowerCondition: .ac, manualBatteryTimeLimit: .thirtyMinutes)
        for widenScope in [false, true] {
            var gate = WorkSessionLeaseGate()
            XCTAssertTrue(gate.accept(lease, now: 100, attaching: true))
            var next = lease; next.sequence = 2; next.expiry = 116
            if widenScope { next.manualPowerCondition = .any }
            else { next.manualBatteryTimeLimit = .unlimited }
            XCTAssertFalse(gate.accept(next, now: 101))
            XCTAssertEqual(gate.current, lease)
        }
        var gate = WorkSessionLeaseGate(); XCTAssertTrue(gate.accept(lease, now: 100, attaching: true))
        var next = lease; next.sequence = 2; next.expiry = 116
        next.configuration.manualPowerCondition = .any; next.configuration.batteryTimeLimit = .unlimited
        XCTAssertTrue(gate.accept(next, now: 101), "Next defaults may change while captured request metadata stays fixed")
    }

    func testSameAutomaticIDCannotWidenCapturedScopeCapOrBatteryAnchor() {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        let lease = WorkSessionLease(sessionID: UUID(), sequence: 1, power: .ac, expiry: 115,
            reasons: [.automatic], settings: settings, automaticRequestID: UUID(), automaticBatteryDeadline: 1900,
            automaticBatteryTimeLimit: .thirtyMinutes, automaticPowerCondition: .ac)
        for kind in ["scope", "cap", "anchor"] {
            var gate = WorkSessionLeaseGate(); XCTAssertTrue(gate.accept(lease, now: 100, attaching: true))
            var next = lease; next.sequence = 2; next.expiry = 116
            if kind == "scope" { next.automaticPowerCondition = .any }
            if kind == "cap" { next.automaticBatteryTimeLimit = .unlimited }
            if kind == "anchor" { next.automaticBatteryDeadline = 1901 }
            XCTAssertFalse(gate.accept(next, now: 101))
            XCTAssertEqual(gate.current, lease)
        }
    }
}
