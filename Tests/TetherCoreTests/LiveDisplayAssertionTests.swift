import XCTest
import IOKit.pwr_mgt
@testable import TetherCore

/// Opt-in API checks only: all test-owned requests have finite timeouts of at most
/// ten seconds. This does not prove physical display behavior or bypass screen locks.
/// No power preferences, security settings, user input or foreign requests are changed.
final class LiveDisplayAssertionTests: XCTestCase {
    private struct AssertionIdentity {
        let id: UInt32
        let uniqueID: NSNumber?
    }

    @MainActor
    func testNativeDisplayLeaseExpiresWithoutRenewalAndRearmsSameID() async throws {
        try enabled()
        let backend = NativeIdleAssertionBackend(type: .display)
        let driver = IdleAssertionDriver(backend: backend)
        defer { driver.end() }
        let started = ContinuousTime.now
        driver.apply(expiry: started + 2, now: started)
        let id = try XCTUnwrap(driver.assertionID)
        let identity = try observedIdentity(id: id, type: kIOPMAssertPreventUserIdleDisplaySleep)
        let initiallyOn = try await waitForObservation(seconds: 1) {
            driver.observe(); return driver.state == .holding
        }
        XCTAssertTrue(initiallyOn, "A successful powerd observation must confirm the display lease")
        guard initiallyOn else { return }
        XCTAssertNil(NativeIdleAssertionBackend().level(id: id), "System observation must reject a display allocation")
        let observedOff = try await waitForObservation(seconds: 5) {
            driver.observe(); return driver.state == .inactive
        }
        XCTAssertTrue(observedOff, "Unavailable queries cannot prove the finite native timeout fired")
        guard observedOff else { return }
        XCTAssertEqual(driver.assertionID, id)
        XCTAssertNil(driver.confirmedExpiry)
        let rearmedAt = ContinuousTime.now
        driver.apply(expiry: rearmedAt + 2, now: rearmedAt)
        let rearmed = try await waitForObservation(seconds: 1) {
            driver.observe(); return driver.state == .holding
        }
        XCTAssertTrue(rearmed); XCTAssertEqual(driver.assertionID, id)
        driver.end()
        XCTAssertNil(driver.assertionID); XCTAssertEqual(driver.state, .inactive)
        let released = try await waitForObservation(seconds: 1) { self.isAbsent(identity) }
        XCTAssertTrue(released, "A successful active-list query must confirm our release")
    }

