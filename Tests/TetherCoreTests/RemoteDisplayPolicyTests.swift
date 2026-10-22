import XCTest
@testable import TetherCore

final class RemoteDisplayPolicyTests: XCTestCase {
    private func remote(power: PowerSource = .ac, closed: Bool = true,
                        disabled: Bool = true, fullWake: Bool = true) -> Snapshot {
        var snapshot = Snapshot(power: power, lidClosed: closed, sleepDisabled: disabled,
                                fullWake: fullWake, externalDisplay: true)
        snapshot.displayTopology = .virtualOnly
        return snapshot
    }

    func testRemoteDisplayAttachingDoesNotReleaseAnACSession() {
        for closed in [false, true] {
            let snapshot = remote(closed: closed)
            XCTAssertFalse(snapshot.defersToDisplaySetup)
            XCTAssertFalse(snapshot.usesNativeClamshell)
            XCTAssertTrue(Policy.wantsClamshell(snapshot, enabled: true, sleepNowPending: false))
            XCTAssertEqual(Policy.actions(for: snapshot, triggers: [.display], enabled: true,
                sleepNowPending: false, ownsOverride: true), [])
        }
    }

    func testStartingWithRemoteDisplayHonorsTheSelectedPowerCondition() {
        for closed in [false, true] {
            for condition in PowerCondition.allCases {
                let actions = Policy.actions(for: remote(closed: closed, disabled: false),
                    triggers: [.start], enabled: true, sleepNowPending: false,
                    condition: condition, ownsOverride: false)
                XCTAssertEqual(actions, condition.includesAC ? [.setSleepDisabled(true)] : [])
            }
        }
        XCTAssertEqual(Policy.actions(for: remote(disabled: false, fullWake: false),
            triggers: [.wake], enabled: true, sleepNowPending: false, ownsOverride: false), [])
    }

    func testUnclassifiedScreenCannotEndWorkOrClaimNativeClamshell() {
        for topology in [DisplayTopology.externalUnverified, .externalWithVirtual] {
            var snapshot = remote(); snapshot.displayTopology = topology
            XCTAssertFalse(snapshot.usesNativeClamshell)
            XCTAssertTrue(Policy.wantsClamshell(snapshot, enabled: true, sleepNowPending: false))
            XCTAssertEqual(Policy.actions(for: snapshot, triggers: [.display], enabled: true,
                sleepNowPending: false, ownsOverride: true), [])
        }
    }

    func testVerifiedPhysicalHandoffReleasesToNativeClamshell() {
        for topology in [DisplayTopology.externalUnverified, .externalWithVirtual] {
            var snapshot = remote()
            snapshot.displayTopology = topology
            snapshot.nativeDisplayVerified = true
            XCTAssertTrue(snapshot.usesNativeClamshell)
            XCTAssertEqual(Policy.actions(for: snapshot, triggers: [.display], enabled: true,
                sleepNowPending: false, ownsOverride: true), [.setSleepDisabled(false)])
        }
    }

    func testUnpluggingRemoteSessionStillRequiresBatteryAllowance() {
        let snapshot = remote(power: .battery)
        XCTAssertEqual(Policy.actions(for: snapshot, triggers: [.power], enabled: true,
            sleepNowPending: false, ownsOverride: true), [.setSleepDisabled(false), .sleepSystem])
        XCTAssertEqual(Policy.actions(for: snapshot, triggers: [.power], enabled: true,
            sleepNowPending: false, batteryHold: true, ownsOverride: true), [])
    }

    func testStoppingOwnedRemoteHoldSleepsOnlyWithClosedLid() {
        for closed in [false, true] {
            XCTAssertEqual(Policy.actions(for: remote(closed: closed), triggers: [.settings],
                enabled: false, sleepNowPending: false, ownsOverride: true),
                closed ? [.setSleepDisabled(false), .sleepSystem] : [.setSleepDisabled(false)])
            XCTAssertEqual(SleepRequestPolicy.allows(.closedLid,
                snapshot: remote(closed: closed, disabled: false), requestPending: false,
                enabled: false, batteryHold: false, condition: .ac, foreignKeepAwake: false), closed)
            XCTAssertEqual(Policy.actions(for: remote(closed: closed), triggers: [.settings],
                enabled: false, sleepNowPending: false, ownsOverride: false), [])
        }
    }

    func testRemoteSessionRetainsOSPressureProtection() {
        for thermal in [2, 3] {
            var tracker = SafetyNetTracker()
            XCTAssertEqual(tracker.update(remote(), clamshellOn: true,
                readings: SafetyReadings(temperature: nil, thermal: thermal, batteryPercent: 80),
                floor: 20, now: Date()), .overheatSleep)
        }
    }
    func testUnclassifiedScreenDoesNotDisableOwnThermalProtection() {
        var snapshot = remote(); snapshot.displayTopology = .externalUnverified
        var tracker = SafetyNetTracker()
        XCTAssertEqual(tracker.update(snapshot, clamshellOn: true,
            readings: SafetyReadings(temperature: nil, thermal: 2, batteryPercent: 80),
            floor: 20, now: Date()), .overheatSleep)
        snapshot.nativeDisplayVerified = true
        XCTAssertNil(tracker.update(snapshot, clamshellOn: true,
            readings: SafetyReadings(temperature: nil, thermal: 2, batteryPercent: 80),
            floor: 20, now: Date()))
    }

    func testRemoteSessionRetainsWeakChargerReserveProtection() {
        var tracker = SafetyNetTracker()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let readings = SafetyReadings(temperature: nil, thermal: 0, batteryPercent: 20, current: -400)
        XCTAssertNil(tracker.update(remote(), clamshellOn: true, readings: readings, floor: 20, now: now))
        XCTAssertEqual(tracker.update(remote(), clamshellOn: true, readings: readings,
            floor: 20, now: now.addingTimeInterval(60)), .weakChargerSleep)
    }
}
