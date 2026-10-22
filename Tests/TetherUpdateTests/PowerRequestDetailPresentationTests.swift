import XCTest
import TetherCore
@testable import Tether

final class PowerRequestDetailPresentationTests: XCTestCase {
    func testInstalledAndRunningAreNotPresentedAsAConfirmedRequest() {
        let previous = Localization.current; defer { Localization.current = previous }
        Localization.current = .english
        XCTAssertEqual(PowerUtilityEvidence.summary(runningPID: nil, requestPIDs: [],
            assertionsAvailable: true, opposesDisplaySleep: false), "Installed only · no request observed")
        XCTAssertEqual(PowerUtilityEvidence.summary(runningPID: 10, requestPIDs: [],
            assertionsAvailable: true, opposesDisplaySleep: false), "Running · no request observed")
        XCTAssertEqual(PowerUtilityEvidence.summary(runningPID: 10, requestPIDs: [],
            assertionsAvailable: false, opposesDisplaySleep: true), "Running · requests unavailable")
        XCTAssertEqual(PowerUtilityEvidence.summary(runningPID: nil, requestPIDs: [],
            assertionsAvailable: false, opposesDisplaySleep: false), "Installed · requests unavailable")
    }

    func testObservedRequestsDescribeOpposingIntentRatherThanFailedPhysicalSleep() {
        let previous = Localization.current; defer { Localization.current = previous }
        Localization.current = .english
        let found = PowerActivityPolicy.requests([
            SleepBlocker(pid: 10, process: "Example", kind: .system, reason: "private payload", assertionType: "PreventUserIdleSystemSleep"),
            SleepBlocker(pid: 10, process: "Example", kind: .display, reason: "", assertionType: "PreventUserIdleDisplaySleep")
        ], displaySleepExpected: true)[0]
        XCTAssertTrue(found.opposesDisplaySleep)
        XCTAssertEqual(Set(found.assertionTypes), ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"])
        let title = PowerUtilityEvidence.summary(runningPID: 10, requestPIDs: [10],
            assertionsAvailable: true, opposesDisplaySleep: found.opposesDisplaySleep)
        XCTAssertEqual(title, "Request observed · opposes display sleep")
        XCTAssertFalse(title.contains("failed"))
        XCTAssertTrue(PowerRequestEffects.effect(.system).contains("lid-close or explicit Sleep"))
        XCTAssertTrue(PowerRequestEffects.effect(.display).contains("Idle display sleep: prevented"))
        XCTAssertTrue(PowerRequestEffects.effect(.legacySystem).contains("not confirmed"))
    }

    func testFreshnessNeverConvertsMissingOrOldCaptureToCurrentEvidence() {
        let previous = Localization.current; defer { Localization.current = previous }
        Localization.current = .english
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(PowerObservationFreshness.summary(checkedAt: nil, now: now, refreshing: false), "Not checked yet.")
        XCTAssertTrue(PowerObservationFreshness.summary(checkedAt: now.addingTimeInterval(-46), now: now, refreshing: false).contains("Previous observation"))
        XCTAssertTrue(PowerObservationFreshness.summary(checkedAt: now.addingTimeInterval(1), now: now, refreshing: false).contains("not confirmed"))
        XCTAssertTrue(PowerObservationFreshness.summary(checkedAt: now.addingTimeInterval(-100), now: now, refreshing: true).contains("previous check"))
        XCTAssertTrue(PowerObservationFreshness.summary(checkedAt: now.addingTimeInterval(-2), now: now, refreshing: false).contains("can change"))
    }

    @MainActor
    func testSleepInfluencesSeparateSavedTimeoutsInputAndWorkRequests() {
        let previous = Localization.current; defer { Localization.current = previous }
        Localization.current = .english
        let inspector = PowerActivityInspector(simulated: true)
        XCTAssertEqual(inspector.sleepPreferences.setting(for: inspector.observedPower)?.systemMinutes, 0)
        XCTAssertEqual(SleepInfluenceView.timeout(0), "Disabled")
        XCTAssertEqual(SleepInfluenceView.timeout(nil), "Not confirmed")
        XCTAssertEqual(SleepInfluenceView.timeout(10), "10 min")
        XCTAssertEqual(inspector.activitySignals?.first?.source, "Codex Computer Use")
        XCTAssertFalse(inspector.requests.contains { $0.process == "WindowServer" })
        XCTAssertTrue(inspector.systemRequests.isEmpty)
        XCTAssertEqual(inspector.appRequests.count, inspector.requests.count)
        let observedAt = inspector.checkedAt
        inspector.reclassify(displaySleepExpected: false)
        XCTAssertEqual(inspector.checkedAt, observedAt, "Reclassification does not make settings or input evidence fresh")
        XCTAssertEqual(inspector.activitySignals?.first?.source, "Codex Computer Use")
    }

    @MainActor
    func testNativeReadOnlyCaptureScrubsPayloadAndDoesNotCreateWorkRequests() async throws {
        let result = await PowerRequestReader.capture(includePreferences: true)
        let blockers = try XCTUnwrap(result.blockers, "IOKit request observation must be available on the target Mac")
        XCTAssertTrue(blockers.allSatisfy { $0.reason.isEmpty })
        XCTAssertFalse(blockers.contains { $0.pid == getpid() })
        XCTAssertFalse(blockers.contains { $0.assertionType == "UserIsActive" || $0.assertionType == "InternalPreventDisplaySleep" })
        XCTAssertFalse(result.systemPIDs.contains(getpid()))
        let setting = try XCTUnwrap(result.sleepPreferences.setting(for: result.power))
        XCTAssertNotNil(setting.systemMinutes)
        XCTAssertNotNil(setting.displayMinutes)
        XCTAssertTrue((result.signals ?? []).allSatisfy { $0.pid != getpid() })
    }
}