    @MainActor
    func testSystemAndDisplayReleaseIndependentlyAndPreserveAnotherOwnedWorkRequest() async throws {
        try enabled()
        let foreignID = try createIndependentWorkAssertion()
        defer { IOPMAssertionRelease(foreignID) }
        let systemBackend = NativeIdleAssertionBackend()
        let displayBackend = NativeIdleAssertionBackend(type: .display)
        let system = IdleAssertionDriver(backend: systemBackend)
        let display = IdleAssertionDriver(backend: displayBackend)
        defer { display.end(); system.end() }
        let started = ContinuousTime.now
        system.apply(expiry: started + 8, now: started)
        display.apply(expiry: started + 8, now: started)
        let systemID = try XCTUnwrap(system.assertionID)
        let displayID = try XCTUnwrap(display.assertionID)
        let systemIdentity = try observedIdentity(id: systemID, type: kIOPMAssertPreventUserIdleSystemSleep)
        let displayIdentity = try observedIdentity(id: displayID, type: kIOPMAssertPreventUserIdleDisplaySleep)
        XCTAssertNotEqual(systemID, displayID)
        XCTAssertNotEqual(systemID, foreignID); XCTAssertNotEqual(displayID, foreignID)
        let allOn = try await waitForObservation(seconds: 1) {
            systemBackend.level(id: systemID) == kIOPMAssertionLevelOn
                && displayBackend.level(id: displayID) == kIOPMAssertionLevelOn
                && systemBackend.level(id: foreignID) == kIOPMAssertionLevelOn
        }
        XCTAssertTrue(allOn, "All three independent finite requests must be observed on")
        guard allOn else { return }
        XCTAssertNil(systemBackend.level(id: displayID)); XCTAssertNil(displayBackend.level(id: systemID))

        display.end()
        XCTAssertNil(display.assertionID)
        let displayReleased = try await waitForObservation(seconds: 1) {
            self.isAbsent(displayIdentity) && systemBackend.level(id: systemID) == kIOPMAssertionLevelOn
                && systemBackend.level(id: foreignID) == kIOPMAssertionLevelOn
        }
        XCTAssertTrue(displayReleased, "Releasing the display request must leave both work requests on")
        guard displayReleased else { return }

        let reacquiredAt = ContinuousTime.now
        display.apply(expiry: reacquiredAt + 8, now: reacquiredAt)
        let secondDisplayID = try XCTUnwrap(display.assertionID)
        let secondDisplayIdentity = try observedIdentity(id: secondDisplayID, type: kIOPMAssertPreventUserIdleDisplaySleep)
        XCTAssertNotEqual(secondDisplayID, systemID); XCTAssertNotEqual(secondDisplayID, foreignID)
        let displayOn = try await waitForObservation(seconds: 1) {
            displayBackend.level(id: secondDisplayID) == kIOPMAssertionLevelOn
        }
        XCTAssertTrue(displayOn)
        guard displayOn else { return }
        system.end()
        XCTAssertNil(system.assertionID)
        let systemReleased = try await waitForObservation(seconds: 1) {
            self.isAbsent(systemIdentity) && displayBackend.level(id: secondDisplayID) == kIOPMAssertionLevelOn
                && systemBackend.level(id: foreignID) == kIOPMAssertionLevelOn
        }
        XCTAssertTrue(systemReleased, "Releasing the system request must leave display and independent work on")
        display.end()
        XCTAssertNil(display.assertionID)
        let independentPreserved = try await waitForObservation(seconds: 1) {
            self.isAbsent(secondDisplayIdentity) && systemBackend.level(id: foreignID) == kIOPMAssertionLevelOn
        }
        XCTAssertTrue(independentPreserved, "Ending both drivers must preserve the independent work request")
    }

    private func enabled() throws {
        guard ProcessInfo.processInfo.environment["TETHER_RUN_LIVE_ASSERTION_TESTS"] == "1" else {
            throw XCTSkip("Set TETHER_RUN_LIVE_ASSERTION_TESTS=1 for bounded live IOKit display tests")
        }
    }

    private func createIndependentWorkAssertion() throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let code = IOPMAssertionCreateWithDescription(kIOPMAssertPreventUserIdleSystemSleep as CFString,
            ("Tether independent display-test work " + UUID().uuidString) as CFString,
            nil, nil, nil, 10, kIOPMAssertionTimeoutActionTurnOff as CFString, &id)
        guard code == kIOReturnSuccess else { throw NSError(domain: "LiveDisplayAssertion", code: Int(code)) }
        return id
    }

    private func observedIdentity(id: UInt32, type: String) throws -> AssertionIdentity {
        let properties = try XCTUnwrap(IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any])
        XCTAssertEqual((properties["AssertionId"] as? NSNumber)?.uint32Value, id)
        XCTAssertEqual((properties["AssertPID"] as? NSNumber)?.int32Value, getpid())
        XCTAssertEqual(properties[kIOPMAssertionTypeKey as String] as? String, type)
        return AssertionIdentity(id: id, uniqueID: properties["GlobalUniqueID"] as? NSNumber)
    }

    private func isAbsent(_ identity: AssertionIdentity) -> Bool {
        guard let active = PowerAssertionSnapshot.read(relevantTypes: [kIOPMAssertPreventUserIdleSystemSleep,
                                                                      kIOPMAssertPreventUserIdleDisplaySleep]) else { return false }
        for entry in active[NSNumber(value: getpid())] ?? [] {
            guard let id = entry["AssertionId"] as? NSNumber else { return false }
            if id.uint32Value == identity.id || identity.uniqueID.map({ $0 == entry["GlobalUniqueID"] as? NSNumber }) == true {
                return false
            }
        }
        return true
    }

    @MainActor
    private func waitForObservation(seconds: Double, _ observed: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousTime.now + seconds
        repeat {
            if observed() { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while ContinuousTime.now < deadline
        return false
    }
}
