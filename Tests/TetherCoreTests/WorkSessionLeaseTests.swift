import XCTest
@testable import TetherCore

final class WorkSessionLeaseTests: XCTestCase {
    private func lease(_ sequence: UInt64 = 1, end: Double? = 115,
                       reasons: [WorkSessionReason] = [.automatic]) -> WorkSessionLease {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        return WorkSessionLease(sessionID: UUID(), sequence: sequence, power: .ac, expiry: end,
            reasons: reasons, settings: settings)
    }
    private func transition() -> WorkSessionPowerTransition {
        WorkSessionPowerTransition(token: UUID(), issuedAt: 100, power: .battery, expiry: 115,
            reasons: [.manual], manualDeadline: 600, batteryDeadline: nil,
            manualBudgetStart: 100, automaticBudgetStart: nil)
    }
    func testClosedLidDisplayModeIsOptionalForOldWireDataAndRoundTripsExplicitChoices() throws {
        let original = lease()
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        old.removeValue(forKey: "closedLidDisplayMode")
        let decodedOld = try JSONDecoder().decode(WorkSessionLease.self,
            from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decodedOld.closedLidDisplayMode)
        XCTAssertEqual(decodedOld.effectiveClosedLidDisplayMode, .off)
        XCTAssertEqual(decodedOld.reasons, original.reasons)
        XCTAssertEqual(decodedOld.expiry, original.expiry)
        for mode in [ClosedLidDisplayMode.off, .zeroBrightness, .unchanged] {
            var explicit = original; explicit.closedLidDisplayMode = mode
            let decoded = try JSONDecoder().decode(WorkSessionLease.self,
                from: JSONEncoder().encode(explicit))
            XCTAssertEqual(decoded.closedLidDisplayMode, mode)
            XCTAssertEqual(decoded.effectiveClosedLidDisplayMode, mode)
            XCTAssertEqual(decoded.reasons, original.reasons)
            XCTAssertEqual(decoded.expiry, original.expiry)
        }
    }

