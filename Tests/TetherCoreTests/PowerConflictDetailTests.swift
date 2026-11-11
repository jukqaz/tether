import XCTest
@testable import TetherCore

final class PowerConflictDetailTests: XCTestCase {
    func testActualTypesAreDetailedWithoutExposingPrivatePayload() {
        let observed: PowerAssertionSnapshot.ByProcess = [30: [
            ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255,
             "Process Name": "Worker", "AssertName": "Private conversation title"],
            ["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 255, "Process Name": "Worker"]
        ]]
        let findings = PowerActivityPolicy.requests(
            SystemProbe.decodeSleepBlockers(observed, excluding: [], closedLidSleepOnly: false), displaySleepExpected: true)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].assertionTypes, ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep"])
        XCTAssertTrue(findings[0].opposesDisplaySleep)
        XCTAssertFalse(String(describing: findings).contains("Private conversation title"))
    }
    func testUnlistedAppsAreStillDetectedAndIdleWorkDoesNotBecomeDisplayConflict() {
        let unknown = SleepBlocker(pid: 77, process: "New AI App", kind: .system, reason: "",
                                   assertionType: "PreventUserIdleSystemSleep")
        XCTAssertNil(PowerAppCatalog.name(bundleID: "unknown.power.app"))
        let findings = PowerActivityPolicy.requests([unknown], displaySleepExpected: true)
        XCTAssertEqual(findings[0].process, "New AI App")
        XCTAssertFalse(findings[0].opposesDisplaySleep)
    }
    func testInstalledCatalogIdentifiersAreUniqueAndExact() {
        XCTAssertEqual(Set(PowerAppCatalog.bundleIDs.map { $0.lowercased() }).count, PowerAppCatalog.bundleIDs.count)
        for identifier in PowerAppCatalog.bundleIDs { XCTAssertNotNil(PowerAppCatalog.name(bundleID: identifier)) }
        XCTAssertNil(PowerAppCatalog.name(bundleID: "fake.com.if.Amphetamine"))
        XCTAssertTrue(PowerActivityPolicy.requests([], displaySleepExpected: true).isEmpty)
    }
}
