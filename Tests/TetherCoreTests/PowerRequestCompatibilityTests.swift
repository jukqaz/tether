import XCTest
@testable import TetherCore

final class PowerRequestCompatibilityTests: XCTestCase {
    func testIdleWorkFromLLMDoesNotOpposeDisplaySleep() throws {
        let request = try XCTUnwrap(PowerActivityPolicy.requests([
            SleepBlocker(pid: 30, process: "LM Studio", kind: .system, reason: "Electron")
        ], displaySleepExpected: true).first)
        XCTAssertFalse(request.opposesDisplaySleep)
        XCTAssertEqual(request.kinds, [.system])
    }

    func testDisplayRequestFromAnyUnknownLLMUsesIntentNotAppName() {
        let blockers = [SleepBlocker(pid: 30, process: "Some new LLM", kind: .display, reason: "")]
        XCTAssertTrue(PowerActivityPolicy.requests(blockers, displaySleepExpected: true)[0].opposesDisplaySleep)
        XCTAssertFalse(PowerActivityPolicy.requests(blockers, displaySleepExpected: false)[0].opposesDisplaySleep)
        // Re-evaluating after opening the lid or deferring to macOS clears the opposing-intent label.
        XCTAssertFalse(PowerActivityPolicy.requests(blockers, displaySleepExpected: false)[0].opposesDisplaySleep)
    }

    func testMixedWorkAndDisplayRequestsRemainAVisibleConflict() {
        let blockers = [SleepBlocker(pid: 30, process: "LLM", kind: .system, reason: ""),
                        SleepBlocker(pid: 30, process: "LLM", kind: .display, reason: "")]
        let result = PowerActivityPolicy.requests(blockers, displaySleepExpected: true)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kinds, [.system, .display])
        XCTAssertTrue(result[0].opposesDisplaySleep)
        XCTAssertTrue(PowerActivityPolicy.requests([], displaySleepExpected: true).isEmpty)
    }

    func testDiskActivityIsNotSystemSleepPrevention() {
        XCTAssertNil(SleepBlocker.Kind(assertionType: "PreventDiskIdle"))
        XCTAssertNil(SleepBlocker.Kind(assertionType: "UserIsActive"))
    }

    func testAssertionTypesKeepTheirDifferentSemantics() {
        XCTAssertEqual(SleepBlocker.Kind(assertionType: "PreventUserIdleSystemSleep"), .system)
        XCTAssertEqual(SleepBlocker.Kind(assertionType: "NoIdleSleepAssertion"), .system)
        XCTAssertEqual(SleepBlocker.Kind(assertionType: "PreventUserIdleDisplaySleep"), .display)
        XCTAssertEqual(SleepBlocker.Kind(assertionType: "NoDisplaySleepAssertion"), .display)
        XCTAssertEqual(SleepBlocker.Kind(assertionType: "NetworkClientActive"), .network)
        XCTAssertEqual(SleepBlocker.Kind(assertionType: "PreventSystemSleep"), .legacySystem)
        let findings = PowerActivityPolicy.requests([SleepBlocker(pid: 1, process: "Server", kind: .network, reason: "")], displaySleepExpected: true)
        XCTAssertFalse(findings[0].opposesDisplaySleep)
    }

    func testRemoteScreenAndNetworkRequestsRemainVisibleWithoutVetoingClosedLidRelease() {
        let observed: PowerAssertionSnapshot.ByProcess = [30: [
            ["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 255, "Process Name": "Remote"],
            ["AssertType": "NetworkClientActive", "AssertLevel": 255, "Process Name": "Remote"]
        ]]
        XCTAssertEqual(SystemProbe.decodeSleepBlockers(observed, excluding: [], closedLidSleepOnly: false).count, 2)
        XCTAssertTrue(SystemProbe.decodeSleepBlockers(observed, excluding: [], closedLidSleepOnly: true).isEmpty)
    }

    func testActualSystemWorkStillDefersSleepWithoutIncludingOurOwnRequests() {
        let observed: PowerAssertionSnapshot.ByProcess = [30: [
            ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255, "Process Name": "Worker"],
            ["AssertType": "PreventSystemSleep", "AssertLevel": 255, "Process Name": "Worker"],
            ["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 255, "Process Name": "Worker"]
        ], 31: [["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 0, "Process Name": "Ended"]]]
        let blockers = SystemProbe.decodeSleepBlockers(observed, excluding: [], closedLidSleepOnly: true)
        XCTAssertEqual(Set(blockers.map(\.kind)), [.system, .legacySystem])
        XCTAssertEqual(blockers.count, 2)
        XCTAssertTrue(SystemProbe.decodeSleepBlockers(observed, excluding: [30], closedLidSleepOnly: true).isEmpty)
    }

    func testElectronHelperResolvesOnlyInsideItsRunningApp() {
        let identity = PowerProcessIdentity(pid: 31, started: 100, executable: "/Applications/LLM.app/Contents/Frameworks/LLM Helper.app/Contents/MacOS/LLM Helper")
        XCTAssertEqual(PowerRequestOwnership.app(for: identity, among: [app()])?.pid, 30)
    }

    func testGenericElectronAndCaffeinateNamesCannotIdentifyAnApp() {
        for path in ["/usr/bin/caffeinate", "/usr/local/bin/ollama", "/Applications/Electron.app/Contents/MacOS/Electron", "/Applications/LLM.app.backup/Contents/MacOS/LLM"] {
            let identity = PowerProcessIdentity(pid: 31, started: 100, executable: path)
            XCTAssertNil(PowerRequestOwnership.app(for: identity, among: [app()]))
        }
    }

    func testReusedAppPIDDoesNotMatch() {
        let reused = PowerProcessIdentity(pid: 30, started: 999, executable: "/Applications/LLM.app/Contents/MacOS/LLM")
        XCTAssertNil(PowerRequestOwnership.app(for: reused, among: [app()]))
        let same = PowerProcessIdentity(pid: 30, started: 100, executable: nil)
        XCTAssertEqual(PowerRequestOwnership.app(for: same, among: [app()])?.pid, 30)
    }

    func testAmbiguousInstancesAndNoncanonicalPathsDoNotMatch() {
        let child = PowerProcessIdentity(pid: 31, started: 100, executable: "/Applications/LLM.app/Contents/Helpers/runner")
        let other = PowerRunningApp(pid: 32, started: 110, name: "LLM", bundlePath: "/Applications/LLM.app")
        XCTAssertNil(PowerRequestOwnership.app(for: child, among: [app(), other]))
        let escaped = PowerProcessIdentity(pid: 31, started: 100, executable: "/Applications/LLM.app/Contents/../../Other.app/Contents/MacOS/runner")
        XCTAssertNil(PowerRequestOwnership.app(for: escaped, among: [app()]))
    }

    func testLiveIdentityContainsMetadataOnly() throws {
        let identity = try XCTUnwrap(PowerProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
        XCTAssertGreaterThan(identity.started, 0)
        XCTAssertTrue(identity.executable?.hasPrefix("/") == true)
    }

    private func app() -> PowerRunningApp {
        PowerRunningApp(pid: 30, started: 100, name: "LLM", bundlePath: "/Applications/LLM.app")
    }
}
