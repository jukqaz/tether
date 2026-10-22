import XCTest
@testable import TetherCore

final class PowerObservationTests: XCTestCase {
    private func result(_ output: String, status: Int32 = 0, timedOut: Bool = false,
                        confirmed: Bool = true) -> Shell.Result {
        .init(status: status, output: output, timedOut: timedOut, processID: nil,
              terminationConfirmed: confirmed, exitStatus: status)
    }

    func testSleepOverrideRequiresSuccessfulExactUnambiguousRead() {
        XCTAssertEqual(SystemProbe.sleepDisabled(in: result("Current settings:\n SleepDisabled 0\n")), false)
        XCTAssertEqual(SystemProbe.sleepDisabled(in: result(" SleepDisabled\t1\n sleep 0")), true)
        for output in ["", "sleep 0", "SleepDisabled", "SleepDisabled yes", "SleepDisabled 2",
                       "SleepDisabled 0 extra", "SleepDisabled 0\nSleepDisabled 1",
                       "SleepDisabled 0\nSleepDisabled 0"] {
            XCTAssertNil(SystemProbe.sleepDisabled(in: result(output)), output)
        }
        XCTAssertNil(SystemProbe.sleepDisabled(in: result("SleepDisabled 0", status: 1)))
        XCTAssertNil(SystemProbe.sleepDisabled(in: result("SleepDisabled 0", timedOut: true)))
        XCTAssertNil(SystemProbe.sleepDisabled(in: result("SleepDisabled 0", confirmed: false)))
    }

    func testUnavailableReadingsRemainUnavailableThroughCompatibilityAccess() {
        var s = Snapshot(power: .ac, lidClosed: nil, sleepDisabled: nil, fullWake: nil)
        XCTAssertFalse(s.lidControlObservationAvailable)
        XCTAssertEqual(s.unavailablePowerObservations, ["lid", "sleepOverride", "wake"])
        XCTAssertFalse(s.lidClosed); XCTAssertFalse(s.sleepDisabled); XCTAssertFalse(s.fullWake)
        XCTAssertNil(s.observedLidClosed); XCTAssertNil(s.observedSleepDisabled); XCTAssertNil(s.observedFullWake)
        s.lidClosed = true; s.sleepDisabled = false; s.fullWake = true
        XCTAssertTrue(s.lidControlObservationAvailable)
        XCTAssertEqual(s.observedLidClosed, true); XCTAssertEqual(s.observedSleepDisabled, false)
    }

    func testNoNewGlobalOverrideOnAnyMissingRequiredReading() {
        for s in [Snapshot(power: .ac, lidClosed: nil, sleepDisabled: false),
                  Snapshot(power: .ac, lidClosed: false, sleepDisabled: nil),
                  Snapshot(power: .ac, lidClosed: false, sleepDisabled: false, fullWake: nil)] {
            XCTAssertEqual(Policy.actions(for: s, triggers: [.power], enabled: true,
                sleepNowPending: false, ownsOverride: false), [], "\(s)")
        }
    }

    func testEligibleOwnedWorkIsNotCanceledByObservationGap() {
        for s in [Snapshot(power: .ac, lidClosed: nil, sleepDisabled: true),
                  Snapshot(power: .ac, lidClosed: false, sleepDisabled: nil),
                  Snapshot(power: .ac, lidClosed: false, sleepDisabled: true, fullWake: nil)] {
            XCTAssertTrue(Policy.wantsClamshell(s, enabled: true, sleepNowPending: false, ownsOverride: true))
            XCTAssertEqual(Policy.actions(for: s, triggers: [.timer], enabled: true,
                sleepNowPending: false, ownsOverride: true), [])
        }
    }

    func testConfirmedOwnReleaseDoesNotRequireLidOrWakeReading() {
        let s = Snapshot(power: .battery, lidClosed: nil, sleepDisabled: true, fullWake: nil)
        XCTAssertEqual(Policy.actions(for: s, triggers: [.power], enabled: true,
            sleepNowPending: false, ownsOverride: true), [.setSleepDisabled(false)])
        XCTAssertEqual(Policy.actions(for: s, triggers: [.power], enabled: true,
            sleepNowPending: false, ownsOverride: false), [])
        let unreadable = Snapshot(power: .battery, lidClosed: true, sleepDisabled: nil)
        XCTAssertEqual(Policy.actions(for: unreadable, triggers: [.power], enabled: true,
            sleepNowPending: false, ownsOverride: true), [])
    }

    func testNeitherAutomaticNorExplicitSleepUsesMissingOverrideOrWake() {
        for s in [Snapshot(power: .battery, lidClosed: true, sleepDisabled: nil),
                  Snapshot(power: .battery, lidClosed: true, sleepDisabled: false, fullWake: nil)] {
            XCTAssertEqual(Policy.actions(for: s, triggers: [.sleepNow], enabled: false,
                sleepNowPending: true, ownsOverride: true), [])
            for intent in [SleepIntent.user, .closedLid, .protection] {
                XCTAssertFalse(SleepRequestPolicy.allows(intent, snapshot: s, requestPending: true,
                    enabled: false, batteryHold: false, condition: .ac, foreignKeepAwake: false))
            }
        }
    }

    func testMissingLidDefersAutomaticSleepButDoesNotInvalidateExplicitUserSleep() {
        let s = Snapshot(power: .battery, lidClosed: nil, sleepDisabled: false)
        for intent in [SleepIntent.closedLid, .protection] {
            XCTAssertFalse(SleepRequestPolicy.allows(intent, snapshot: s, requestPending: true,
                enabled: false, batteryHold: false, condition: .ac, foreignKeepAwake: false))
        }
        XCTAssertTrue(SleepRequestPolicy.allows(.user, snapshot: s, requestPending: true,
            enabled: false, batteryHold: false, condition: .ac))
    }

    func testUnknownLidCannotConsumeOrPerformOpenLidHandoff() {
        var gate = NativeClamshellHandoffGate()
        var s = Snapshot(power: .ac, lidClosed: nil, sleepDisabled: true)
        s.nativeDisplayCandidate = true
        XCTAssertFalse(gate.begin(snapshot: s, allowed: true, ownsOverride: true))
        s.lidClosed = false
        XCTAssertTrue(gate.begin(snapshot: s, allowed: true, ownsOverride: true))
        s.observedSleepDisabled = nil; s.nativeDisplayVerified = true
        s.externalDisplay = true; s.displayTopology = .externalUnverified
        XCTAssertFalse(s.defersToDisplaySetup)
    }
}
