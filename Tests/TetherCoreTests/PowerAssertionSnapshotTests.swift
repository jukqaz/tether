import XCTest
import IOKit.pwr_mgt
@testable import TetherCore

final class PowerAssertionSnapshotTests: XCTestCase {
    private var allOff: [String: NSNumber] {
        [kIOPMAssertPreventUserIdleSystemSleep: 0,
         kIOPMAssertPreventUserIdleDisplaySleep: 0,
         kIOPMAssertionTypePreventSystemSleep: 0,
         kIOPMAssertNetworkClientActive as String: 0,
         "UserIsActive": 0]
    }

    func testNullProcessListNeedsCorroboratedAllOffStatus() {
        let active = PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: nil) {
            (kIOReturnSuccess, allOff)
        }
        XCTAssertEqual(active?.count, 0)
        let properties: [String: Any] = ["AssertionId": NSNumber(value: 7),
            "AssertPID": NSNumber(value: 42), "AssertType": kIOPMAssertPreventUserIdleSystemSleep,
            "AssertLevel": NSNumber(value: 255)]
        XCTAssertEqual(NativeIdleAssertionBackend.confirmedLevel(id: 7, pid: 42,
            properties: properties, active: active), 0)
    }

    func testNullOrFailedStatusDoesNotProveAnEmptyList() {
        for result: (IOReturn, Any?) in [(kIOReturnError, allOff), (kIOReturnSuccess, nil),
                                         (kIOReturnSuccess, [String: NSNumber]())] {
            XCTAssertNil(PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: nil) { result })
        }
    }

    func testRelevantActiveAggregateKeepsTheObservationUnverified() {
        for type in PowerAssertionSnapshot.blockerTypes {
            var levels = allOff; levels[type] = 1
            XCTAssertNil(PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: nil) {
                (kIOReturnSuccess, levels)
            }, type)
        }
    }

    func testScreenAndNetworkActivityDoNotHideAConfirmedSystemRelease() {
        var levels = allOff
        levels[kIOPMAssertPreventUserIdleDisplaySleep] = 1
        levels[kIOPMAssertNetworkClientActive as String] = 1
        XCTAssertEqual(PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: nil,
            relevantTypes: PowerAssertionSnapshot.closedLidSleepBlockerTypes) {
                (kIOReturnSuccess, levels)
            }?.count, 0)
        for type in PowerAssertionSnapshot.closedLidSleepBlockerTypes {
            var active = levels; active[type] = 1
            XCTAssertNil(PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: nil,
                relevantTypes: PowerAssertionSnapshot.closedLidSleepBlockerTypes) {
                    (kIOReturnSuccess, active)
                }, type)
        }
    }

    func testUnrelatedStatusDoesNotPreventARelevantAllOffObservation() {
        var levels = allOff; levels["EnableIdleSleep"] = 1; levels["InternalPreventDisplaySleep"] = 1
        XCTAssertEqual(PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: nil) {
            (kIOReturnSuccess, levels)
        }?.count, 0)
        levels[kIOPMAssertPreventUserIdleDisplaySleep] = 1
        XCTAssertNil(PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: nil) {
            (kIOReturnSuccess, levels)
        })
        XCTAssertEqual(PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: nil,
            relevantTypes: [kIOPMAssertPreventUserIdleSystemSleep]) {
                (kIOReturnSuccess, levels)
            }?.count, 0)
        XCTAssertNil(PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: nil, relevantTypes: []) {
            (kIOReturnSuccess, levels)
        })
    }

    func testMissingKnownTypeIsNotACompleteAllOffObservation() {
        for type in [kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertPreventUserIdleDisplaySleep,
                     kIOPMAssertionTypePreventSystemSleep, kIOPMAssertNetworkClientActive as String] {
            var levels = allOff; levels.removeValue(forKey: type)
            XCTAssertNil(PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: nil) {
                (kIOReturnSuccess, levels)
            }, type)
        }
    }

    func testMalformedBooleanAndNonfiniteStatusRemainUnverified() {
        var malformed: [String: Any] = allOff; malformed["UserIsActive"] = "0"
        var boolean = allOff; boolean["UserIsActive"] = NSNumber(value: false)
        var nan = allOff; nan["UserIsActive"] = NSNumber(value: Double.nan)
        for value: Any in [malformed, boolean, nan] {
            XCTAssertNil(PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: nil) {
                (kIOReturnSuccess, value)
            })
        }
    }

    func testValidProcessListDoesNotRequireOrAlterAggregateStatus() {
        let entry: [String: Any] = ["AssertType": kIOPMAssertPreventUserIdleSystemSleep,
                                  "AssertLevel": NSNumber(value: 255), "AssertionId": NSNumber(value: 7)]
        let active: PowerAssertionSnapshot.ByProcess = [42: [entry]]
        var statusCalls = 0
        let decoded = PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: active) {
            statusCalls += 1; return (kIOReturnError, nil)
        }
        XCTAssertEqual(decoded?[42]?.first?["AssertionId"] as? NSNumber, 7)
        XCTAssertEqual(statusCalls, 0)
    }

    func testMalformedNonnullListCannotBecomeAnAllClearStatus() {
        var statusCalls = 0
        for value: Any in ["invalid", ["42": "invalid"], [42: "invalid"]] {
            XCTAssertNil(PowerAssertionSnapshot.decode(code: kIOReturnSuccess, byProcess: value) {
                statusCalls += 1; return (kIOReturnSuccess, allOff)
            })
        }
        XCTAssertEqual(statusCalls, 0)
    }

    func testFailedProcessQueryCannotBeReplacedByGoodStatus() {
        var statusCalls = 0
        for value: Any? in [nil, PowerAssertionSnapshot.ByProcess()] {
            XCTAssertNil(PowerAssertionSnapshot.decode(code: kIOReturnError, byProcess: value) {
                statusCalls += 1; return (kIOReturnSuccess, allOff)
            })
        }
        XCTAssertEqual(statusCalls, 0)
    }
}
