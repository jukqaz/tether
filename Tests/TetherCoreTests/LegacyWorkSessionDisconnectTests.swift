import Foundation
import XCTest
@testable import TetherCore

final class LegacyWorkSessionDisconnectTests: XCTestCase {
    private func request(reasons: [WorkSessionReason] = [.automatic], power: PowerSource = .ac,
                         executionVersion: Int? = 3, requestID: UUID? = nil) -> WorkSessionLease {
        var settings = IdleSessionSettings()
        settings.automaticEnabled = true
        settings.manualBatteryContinuationMinutes = 120
        return WorkSessionLease(sessionID: UUID(), sequence: 1, power: power, expiry: 115,
            reasons: reasons, manualDeadline: reasons.contains(.manual) ? 600 : nil, settings: settings,
            executionVersion: executionVersion, manualRequestID: requestID)
    }

    private func batteryProjection(reasons: [WorkSessionReason]) -> WorkSessionPowerTransition {
        WorkSessionPowerTransition(token: UUID(), issuedAt: 100, power: .battery, expiry: 115,
            reasons: reasons, manualDeadline: reasons.contains(.manual) ? 600 : nil,
            batteryDeadline: reasons.contains(.automatic) ? 280 : nil,
            manualBudgetStart: reasons.contains(.manual) ? 100 : nil,
            automaticBudgetStart: reasons.contains(.automatic) ? 100 : nil)
    }

    func testLegacyPayloadRemainsDecodableButCannotAttachActiveAuthority() throws {
        let reasonSets: [[WorkSessionReason]] = [[.automatic], [.manual], [.automatic, .manual]]
        for reasons in reasonSets {
            var old = request(reasons: reasons, executionVersion: nil)
            old.powerTransition = batteryProjection(reasons: reasons)
            old.continuationToken = old.powerTransition?.token
            let decoded = try JSONDecoder().decode(WorkSessionLease.self, from: JSONEncoder().encode(old))
            XCTAssertNil(decoded.executionVersion)
            XCTAssertEqual(decoded, old, "Compatibility decoding preserves original metadata")
            XCTAssertTrue(decoded.isValid(now: 100))
            var gate = WorkSessionLeaseGate()
            XCTAssertFalse(gate.accept(decoded, now: 100, attaching: true))
            XCTAssertNil(gate.current); XCTAssertNil(gate.transitionReceipt)
            XCTAssertEqual(gate.reasons(now: 101, power: .battery), [])
            XCTAssertEqual(gate.reasons(now: 102, power: .ac), [])
        }
    }

    func testRestartAndEmptyUpgradeCannotReattachOldLegacyManualWithinOriginalExpiry() throws {
        var old = request(reasons: [.manual], executionVersion: nil)
        old.powerTransition = batteryProjection(reasons: [.manual])
        var state = HelperState(); state.userSessionCoordinated = true; state.workSessionLease = old
        let restored = try JSONDecoder().decode(HelperState.self, from: JSONEncoder().encode(state))
        let saved = try XCTUnwrap(restored.workSessionLease)
        XCTAssertEqual(saved, old)
        var restarted = WorkSessionLeaseGate()
        XCTAssertFalse(restarted.accept(saved, now: 102, attaching: true))
        var empty = saved; empty.sequence = 2; empty.reasons = []; empty.expiry = nil
        XCTAssertTrue(restarted.accept(empty, now: 102, attaching: true), "Old clients can still positively release")
        var replay = saved; replay.sequence = 3
        XCTAssertFalse(restarted.accept(replay, now: 103), "Neither reattachment nor a higher sequence grants legacy execution")
        XCTAssertEqual(restarted.reasons(now: 103, power: .ac), [])
        var fresh = replay; fresh.executionVersion = 3; fresh.powerTransition = nil
        fresh.manualRequestID = UUID(); fresh.continuationToken = nil
        XCTAssertTrue(restarted.accept(fresh, now: 103), "A supported current decision can complete the upgrade")
        XCTAssertEqual(restarted.reasons(now: 103, power: .ac), [.manual])
        XCTAssertEqual(restored.workSessionLease, old, "Gate evaluation does not rewrite the recovery source")
    }

    func testConfirmedDisconnectConsumesEverySupportedReasonWithoutReconnectRevival() {
        let reasonSets: [[WorkSessionReason]] = [[.automatic], [.manual], [.automatic, .manual]]
        for reasons in reasonSets {
            let lease = request(reasons: reasons, requestID: UUID())
            var gate = WorkSessionLeaseGate()
            XCTAssertTrue(gate.accept(lease, now: 100, attaching: true))
            XCTAssertEqual(gate.reasons(now: 100, power: .ac), reasons)
            gate.observeTransition(now: 101, power: .battery)
            XCTAssertEqual(gate.reasons(now: 101, power: .battery), [])
            gate.observeTransition(now: 102, power: .ac)
            XCTAssertEqual(gate.reasons(now: 102, power: .ac), [])
            XCTAssertNil(gate.transitionReceipt)
        }
    }

