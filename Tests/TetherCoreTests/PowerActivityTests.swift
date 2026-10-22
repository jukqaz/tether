import XCTest
@testable import TetherCore

final class PowerActivityTests: XCTestCase {
    func testRunningUtilityDoesNotImplyConflict() {
        XCTAssertEqual(PowerAppCatalog.name(bundleID: "com.if.Amphetamine"), "Amphetamine")
        XCTAssertNil(PowerAppCatalog.name(bundleID: "unrelated.Amphetamine"))
        XCTAssertTrue(PowerActivityPolicy.requests([], displaySleepExpected: true).isEmpty)
    }

    func testDisplayRequestOnlyConflictsWithOpposingIntent() {
        let items = [SleepBlocker(pid: 20, process: "Remote", kind: .display, reason: ""),
                     SleepBlocker(pid: 20, process: "Remote", kind: .display, reason: "duplicate"),
                     SleepBlocker(pid: 20, process: "Remote", kind: .system, reason: ""),
                     SleepBlocker(pid: 21, process: "Backup", kind: .system, reason: "")]
        let findings = PowerActivityPolicy.requests(items, displaySleepExpected: true)
        XCTAssertEqual(findings.count, 2)
        XCTAssertTrue(findings[0].opposesDisplaySleep)
        XCTAssertEqual(findings[0].kinds, [.display, .system])
        XCTAssertFalse(findings[1].opposesDisplaySleep)
        XCTAssertTrue(PowerActivityPolicy.requests(items, displaySleepExpected: false).allSatisfy { !$0.opposesDisplaySleep })
    }

    func testUnknownIsNotMismatch() {
        XCTAssertFalse(PowerActivityPolicy.globalMismatch(expected: nil, observed: true))
        XCTAssertFalse(PowerActivityPolicy.globalMismatch(expected: false, observed: nil))
        XCTAssertFalse(PowerActivityPolicy.globalMismatch(expected: true, observed: true))
        XCTAssertTrue(PowerActivityPolicy.globalMismatch(expected: false, observed: true))
    }

}
