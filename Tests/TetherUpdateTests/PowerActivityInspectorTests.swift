import XCTest
@testable import Tether
import TetherCore

final class PowerActivityInspectorTests: XCTestCase {
    @MainActor
    func testSampleDoesNotClaimRemoteConnectionOrInput() async {
        let inspector = PowerActivityInspector(simulated: true)
        let context = try! XCTUnwrap(inspector.remoteContext)
        XCTAssertFalse(context.providers.isEmpty)
        for provider in context.providers {
            XCTAssertNil(provider.connection.value)
            XCTAssertNil(provider.frameDelivery.value)
            XCTAssertNil(provider.inputRoundTrip.value)
            XCTAssertNil(provider.authentication.value)
        }
    }

    @MainActor
    func testScopeChangeClearsRemoteFactsWithoutChangingCapturedPowerRequests() async {
        let inspector = PowerActivityInspector(simulated: true)
        let requests = inspector.requests, checkedAt = inspector.checkedAt
        inspector.invalidateRemoteContext(displayRevision: 1, sessionKey: "new-session")
        XCTAssertNil(inspector.remoteContext)
        XCTAssertNil(inspector.displays)
        XCTAssertEqual(inspector.requests, requests)
        XCTAssertEqual(inspector.checkedAt, checkedAt)
        XCTAssertFalse(inspector.busy)
    }

    @MainActor
    func testRefreshClearsOldDisplayFactsBeforePendingCheckWithoutChangingOtherEvidence() async {
        let inspector = PowerActivityInspector(simulated: true)
        let requests = inspector.requests, checkedAt = inspector.checkedAt
        XCTAssertNotNil(inspector.displays)
        inspector.refresh(displaySleepExpected: true, displayRevision: 2, sessionKey: "test")
        XCTAssertNil(inspector.displays)
        XCTAssertNil(inspector.remoteContext)
        XCTAssertEqual(inspector.requests, requests)
        XCTAssertEqual(inspector.checkedAt, checkedAt)
        inspector.cancel()
    }

    @MainActor
    func testStaleDisplayScopeCannotPublishCollection() async {
        let inspector = PowerActivityInspector(simulated: true)
        inspector.refresh(displaySleepExpected: true, displayRevision: 2, sessionKey: "test", isScopeCurrent: { false })
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(inspector.remoteContext)
        XCTAssertNil(inspector.displays)
        XCTAssertFalse(inspector.busy)
    }

    @MainActor
    func testCancelCannotPublishPendingCollection() async {
        let inspector = PowerActivityInspector(simulated: true)
        inspector.refresh(displaySleepExpected: true, displayRevision: 2, sessionKey: "test")
        inspector.cancel()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(inspector.remoteContext)
        XCTAssertNil(inspector.displays)
        XCTAssertFalse(inspector.busy)
    }

    @MainActor
    func testReclassificationDoesNotRenewRemoteEvidence() async {
        let inspector = PowerActivityInspector(simulated: true)
        let context = try! XCTUnwrap(inspector.remoteContext), checkedAt = inspector.checkedAt
        let displays = inspector.displays
        inspector.reclassify(displaySleepExpected: false)
        XCTAssertEqual(inspector.remoteContext?.generation, context.generation)
        XCTAssertEqual(inspector.displays, displays)
        XCTAssertEqual(inspector.checkedAt, checkedAt)
    }

    @MainActor
    func testHeadlessInventoryIsDifferentFromQueryFailure() async {
        let headless = DisplayProbe.resolve(observations: [], profile: nil)
        XCTAssertTrue(PowerActivityInspector.inventoryIsCurrent(report: headless, current: []))
        XCTAssertFalse(PowerActivityInspector.inventoryIsCurrent(report: headless, current: nil))
        XCTAssertFalse(PowerActivityInspector.inventoryIsCurrent(report: DisplayProbe.resolve(observations: nil, profile: nil), current: []))
        let inspector = PowerActivityInspector(simulated: true)
        var captures = 0
        func remote() -> RemoteInteropContext {
            captures += 1
            return RemoteProviderProbe.sample(generation: 1, displayRevision: 1, sessionKey: "test")
        }
        inspector.publishDisplayCollection(report: headless, current: [], remote: remote)
        XCTAssertEqual(inspector.displays, headless)
        XCTAssertTrue(inspector.displays?.graphicsAvailable == true)
        XCTAssertNotNil(inspector.remoteContext)
        XCTAssertEqual(captures, 1)
        inspector.publishDisplayCollection(report: headless, current: nil, remote: remote)
        XCTAssertNil(inspector.displays)
        XCTAssertNil(inspector.remoteContext)
        XCTAssertEqual(captures, 1)
        inspector.publishDisplayCollection(report: DisplayProbe.resolve(observations: nil, profile: nil), current: [], remote: remote)
        XCTAssertNil(inspector.displays)
        XCTAssertNil(inspector.remoteContext)
        XCTAssertEqual(captures, 1)
    }

    @MainActor
    func testNewDisplayIDOrResolutionInvalidatesSameTopology() async {
        func screen(id: UInt32, width: Int) -> DisplayObservation {
            .init(id: id, builtIn: false, vendor: 0xeee0, model: 0xeee1,
                  width: width, height: 1440, active: true, asleep: false)
        }
        let initial = [screen(id: 1, width: 2560)]
        let report = DisplayProbe.resolve(observations: initial, profile: nil)
        XCTAssertTrue(PowerActivityInspector.inventoryIsCurrent(report: report, current: initial))
        XCTAssertFalse(PowerActivityInspector.inventoryIsCurrent(report: report, current: [screen(id: 2, width: 2560)]))
        XCTAssertFalse(PowerActivityInspector.inventoryIsCurrent(report: report, current: [screen(id: 1, width: 1920)]))
    }

    @MainActor
    func testLateInventoryChangeCannotPairOldDisplayReasonWithNewCheckTime() async {
        let virtual = DisplayObservation(id: 15, builtIn: false, vendor: 0xeee0, model: 0xeee1,
                                         width: 2560, height: 1440, active: true, asleep: false)
        let report = DisplayProbe.resolve(observations: [virtual], profile: nil)
        let inspector = PowerActivityInspector(simulated: true)
        let requests = inspector.requests, checkedAt = inspector.checkedAt
        var captures = 0
        func remote() -> RemoteInteropContext {
            captures += 1
            return RemoteProviderProbe.sample(generation: 1, displayRevision: 1, sessionKey: "unchanged-session")
        }
        inspector.publishDisplayCollection(report: report, current: [virtual], remote: remote)
        XCTAssertEqual(inspector.displays?.virtualCount, 1)
        XCTAssertNotNil(inspector.remoteContext)
        // The screen disappeared before its notification updated the caller's revision.
        inspector.publishDisplayCollection(report: report, current: [], remote: remote)
        XCTAssertNil(inspector.displays)
        XCTAssertNil(inspector.remoteContext)
        XCTAssertNotNil(inspector.note)
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(inspector.requests, requests)
        XCTAssertEqual(inspector.checkedAt, checkedAt)
        // The surrounding collection may now report its completion time, but not old facts.
        inspector.checkedAt = checkedAt?.addingTimeInterval(2)
        XCTAssertNil(inspector.displays)
        XCTAssertNil(inspector.remoteContext)
    }
}
