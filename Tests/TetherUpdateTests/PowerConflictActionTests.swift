import XCTest
@testable import Tether
import TetherCore

final class PowerConflictActionTests: XCTestCase {
    @MainActor
    func testExampleActionsCannotOpenOrRevealRealApps() async {
        let inspector = PowerActivityInspector(simulated: true)
        XCTAssertEqual(inspector.installedUtilities.count, 2)
        let active = inspector.installedUtilities[0]
        let installedOnly = inspector.installedUtilities[1]
        XCTAssertEqual(active.requestKinds, [.system, .display])
        XCTAssertTrue(active.opposesDisplaySleep)
        XCTAssertNil(installedOnly.runningPID)
        XCTAssertTrue(installedOnly.requestKinds.isEmpty)
        for app in inspector.installedUtilities {
            XCTAssertFalse(inspector.canOpenUtility(app))
            XCTAssertFalse(inspector.canRevealUtility(app))
        }
        XCTAssertFalse(inspector.canReveal(204))
        inspector.reclassify(displaySleepExpected: false)
        XCTAssertFalse(inspector.installedUtilities[0].opposesDisplaySleep)
        XCTAssertEqual(inspector.installedUtilities[0].requestKinds, [.system, .display])
    }
    @MainActor
    func testLocationActionsRejectChangedOrMissingInstallation() async {
        let inspector = PowerActivityInspector(simulated: false)
        let item = PowerActivityInspector.InstalledUtility(name: "Amphetamine", bundleID: "com.if.Amphetamine",
            bundleURL: URL(fileURLWithPath: "/nonexistent/Tether-test/Amphetamine.app"), runningPID: nil,
            requestKinds: [], requestPIDs: [], opposesDisplaySleep: false, assertionsAvailable: false)
        XCTAssertFalse(inspector.canOpenUtility(item))
        XCTAssertFalse(inspector.canRevealUtility(item))
        inspector.revealUtility(item)
        XCTAssertNotNil(inspector.note)
        XCTAssertFalse(inspector.canReveal(Int32.max))
    }
}
