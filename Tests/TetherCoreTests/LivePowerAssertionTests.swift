import XCTest
import IOKit.pwr_mgt
@testable import TetherCore

/// Opt-in native powerd tests. Only short-lived assertions belonging to this test are created;
/// no display-off, system sleep, pmset setting, or third-party assertion is changed.
final class LivePowerAssertionTests: XCTestCase {
    func testNativeDriverLeaseExpiresWithoutAppRenewalAndRearmsSameID() async throws {
        try enabled()
        let driver = await MainActor.run { IdleAssertionDriver() }
        await MainActor.run {
            driver.apply(expiry: ContinuousTime.now + 2, now: ContinuousTime.now)
            XCTAssertEqual(driver.state, .holding)
        }
        let original = await MainActor.run { driver.assertionID }
        let deadline = ContinuousTime.now + 5
        var off = false
        while ContinuousTime.now < deadline {
            off = await MainActor.run { driver.observe(); return driver.state == .inactive }
            if off { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let observedOff = off
        await MainActor.run {
            XCTAssertTrue(observedOff, "Only a successful OS active-list observation proves the deadline fired")
            XCTAssertEqual(driver.assertionID, original)
            driver.apply(expiry: ContinuousTime.now + 2, now: ContinuousTime.now)
            XCTAssertEqual(driver.state, .holding); XCTAssertEqual(driver.assertionID, original)
            driver.end(); XCTAssertNil(driver.assertionID)
        }
    }
    private func enabled() throws {
        guard ProcessInfo.processInfo.environment["TETHER_RUN_LIVE_ASSERTION_TESTS"] == "1" else {
            throw XCTSkip("Set TETHER_RUN_LIVE_ASSERTION_TESTS=1 for bounded live IOKit tests")
        }
    }
    private func create(_ type: String, name: String) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(type as CFString, name as CFString, nil, nil, nil,
            10, kIOPMAssertionTimeoutActionRelease as CFString, &id)
        XCTAssertEqual(result, kIOReturnSuccess)
        guard result == kIOReturnSuccess else { throw NSError(domain: "LiveAssertion", code: Int(result)) }
        return id
    }
    private func observed(_ name: String) throws -> [SleepBlocker] {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let all = SystemProbe.sleepBlockerSnapshot() {
                let ours = all.filter { $0.pid == getpid() && $0.reason == name }
                if !ours.isEmpty { return ours }
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        XCTFail("Timed out observing test-owned assertion")
        return []
    }
    func testNativeIdleRequestCoexistsWithDisplaySleep() throws {
        try enabled()
        let name = "Tether compatibility idle " + UUID().uuidString
        let id = try create(kIOPMAssertionTypePreventUserIdleSystemSleep, name: name)
        defer { IOPMAssertionRelease(id) }
        let blockers = try observed(name)
        XCTAssertEqual(blockers.map(\.kind), [.system])
        XCTAssertFalse(try XCTUnwrap(PowerActivityPolicy.requests(blockers, displaySleepExpected: true).first).opposesDisplaySleep)
        XCTAssertFalse(try XCTUnwrap(SystemProbe.sleepBlockerSnapshot(excluding: [getpid()])).contains { $0.reason == name })
    }
    func testNativeDisplayRequestConflictsOnlyWhileDisplaySleepIsWanted() throws {
        try enabled()
        let name = "Tether compatibility display " + UUID().uuidString
        let id = try create(kIOPMAssertionTypePreventUserIdleDisplaySleep, name: name)
        defer { IOPMAssertionRelease(id) }
        let blockers = try observed(name)
        XCTAssertEqual(blockers.map(\.kind), [.display])
        XCTAssertTrue(try XCTUnwrap(PowerActivityPolicy.requests(blockers, displaySleepExpected: true).first).opposesDisplaySleep)
        XCTAssertFalse(try XCTUnwrap(PowerActivityPolicy.requests(blockers, displaySleepExpected: false).first).opposesDisplaySleep)
    }
    func testInactiveNativeAssertionIsNotShownAsAnActiveBlocker() throws {
        try enabled()
        let name = "Tether compatibility inactive " + UUID().uuidString
        let id = try create(kIOPMAssertionTypePreventUserIdleSystemSleep, name: name)
        defer { IOPMAssertionRelease(id) }
        _ = try observed(name)
        XCTAssertEqual(IOPMAssertionSetProperty(id, kIOPMAssertionLevelKey as CFString, NSNumber(value: 0)), kIOReturnSuccess)
        // powerd can briefly refuse a query during the transition. Only a successful
        // observation with our assertion absent proves deactivation; nil never passes.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var successfulQueries = 0
        var lastMatchedLevel: Int?
        repeat {
            if let all = SystemProbe.sleepBlockerSnapshot() {
                successfulQueries += 1
                if !all.contains(where: { $0.pid == getpid() && $0.reason == name }) { return }
            }
            let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
            lastMatchedLevel = (properties?[kIOPMAssertionLevelKey as String] as? NSNumber)?.intValue
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("No successful inactive-assertion observation within 2 seconds; successfulQueries=\(successfulQueries), ownPropertyLevel=\(String(describing: lastMatchedLevel))")
    }
    func testIndependentCaffeinateSurvivesOurQueriesAndAssertionRelease() throws {
        try enabled()
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        other.arguments = ["-i", "-t", "10"]
        try other.run()
        defer { if other.isRunning { other.terminate() }; other.waitUntilExit() }
        let name = "Tether compatibility ownership " + UUID().uuidString
        let id = try create(kIOPMAssertionTypePreventUserIdleSystemSleep, name: name)
        var released = false
        defer { if !released { IOPMAssertionRelease(id) } }
        _ = try observed(name)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !(SystemProbe.sleepBlockerSnapshot() ?? []).contains(where: { $0.pid == other.processIdentifier }) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(IOPMAssertionRelease(id), kIOReturnSuccess); released = true
        for _ in 0..<20 {
            let all = try XCTUnwrap(SystemProbe.sleepBlockerSnapshot())
            XCTAssertTrue(all.contains { $0.pid == other.processIdentifier && $0.kind == .system })
            XCTAssertFalse(all.contains { $0.pid == getpid() && $0.reason == name })
            XCTAssertTrue(other.isRunning)
        }
    }
}
