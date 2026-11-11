import XCTest
@testable import TetherCore

final class DisplayRecoveryTests: XCTestCase {
    func testObservationPauseCannotRearmAnExhaustedIncident() {
        var gate = DisplaySleepGate()
        for time in [0.0, 10, 20] { XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: time), .request) }
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 30), .conflict)
        // An output that prevents all-display commands pauses observations; it is
        // not a confirmed end of the underlying closed-hold incident.
        for time in [100.0, 101, 1000] {
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: time), .conflict)
            XCTAssertEqual(gate.phase, .stopped); XCTAssertEqual(gate.requestCount, 3)
        }
    }
    func testObservationPausePreservesPartialBudgetAndOriginalRetrySpacing() {
        var gate = DisplaySleepGate()
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 0), .request)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 2), .none)
        XCTAssertEqual(gate.requestCount, 1)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 10), .request)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 12), .none)
        XCTAssertEqual(gate.requestCount, 2)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 20), .request)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 30), .conflict)
        XCTAssertEqual(gate.requestCount, 3)
    }
    func testObservationPauseCannotProveTheStableSleepNeededToRenewBudget() {
        var gate = DisplaySleepGate()
        _ = gate.evaluate(eligible: true, sleeping: false, now: 0)
        for time in stride(from: 1.0, through: 58, by: 3) {
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: true, now: time), .none)
        }
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: true, now: 200), .none)
        XCTAssertEqual(gate.requestCount, 1)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 201), .none)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 211), .request)
        XCTAssertEqual(gate.requestCount, 2)
    }
    func testVerifiedHoldEndResetsStoppedRecoveryBeforeANewIncident() {
        var gate = DisplaySleepGate()
        for time in [0.0, 10, 20] { _ = gate.evaluate(eligible: true, sleeping: false, now: time) }
        _ = gate.evaluate(eligible: true, sleeping: false, now: 30)
        XCTAssertEqual(gate.phase, .stopped)
        XCTAssertEqual(gate.evaluate(eligible: false, sleeping: false, now: 31), .none)
        XCTAssertEqual(gate.phase, .inactive); XCTAssertEqual(gate.requestCount, 0)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 32), .request)
        XCTAssertEqual(gate.requestCount, 1)
    }
    func testInitiallyUnknownPanelNeverRequestsAllDisplaySleep() {
        var gate = DisplaySleepGate()
        for time in [0.0, 3, 9] {
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: nil, now: time), .none)
            XCTAssertEqual(gate.requestCount, 0)
        }
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: nil, now: 10), .conflict)
        XCTAssertEqual(gate.phase, .stopped)
        XCTAssertEqual(gate.requestCount, 0)
    }
    func testForeignDisplayDeferralCannotReplenishRetryBudget() {
        var gate = DisplaySleepGate()
        for time in [0.0, 10, 20] { XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: time), .request) }
        gate.deferRequests(); XCTAssertEqual(gate.phase, .deferred)
        XCTAssertEqual(gate.requestCount, 3)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 21), .conflict)
        XCTAssertEqual(gate.requestCount, 3)
    }
    func testDeferralPreservesMonotonicClockValidation() {
        var gate = DisplaySleepGate()
        _ = gate.evaluate(eligible: true, sleeping: false, now: 10)
        gate.deferRequests()
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 9), .conflict)
        XCTAssertEqual(gate.phase, .stopped)
    }
    func testIndependentWakesAfterSustainedSleepDoNotAccumulateAcrossHours() {
        var gate = DisplaySleepGate()
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 0), .request)
        for incident in 0..<4 {
            let base = Double(incident * 3600)
            for offset in stride(from: 1.0, through: 61, by: 3) {
                XCTAssertEqual(gate.evaluate(eligible: true, sleeping: true, now: base + offset), .none)
            }
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: base + 3590), .none)
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: base + 3600), .request,
                           "A distinct wake after stable sleep needs its own bounded recovery")
        }
    }

    // Real failure: request at lid close, transient wake from another process, then
    // the old helper stopped at 10 seconds. The new helper gets a second observation.
    func testRecordedWakeRecoversWithoutEndingClamshell() {
        var gate = DisplaySleepGate()
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 0), .request)
        for time in [1.0, 4, 7] {
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: time), .none)
        }
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 10), .request)
        XCTAssertEqual(gate.requestCount, 2)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: true, now: 13), .none)
        XCTAssertFalse(gate.pending)
        for time in [30.0, 90, 300] {
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: true, now: time), .none)
        }
    }

    func testLongObservationGapDoesNotProveStableSleep() {
        var gate = DisplaySleepGate()
        for t in [0.0, 10, 20] { _ = gate.evaluate(eligible: true, sleeping: false, now: t) }
        _ = gate.evaluate(eligible: true, sleeping: true, now: 21)
        _ = gate.evaluate(eligible: true, sleeping: true, now: 200)
        _ = gate.evaluate(eligible: true, sleeping: false, now: 201)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 211), .conflict)
    }

    func testUnknownObservationBreaksStableSleepWindow() {
        var gate = DisplaySleepGate()
        _ = gate.evaluate(eligible: true, sleeping: false, now: 0)
        for t in stride(from: 1.0, through: 58, by: 3) { _ = gate.evaluate(eligible: true, sleeping: true, now: t) }
        _ = gate.evaluate(eligible: true, sleeping: nil, now: 59)
        _ = gate.evaluate(eligible: true, sleeping: true, now: 60)
        XCTAssertEqual(gate.requestCount, 1)
        for t in stride(from: 63.0, through: 120, by: 3) { _ = gate.evaluate(eligible: true, sleeping: true, now: t) }
        XCTAssertEqual(gate.requestCount, 0)
    }

    func testInvalidOrBackwardsClockStopsWithoutRenewingBudget() {
        for invalid in [Double.nan, Double.infinity, 9] {
            var gate = DisplaySleepGate()
            _ = gate.evaluate(eligible: true, sleeping: false, now: 10)
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: true, now: invalid), .conflict)
            XCTAssertEqual(gate.phase, .stopped)
        }
    }

    func testContinuousWakeExhaustsThreeSpacedRequestsAndLatches() {
        var gate = DisplaySleepGate()
        for time in [0.0, 10, 20] {
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: time), .request)
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: time + 9.9), .none)
        }
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 30), .conflict)
        XCTAssertEqual(gate.requestCount, 3)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: true, now: 31), .conflict)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 100), .conflict)
    }

    func testIntermittentSuccessfulSleepCannotReplenishBudget() {
        var gate = DisplaySleepGate()
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 0), .request)
        for (asleep, awake, retry) in [(1.0, 2.0, 12.0), (13, 14, 24)] {
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: true, now: asleep), .none)
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: awake), .none)
            XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: retry), .request)
        }
        _ = gate.evaluate(eligible: true, sleeping: true, now: 25)
        _ = gate.evaluate(eligible: true, sleeping: false, now: 26)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 36), .conflict)
        XCTAssertEqual(gate.requestCount, 3)
    }

    func testShortWakeCanRecoverWithoutAnotherCommand() {
        var gate = DisplaySleepGate()
        _ = gate.evaluate(eligible: true, sleeping: true, now: 0)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 1), .none)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: true, now: 9), .none)
        XCTAssertFalse(gate.pending)
        XCTAssertEqual(gate.requestCount, 0)
    }

    func testUnknownAfterRetryDoesNotGetMoreDisplayCommands() {
        var gate = DisplaySleepGate()
        _ = gate.evaluate(eligible: true, sleeping: false, now: 0)
        _ = gate.evaluate(eligible: true, sleeping: false, now: 10)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: nil, now: 11), .none)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: nil, now: 20), .conflict)
        XCTAssertEqual(gate.requestCount, 2)
    }

    func testIneligibleResetsPendingRetryAndBudget() {
        var gate = DisplaySleepGate()
        _ = gate.evaluate(eligible: true, sleeping: false, now: 0)
        _ = gate.evaluate(eligible: true, sleeping: false, now: 10)
        XCTAssertEqual(gate.evaluate(eligible: false, sleeping: false, now: 20), .none)
        XCTAssertFalse(gate.pending)
        XCTAssertEqual(gate.requestCount, 0)
        XCTAssertEqual(gate.evaluate(eligible: true, sleeping: false, now: 21), .request)
    }
}