    func testUnknownDoesNotEraseTheConfirmedACDepartureBoundary() {
        var gate = WorkSessionLeaseGate()
        XCTAssertTrue(gate.accept(request(), now: 100, attaching: true))
        gate.observeTransition(now: 101, power: .unknown)
        XCTAssertEqual(gate.reasons(now: 101, power: .unknown), [])
        gate.observeTransition(now: 102, power: .battery)
        gate.observeTransition(now: 103, power: .ac)
        XCTAssertEqual(gate.reasons(now: 103, power: .ac), [])
        XCTAssertNil(gate.transitionReceipt)
    }

    func testEmptyAndFreshACAutomaticCannotReviveConsumedManualID() {
        var old = request(reasons: [.automatic, .manual], requestID: UUID())
        var gate = WorkSessionLeaseGate()
        XCTAssertTrue(gate.accept(old, now: 100, attaching: true))
        gate.observeTransition(now: 101, power: .battery)
        var empty = old; empty.sequence = 2; empty.power = .battery; empty.reasons = []; empty.expiry = nil
        empty.executionVersion = nil
        XCTAssertTrue(gate.accept(empty, now: 101))
        gate.observeTransition(now: 102, power: .ac)
        var automatic = old; automatic.sequence = 3; automatic.reasons = [.automatic]
        XCTAssertTrue(gate.accept(automatic, now: 102))
        XCTAssertEqual(gate.reasons(now: 102, power: .ac), [.automatic])
        old.sequence = 4
        XCTAssertFalse(gate.accept(old, now: 103), "A higher sequence cannot resurrect the consumed manual")
        XCTAssertEqual(gate.current, automatic)
    }

    func testBatteryOriginManualIsConsumedOnReunplugWithoutAnIntermediateACLease() {
        let old = request(reasons: [.manual], power: .battery, requestID: UUID())
        var gate = WorkSessionLeaseGate()
        XCTAssertTrue(gate.accept(old, now: 100, attaching: true))
        gate.observeTransition(now: 101, power: .ac)
        XCTAssertEqual(gate.reasons(now: 101, power: .ac), [.manual], "Battery-origin manual work may use AC before the next confirmed unplug consumes it")
        gate.observeTransition(now: 102, power: .battery)
        XCTAssertEqual(gate.reasons(now: 102, power: .battery), [])
        var replay = old; replay.sequence = 2
        XCTAssertFalse(gate.accept(replay, now: 102))
        replay.manualRequestID = UUID()
        XCTAssertTrue(gate.accept(replay, now: 102))
        gate.observeTransition(now: 103, power: .battery)
        XCTAssertEqual(gate.reasons(now: 103, power: .battery), [.manual])
    }

    func testFreshBatteryManualCanArriveBeforeEmptyOrPowerNotification() {
        let old = request(reasons: [.manual], requestID: UUID())
        var gate = WorkSessionLeaseGate()
        XCTAssertTrue(gate.accept(old, now: 100, attaching: true))
        var replay = old; replay.sequence = 2; replay.power = .battery
        XCTAssertFalse(gate.accept(replay, now: 101))
        var fresh = replay; fresh.manualRequestID = UUID()
        XCTAssertTrue(gate.accept(fresh, now: 101))
        gate.observeTransition(now: 101, power: .battery)
        XCTAssertEqual(gate.reasons(now: 101, power: .battery), [.manual])
        XCTAssertEqual(gate.current?.manualRequestID, fresh.manualRequestID)
        XCTAssertNil(gate.transitionReceipt)
    }

    func testBoundaryUsesLiveReasonsRatherThanExpiredManualPayload() {
        var expired = request(reasons: [.manual], requestID: UUID()); expired.manualDeadline = 110
        var gate = WorkSessionLeaseGate()
        XCTAssertTrue(gate.accept(expired, now: 100, attaching: true))
        XCTAssertEqual(gate.reasons(now: 110, power: .ac), [])
        var combined = expired; combined.reasons = [.automatic, .manual]; combined.sequence = 2
        XCTAssertTrue(gate.accept(combined, now: 109))
        XCTAssertEqual(gate.reasons(now: 110, power: .ac), [.automatic])
        combined.sequence = 3; combined.configuration.automaticEnabled = false
        XCTAssertFalse(gate.accept(combined, now: 109), "Disabled automatic work cannot remain inside an active grant")
        combined.reasons = [.manual]
        XCTAssertTrue(gate.accept(combined, now: 109))
        XCTAssertEqual(gate.reasons(now: 110, power: .ac), [])
    }
}
