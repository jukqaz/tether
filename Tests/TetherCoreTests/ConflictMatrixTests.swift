import XCTest
@testable import TetherCore

final class ConflictMatrixTests: XCTestCase {
    func testRecoveryUsesTheSameCoexistencePolicyAndRequiresConfirmedBatteryConditions() {
        for power in [PowerSource.ac, .battery, .unknown] {
            for lid in [Bool?.some(true), false, nil] {
                for wake in [Bool?.some(true), false, nil] {
                    for disabled in [Bool?.some(true), false, nil] {
                        for foreign in [Bool?.some(true), false, nil] {
                            let snapshot = Snapshot(power: power, lidClosed: lid, sleepDisabled: disabled, fullWake: wake)
                            XCTAssertEqual(SleepRequestPolicy.allowsAutomaticRecovery(snapshot: snapshot,
                                foreignKeepAwake: foreign), power == .battery && lid == true && wake == true
                                    && disabled == false && foreign == false)
                        }
                    }
                }
            }
        }
    }
    func testPolicyMatrixHonorsNativeClamshellDarkWakeAndForeignOwnership() {
        var count = 0
        for power in [PowerSource.ac, .battery, .unknown] {
            for topology in [DisplayTopology.none, .externalUnverified, .virtualOnly, .externalWithVirtual, .unknown] {
                for lid in [false, true] { for wake in [false, true] { for disabled in [false, true] {
                    for enabled in [false, true] { for owned in [false, true] { for hold in [false, true] {
                        for condition in PowerCondition.allCases {
                            var snapshot = Snapshot(power: power, lidClosed: lid, sleepDisabled: disabled, fullWake: wake,
                                                    externalDisplay: topology.mayHaveExternal)
                            snapshot.displayTopology = topology
                            // This matrix covers verified handoff candidates. Unclassified
                            // outputs without this evidence have separate remote regressions.
                            snapshot.nativeDisplayVerified = [.externalUnverified, .externalWithVirtual].contains(topology)
                            for trigger in [Trigger.start, .power, .lid, .wake, .settings, .timer, .display] {
                                let actions = Policy.actions(for: snapshot, triggers: [trigger], enabled: enabled,
                                    sleepNowPending: false, batteryHold: hold, condition: condition, ownsOverride: owned)
                                if !owned { XCTAssertFalse(actions.contains(.setSleepDisabled(false))) }
                                if !wake { XCTAssertFalse(actions.contains(.setSleepDisabled(true))); XCTAssertFalse(actions.contains(.sleepSystem)) }
                                if power == .unknown || topology == .unknown { XCTAssertFalse(actions.contains(.setSleepDisabled(true))) }
                                if power == .ac && [.externalUnverified, .externalWithVirtual, .unknown].contains(topology) {
                                    XCTAssertFalse(actions.contains(.setSleepDisabled(true)))
                                    XCTAssertFalse(actions.contains(.sleepSystem))
                                }
                                if !enabled { XCTAssertFalse(actions.contains(.setSleepDisabled(true))) }
                                if !owned && disabled { XCTAssertTrue(actions.isEmpty) }
                                count += 1
                            }
                        }
                    } } }
                } } }
            }
        }
        XCTAssertEqual(count, 20_160)
    }

    func testEverySleepAttemptRevalidatesItsOriginalIntent() {
        var count = 0
        for power in [PowerSource.ac, .battery, .unknown] {
            for topology in [DisplayTopology.none, .externalUnverified, .virtualOnly, .externalWithVirtual, .unknown] {
                for lid in [false, true] { for wake in [false, true] { for disabled in [false, true] {
                    for pending in [false, true] { for enabled in [false, true] { for hold in [false, true] {
                        for condition in PowerCondition.allCases { for intent in [SleepIntent.user, .closedLid, .protection] {
                            var s = Snapshot(power: power, lidClosed: lid, sleepDisabled: disabled, fullWake: wake,
                                             externalDisplay: topology.mayHaveExternal)
                            s.displayTopology = topology
                            let allowed = SleepRequestPolicy.allows(intent, snapshot: s, requestPending: pending,
                                enabled: enabled, batteryHold: hold, condition: condition, foreignKeepAwake: false)
                            if allowed {
                                XCTAssertTrue(wake); XCTAssertNotEqual(power, .unknown); XCTAssertFalse(disabled)
                                if intent != .user { XCTAssertTrue(lid) }
                                if intent != .closedLid { XCTAssertTrue(pending) }
                                if intent == .closedLid && power == .ac { XCTAssertTrue([.none, .virtualOnly].contains(topology)) }
                                if intent == .protection && power == .ac { XCTAssertTrue(condition.includesAC) }
                            }
                            count += 1
                        } }
                    } } }
                } } }
            }
        }
        XCTAssertEqual(count, 8_640)
    }

    func testOpeningLidCancelsProtectionButNotExplicitUserSleep() {
        let s = Snapshot(power: .ac, lidClosed: false, sleepDisabled: false, externalDisplay: true)
        XCTAssertFalse(SleepRequestPolicy.allows(.protection, snapshot: s, requestPending: true,
            enabled: false, batteryHold: false, condition: .ac))
        XCTAssertTrue(SleepRequestPolicy.allows(.user, snapshot: s, requestPending: true,
            enabled: false, batteryHold: false, condition: .ac))
        XCTAssertFalse(SleepRequestPolicy.allows(.user, snapshot: s, requestPending: false,
            enabled: false, batteryHold: false, condition: .ac))
    }

    func testForeignOverrideAndNativeDisplayCancelReleaseRetries() {
        for snapshot in [Snapshot(power: .battery, lidClosed: true, sleepDisabled: true),
                         Snapshot(power: .ac, lidClosed: true, sleepDisabled: false, externalDisplay: true)] {
            XCTAssertFalse(SleepRequestPolicy.allows(.closedLid, snapshot: snapshot, requestPending: false,
                enabled: false, batteryHold: false, condition: .ac))
        }
    }
    func testAutomaticSleepPreservesOtherWorkAndFailsClosedOnQueryFailure() {
        for power in [PowerSource.ac, .battery] {
            let snapshot = Snapshot(power: power, lidClosed: true, sleepDisabled: false)
            for intent in [SleepIntent.closedLid, .protection] {
                for foreign in [Bool?.some(true), nil] {
                    XCTAssertFalse(SleepRequestPolicy.allows(intent, snapshot: snapshot, requestPending: true,
                        enabled: false, batteryHold: false, condition: .ac, foreignKeepAwake: foreign))
                }
                XCTAssertTrue(SleepRequestPolicy.allows(intent, snapshot: snapshot, requestPending: true,
                    enabled: false, batteryHold: false, condition: .ac, foreignKeepAwake: false))
            }
            // Explicit user Sleep remains a distinct intent, including unavailable queries.
            for foreign in [Bool?.some(true), nil] {
                XCTAssertTrue(SleepRequestPolicy.allows(.user, snapshot: snapshot, requestPending: true,
                    enabled: false, batteryHold: false, condition: .ac, foreignKeepAwake: foreign))
            }
        }
    }
}