    func testPreviousCoordinatorCannotSilentlyIgnoreClosedLidDisplayChoices() {
        var control = Control(); control.schemaVersion = Control.currentSchema
        var reply = ServiceReply(id: UUID(), ok: true, epoch: "ready", revision: 1, control: control,
            protection: ProtectionStatus(reason: nil, error: nil, dryRun: true))
        var status = Status(updatedAt: 100, version: TetherPaths.version, enabled: false, power: .ac,
            lidClosed: false, sleepDisabled: false, lastEvent: nil, lastEventAt: nil)
        status.build = TetherPaths.build
        status.workSessionCoordinatorVersion = 9
        reply.status = status
        XCTAssertFalse(reply.isCurrentHelperReady(now: Date(timeIntervalSince1970: 100)))
        reply.status?.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
        XCTAssertEqual(WorkSessionLease.coordinatorVersion, 10)
        XCTAssertTrue(reply.isCurrentHelperReady(now: Date(timeIntervalSince1970: 100)))
    }
    func testDisconnectEndIntentIsOptionalAndCannotGrantWork() throws {
        let old = lease()
        XCTAssertNil(try JSONDecoder().decode(WorkSessionLease.self,
            from: JSONEncoder().encode(old)).disconnectEndRequested)
        var ended = old
        ended.sequence = 2; ended.power = .battery; ended.reasons = []; ended.expiry = nil
        ended.disconnectEndRequested = true
        let decoded = try JSONDecoder().decode(WorkSessionLease.self, from: JSONEncoder().encode(ended))
        XCTAssertEqual(decoded.disconnectEndRequested, true)
        XCTAssertTrue(decoded.isValid(now: 101))
        var gate = WorkSessionLeaseGate()
        XCTAssertFalse(gate.accept(decoded, now: 101), "End intent cannot attach or create a grant")
        XCTAssertTrue(gate.accept(old, now: 100, attaching: true))
        XCTAssertTrue(gate.accept(decoded, now: 101))
        XCTAssertEqual(gate.reasons(now: 101, power: .battery), [])
        var invalid = ended; invalid.power = .ac
        XCTAssertFalse(invalid.isValid(now: 101))
        invalid = old; invalid.disconnectEndRequested = true
        XCTAssertFalse(invalid.isValid(now: 101))
        invalid = ended; invalid.configuration.enabled = false
        XCTAssertFalse(invalid.isValid(now: 101))
        invalid = ended; invalid.executionVersion = nil
        XCTAssertFalse(invalid.isValid(now: 101))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ended)) as? [String: Any])
        legacy.removeValue(forKey: "disconnectEndRequested")
        let legacyEnd = try JSONDecoder().decode(WorkSessionLease.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(legacyEnd.disconnectEndRequested)
        XCTAssertTrue(legacyEnd.isValid(now: 101))
    }
    func testV4CannotAuthorizeBatteryAutomaticOrOppositePowerContinuation() throws {
        for continuation in [Int?.none, 15, 120] {
            var request = lease(reasons: [.manual]); request.manualDeadline = 600
            request.configuration.manualBatteryContinuationMinutes = continuation
            request.powerTransition = transition()
            XCTAssertFalse(request.isValid(now: 100), "Legacy opt-in is never a v4 power-transfer permission")
            let decoded = try JSONDecoder().decode(WorkSessionLease.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(decoded.powerTransition, request.powerTransition, "Legacy metadata remains decodable")
            XCTAssertFalse(decoded.isValid(now: 100))
        }
        var automatic = lease(); automatic.power = .battery
        XCTAssertFalse(automatic.isValid(now: 100))
    }
    func testSleepConsumptionRequiresSameBootOwnerAndAnObservedSequenceBoundary() {
        let owner = UUID()
        let valid = WorkSessionSleepConsumption(bootID: "fixture", sessionID: owner, sequence: 4, observedAt: 101)
        XCTAssertTrue(valid.isValid(sessionID: owner, sequence: 4, now: 104, boot: "fixture"))
        XCTAssertTrue(valid.isValid(sessionID: owner, sequence: 8, now: 1000, boot: "fixture"))
        XCTAssertFalse(valid.isValid(sessionID: owner, sequence: 3, now: 104, boot: "fixture"))
        XCTAssertFalse(valid.isValid(sessionID: UUID(), sequence: 4, now: 104, boot: "fixture"))
        XCTAssertFalse(valid.isValid(sessionID: owner, sequence: 4, now: 100, boot: "fixture"))
        XCTAssertFalse(valid.isValid(sessionID: owner, sequence: 4, now: 104, boot: "another-boot"))
        XCTAssertFalse(valid.isValid(sessionID: owner, sequence: 4, now: 104, boot: "unknown"))
        var preparationOnly = valid; preparationOnly.sequence = 0
        XCTAssertTrue(preparationOnly.isValid(sessionID: owner, sequence: 1, now: 104, boot: "fixture"))
        var invalid = valid; invalid.observedAt = .nan
        XCTAssertFalse(invalid.isValid(sessionID: owner, sequence: 4, now: 104, boot: "fixture"))
        invalid = valid; invalid.observedAt = -1
        XCTAssertFalse(invalid.isValid(sessionID: owner, sequence: 4, now: 104, boot: "fixture"))
    }
    func testSleepConsumptionIsOptionalForOldDataAndPersistsOnlyItsObservation() throws {
        let original = lease()
        let legacyLease = try JSONDecoder().decode(WorkSessionLease.self, from: JSONEncoder().encode(original))
        XCTAssertNil(legacyLease.sleepConsumptionID)
        let bridge = try JSONDecoder().decode(WorkSessionBridge.self, from:
            Data("{\"version\":1,\"coordinated\":true,\"automaticBudget\":{},\"stopRequested\":false}".utf8))
        XCTAssertNil(bridge.sleepConsumption); XCTAssertNil(bridge.extensionPreparationReceipt)
        var state = HelperState()
        state.userSessionCoordinated = true
        state.workSleepConsumption = WorkSessionSleepConsumption(bootID: "fixture", sessionID: original.sessionID,
            sequence: original.sequence, observedAt: 101)
        let restored = try JSONDecoder().decode(HelperState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.workSleepConsumption, state.workSleepConsumption)
        XCTAssertNil(restored.workSessionLease)
        var acknowledged = original; acknowledged.sleepConsumptionID = state.workSleepConsumption?.id
        XCTAssertEqual(try JSONDecoder().decode(WorkSessionLease.self,
            from: JSONEncoder().encode(acknowledged)).sleepConsumptionID, state.workSleepConsumption?.id)
    }
    func testInvalidTransitionMetadataDoesNotReplaceTheLastGrant() {
        var gate = WorkSessionLeaseGate(); let original = lease(reasons: [.manual])
        XCTAssertTrue(gate.accept(original, now: 100, attaching: true))
        var invalid = original; invalid.sequence = 2; invalid.manualDeadline = 600
        invalid.powerTransition = transition(); invalid.continuationToken = invalid.powerTransition?.token
        XCTAssertFalse(gate.accept(invalid, now: 101))
        XCTAssertEqual(gate.current, original); XCTAssertNil(gate.transitionReceipt)
        gate.observeTransition(now: 101, power: .battery)
        XCTAssertNil(gate.transitionReceipt); XCTAssertEqual(gate.reasons(now: 101, power: .battery), [])
    }
    func testTransitionEvidenceCannotGrantUnknownUnboundedOrIncompleteBatteryWork() {
        let valid = transition()
        XCTAssertTrue(valid.isValid(source: .ac, parentExpiry: 115, now: 100))
        var invalid: [WorkSessionPowerTransition] = []
        var value = valid; value.power = .unknown; invalid.append(value)
        value = valid; value.expiry = 116; invalid.append(value)
        value = valid; value.issuedAt = 101; invalid.append(value)
        value = valid; value.manualBudgetStart = nil; invalid.append(value)
        value = valid; value.manualDeadline = nil; invalid.append(value)
        value = valid; value.manualBudgetStart = 101; invalid.append(value)
        value = valid; value.reasons = [.manual, .manual]; invalid.append(value)
        for decision in invalid {
            XCTAssertFalse(decision.isValid(source: .ac, parentExpiry: 115, now: 100))
        }
        XCTAssertFalse(valid.isValid(source: .unknown, parentExpiry: 115, now: 100))
        XCTAssertFalse(valid.isValid(source: .battery, parentExpiry: 115, now: 100))
    }
    func testManualDeadlineEndsBeforeIndependentACAutomaticWithoutPowerProjection() {
        var request = lease(reasons: [.automatic, .manual]); request.manualDeadline = 110
        var gate = WorkSessionLeaseGate()
        XCTAssertTrue(gate.accept(request, now: 100, attaching: true))
        XCTAssertEqual(gate.reasons(now: 109, power: .ac), [.automatic, .manual])
        XCTAssertEqual(gate.reasons(now: 110, power: .ac), [.automatic])
        XCTAssertEqual(gate.reasons(now: 111, power: .battery), [])
        XCTAssertEqual(gate.reasons(now: 115, power: .ac), [])
    }
    func testPreparationReceiptIsFiniteAndBoundToTheReadRootRevisionAndSession() throws {
        let session = UUID()
        let receipt = WorkSessionPreparation(sessionID: session, epoch: "root", revision: 2, expiresAt: 115)
        let decoded = try JSONDecoder().decode(WorkSessionPreparation.self, from: JSONEncoder().encode(receipt))
        XCTAssertEqual(decoded, receipt)
        XCTAssertTrue(decoded.isValid(sessionID: session, epoch: "root", revision: 2, now: 100))
        for (id, epoch, revision, now) in [(UUID(), "root", UInt64(2), 100.0),
            (session, "restarted-root", 2, 100), (session, "root", 3, 100), (session, "root", 2, 115)] {
            XCTAssertFalse(decoded.isValid(sessionID: id, epoch: epoch, revision: revision, now: now))
        }
        var invalid = decoded; invalid.expiresAt = 116
        XCTAssertFalse(invalid.isValid(sessionID: session, epoch: "root", revision: 2, now: 100))
    }
    func testOnlyAnExplicitAttachmentCreatesABoundFiniteLease() {
        var gate = WorkSessionLeaseGate(); let initial = lease()
        XCTAssertFalse(gate.accept(initial, now: 100))
        XCTAssertTrue(gate.accept(initial, now: 100, attaching: true))
        XCTAssertEqual(gate.reasons(now: 114, power: .ac), [.automatic])
        XCTAssertEqual(gate.reasons(now: 115, power: .ac), [])
        XCTAssertEqual(gate.reasons(now: 101, power: .battery), [])
        XCTAssertEqual(gate.reasons(now: 101, power: .unknown), [])
    }
    func testEndingAuthorityRejectsDelayedRenewalUntilNewExplicitAttachment() {
        var initial = lease(reasons: [.manual])
        initial.manualDeadline = 600
        var gate = WorkSessionLeaseGate()
        XCTAssertTrue(gate.accept(initial, now: 100, attaching: true))
        gate.end()
        XCTAssertNil(gate.current); XCTAssertNil(gate.transitionReceipt)
        initial.sequence += 1
        XCTAssertFalse(gate.accept(initial, now: 104))
        XCTAssertEqual(gate.reasons(now: 104, power: .ac), [])
        XCTAssertTrue(gate.accept(initial, now: 104, attaching: true))
        XCTAssertEqual(gate.reasons(now: 104, power: .ac), [.manual])
    }
    func testReplayWrongSessionAndMalformedRequestDoNotChangeTheLastGrant() {
        var gate = WorkSessionLeaseGate(); let initial = lease()
        XCTAssertTrue(gate.accept(initial, now: 100, attaching: true))
        XCTAssertFalse(gate.accept(initial, now: 101))
        var wrong = lease(2); XCTAssertFalse(gate.accept(wrong, now: 101, attaching: true))
        wrong.sessionID = initial.sessionID; wrong.expiry = .infinity
        XCTAssertFalse(gate.accept(wrong, now: 101))
        wrong.expiry = 132; XCTAssertFalse(gate.accept(wrong, now: 101))
        XCTAssertEqual(gate.current, initial)
    }
    func testRemovingOneReasonKeepsTheOtherAndEmptyLeaseReleasesWithoutZeroTimeout() {
        var initial = lease(reasons: [.automatic, .manual]); var gate = WorkSessionLeaseGate()
        XCTAssertTrue(gate.accept(initial, now: 100, attaching: true))
        initial.sequence = 2; initial.reasons = [.automatic]
        XCTAssertTrue(gate.accept(initial, now: 101))
        XCTAssertEqual(gate.reasons(now: 102, power: .ac), [.automatic])
        initial.sequence = 3; initial.reasons = []; initial.expiry = nil
        XCTAssertTrue(gate.accept(initial, now: 103)); XCTAssertEqual(gate.reasons(now: 103, power: .ac), [])
        gate.end(); XCTAssertFalse(gate.accept(initial, now: 104))
    }
    func testBatteryManualNeedsAFiniteDeadlineAndKeepsTheFirstCeilingOnAC() {
        var value = lease(reasons: [.manual]); value.power = .battery
        XCTAssertFalse(value.isValid(now: 100))
        value.manualDeadline = 800; value.manualStartedOnBattery = true
        value.manualBatteryMaximumDeadline = 7300
        XCTAssertTrue(value.isValid(now: 100))
        value.power = .ac; XCTAssertTrue(value.isValid(now: 101))
        value.manualDeadline = 7301; XCTAssertTrue(value.isValid(now: 101), "The manual deadline may extend on AC without changing the first battery ceiling")
        XCTAssertEqual(value.manualBatteryMaximumDeadline, 7300)
        value.power = .battery; value.expiry = 7310
        XCTAssertFalse(value.isValid(now: 7300), "Returning to battery after the original ceiling expires cannot grant work")
        value.power = .ac; value.expiry = 115
        value.manualDeadline = nil; XCTAssertFalse(value.isValid(now: 101))
        value.manualDeadline = 800; value.reasons = [.manual, .manual]; XCTAssertFalse(value.isValid(now: 101))
        value.reasons = [.manual]; value.configuration.limits = UserLimits(maxHoldHours: .nan)
        XCTAssertFalse(value.isValid(now: 101))
        value.configuration.limits = UserLimits(openLidMaxTemperature: 50)
        XCTAssertFalse(value.isValid(now: 101))
    }
    func testExtensionPreparationNeverMutatesOldAuthorityAndCannotCrossRequestOrOwner() {
        var old = lease(reasons: [.manual]); old.manualRequestID = UUID(); old.manualDeadline = 600
        let pending = WorkSessionExtensionPreparation(id: UUID(), requestID: old.manualRequestID!,
            currentDeadline: 600, proposedDeadline: 1500, expiresAt: 105)
        var prepared = old; prepared.sequence = 2; prepared.extensionPreparation = pending
        XCTAssertTrue(prepared.isValid(now: 100))
        XCTAssertTrue(pending.matches(current: old, incoming: prepared, now: 100))
        XCTAssertEqual(prepared.manualDeadline, 600)
        var wrong = prepared; wrong.manualRequestID = UUID()
        XCTAssertFalse(pending.matches(current: old, incoming: wrong, now: 100))
        wrong = prepared; wrong.sessionID = UUID()
        XCTAssertFalse(pending.matches(current: old, incoming: wrong, now: 100))
        XCTAssertFalse(pending.isValid(now: 105))
        var tooLate = pending; tooLate.expiresAt = 106
        XCTAssertFalse(tooLate.isValid(now: 100))
    }
    func testCommittedExtensionNeedsMatchingPreparationAndWholeApprovedAmount() {
        var current = lease(2, reasons: [.manual])
        let request = UUID(), extensionID = UUID()
        current.manualRequestID = request; current.manualDeadline = 600
        let pending = WorkSessionExtensionPreparation(id: extensionID, requestID: request,
            currentDeadline: 600, proposedDeadline: 2400, expiresAt: 105)
        let receipt = WorkSessionExtensionPreparationReceipt(sessionID: current.sessionID, sequence: 2,
            observedAt: 100, preparation: pending)
        var committed = current; committed.sequence = 3
        committed.manualDeadline = 2400; committed.manualExtensionID = extensionID
        XCTAssertTrue(receipt.permitsCommit(current: current, incoming: committed, now: 101))
        var wrong = committed; wrong.manualExtensionID = UUID()
        XCTAssertFalse(receipt.permitsCommit(current: current, incoming: wrong, now: 101))
        wrong = committed; wrong.manualDeadline = 1500
        XCTAssertFalse(receipt.permitsCommit(current: current, incoming: wrong, now: 101))
        XCTAssertFalse(receipt.permitsCommit(current: current, incoming: committed, now: 105))
        current.manualBatteryMaximumDeadline = 2000
        XCTAssertTrue(receipt.permitsCommit(current: current, incoming: committed, now: 101), "An explicit AC extension preserves rather than applies the battery ceiling")
        current.power = .battery; committed.power = .battery
        XCTAssertFalse(receipt.permitsCommit(current: current, incoming: committed, now: 101))
    }
}
