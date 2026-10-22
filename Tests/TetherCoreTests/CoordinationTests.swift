import XCTest
@testable import TetherCore

final class CoordinationTests: XCTestCase {
    func testUnknownBootCannotAcquireOwnershipOrOverwriteRecoveryRecord() {
        var journal = PowerOwnership()
        for boot in ["unknown", ""] {
            XCTAssertFalse(journal.acquire(boot: boot))
            XCTAssertFalse(journal.owned); XCTAssertNil(journal.appliedAt)
        }
        XCTAssertTrue(journal.acquire(boot: "fixture-boot"))
        let previous = journal
        XCTAssertFalse(journal.acquire(boot: "unknown"))
        XCTAssertEqual(journal, previous)
    }
    func testInactivePolicyDoesNotTouchForeignOverrideOrForceSleep() {
        for power in [PowerSource.ac, .battery, .unknown] {
            let snapshot = Snapshot(power: power, lidClosed: true, sleepDisabled: true)
            XCTAssertEqual(Policy.actions(for: snapshot, triggers: [.timer], enabled: false,
                sleepNowPending: false, ownsOverride: false), [])
        }
    }
    func testOwnedReleaseSleepsClosedBatteryButLeavesNativeDisplayAlone() {
        let battery = Snapshot(power: .battery, lidClosed: true, sleepDisabled: true)
        XCTAssertEqual(Policy.actions(for: battery, triggers: [.power], enabled: false,
            sleepNowPending: false, ownsOverride: true), [.setSleepDisabled(false), .sleepSystem])
        var native = Snapshot(power: .ac, lidClosed: true, sleepDisabled: true, externalDisplay: true)
        native.nativeDisplayVerified = true
        XCTAssertEqual(Policy.actions(for: native, triggers: [.display], enabled: true,
            sleepNowPending: false, ownsOverride: true), [.setSleepDisabled(false)])
    }
    func testUnknownDisplayDoesNotEnableOrClaimNativeClamshell() {
        var snapshot = Snapshot(power: .ac, lidClosed: true, sleepDisabled: false, externalDisplay: true)
        snapshot.displayTopology = .unknown
        XCTAssertFalse(snapshot.usesNativeClamshell)
        XCTAssertFalse(Policy.wantsClamshell(snapshot, enabled: true, sleepNowPending: false))
        snapshot.sleepDisabled = true
        XCTAssertEqual(Policy.actions(for: snapshot, triggers: [.display], enabled: true,
            sleepNowPending: false, ownsOverride: true), [])
        XCTAssertEqual(Policy.actions(for: snapshot, triggers: [.display], enabled: false,
            sleepNowPending: false, ownsOverride: true), [.setSleepDisabled(false)])
        XCTAssertEqual(Policy.actions(for: snapshot, triggers: [.power], enabled: true,
            sleepNowPending: false, ownsOverride: false), [])
    }
    func testDisplayRequestWaitsForAcknowledgementThenStops() {
        var gate = DisplaySleepGate()
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 0), .request)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: nil, now: 9), .none)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: nil, now: 10), .conflict)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 20), .conflict)
    }
    func testRemoteWakeGetsBoundedRecoveryAndOpeningLidCancelsIt() {
        var gate = DisplaySleepGate()
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: true, now: 0), .none)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 2), .none)
        XCTAssertTrue(gate.pending)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 12), .request)
        XCTAssertEqual(gate.evaluate(eligible: false, sleeping: false, now: 13), .none)
        XCTAssertEqual(gate.requestCount, 0)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 14), .request)
    }
    func testBriefOrUnknownPowerCannotResetBudget() {
        var gate = StablePowerGate()
        var protection = ProtectionState()
        protection.prepareBatteryBudget(power: .battery, needed: true, clock: 0)
        for (power, clock) in [(PowerSource.ac, 1.0), (.battery, 2), (.ac, 10), (.unknown, 11), (.ac, 20), (.ac, 49)] {
            XCTAssertFalse(gate.observe(power, now: clock))
        }
        XCTAssertTrue(gate.observe(.ac, now: 50))
        XCTAssertNotNil(protection.batteryBudgetStart)
        protection.confirmPowerReturn()
        XCTAssertNil(protection.batteryBudgetStart)
    }
    func testMissingDisplayObservationRecoversWithoutAnotherOffRequest() {
        var gate = DisplaySleepGate()
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: true, now: 0), .none)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: nil, now: 3), .none)
        XCTAssertTrue(gate.pending)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: nil, now: 12.9), .none)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: true, now: 13), .none)
        XCTAssertFalse(gate.pending)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: nil, now: 20), .none)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: nil, now: 30), .conflict)
    }
    func testKnownWakeAfterUnknownObservationUsesBoundedRecovery() {
        var gate = DisplaySleepGate()
        _ = gate.evaluate(eligible: true, sleeping: true, now: 0)
        _ = gate.evaluate(eligible: true, sleeping: nil, now: 1)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 2), .none)
        XCTAssertNil(gate.unavailableSince)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 12), .request)
        XCTAssertEqual(gate.evaluate(eligible: false, sleeping: nil, now: 13), .none)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: nil, now: 14), .none)
        XCTAssertEqual(gate.requestCount, 0)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: nil, now: 24), .conflict)
    }
    func testPowerOwnershipJournalSurvivesRoundTripWithoutInventingOwnership() throws {
        var journal = PowerOwnership()
        XCTAssertFalse(journal.owned)
        journal.acquire(boot: "fixture-boot")
        let decoded = try JSONDecoder().decode(PowerOwnership.self, from: JSONEncoder().encode(journal))
        XCTAssertTrue(decoded.owned); XCTAssertTrue(decoded.isValid(for: "fixture-boot"))
        XCTAssertFalse(decoded.isValid(for: "unknown")); XCTAssertFalse(decoded.isValid(for: "other-boot"))
        journal.release(); XCTAssertFalse(journal.owned)
    }
    func testPeerPIDCannotBeForgedInJSON() throws {
        let request = try JSONDecoder().decode(ServiceRequest.self, from: Data("{\"version\":2,\"id\":\"00000000-0000-0000-0000-000000000001\",\"action\":\"attachApp\",\"authenticatedPID\":1}".utf8))
        XCTAssertNil(request.authenticatedPID)
    }
}
