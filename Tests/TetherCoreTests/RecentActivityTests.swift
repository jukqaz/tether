import XCTest
@testable import TetherCore

final class RecentActivityTests: XCTestCase {
    private func line(_ message: String, time: String = "12:00:00") -> String { "2026-09-28 \(time) \(message)\n" }
    func testReservationStartAndTimeEndAreNewestFirst() {
        let text = line("activity: battery session reserved") + line("battery hold armed", time: "12:01:00") + line("battery hold ended: time is up", time: "12:46:00")
        XCTAssertEqual(RecentActivity.parse(text).map(\.kind), [.holdEndedTime, .holdStarted, .reserved])
    }
    func testSleepRequestsAreDistinctFromOSTransitionNotifications() {
        let text = line("sleep now requested") + line("command result: accepted (physical sleep not confirmed)") + line("system power: will sleep") + line("system power: powered on")
        XCTAssertEqual(RecentActivity.parse(text).map(\.kind), [.poweredOn, .willSleep, .sleepRequested])
    }
    func testAppExitAndOverrideReleaseNeverBecomeSleepEvents() {
        let text = line("app session connected")
            + line("app session disconnected: app requested detach; ending temporary work and releasing owned power changes")
            + line("clamshell override released")
        XCTAssertEqual(RecentActivity.parse(text).map(\.kind), [.overrideOff, .appDisconnected, .appConnected])
    }
    func testAutomaticSleepDeferralsRemainDistinctFromRequestsAndOSTransitions() {
        let text = line("clamshell override released")
            + line("automatic sleep deferred: otherRequests; foreign requests preserved")
            + line("automatic sleep deferred: observationUnavailable; foreign requests preserved")
            + line("sleep now requested")
            + line("system power: will sleep")
        XCTAssertEqual(RecentActivity.parse(text).map(\.kind),
            [.willSleep, .sleepRequested, .sleepDeferredObservationUnavailable, .sleepDeferredOtherRequests, .overrideOff])
    }
    func testAutomaticSleepDeferralAllowlistRejectsUnknownReasonsAndVariablePayloads() {
        let secret = "/Users/alice/private-prompt"
        let text = line("automatic sleep deferred: otherRequests; foreign requests preserved")
            + line("automatic sleep deferred: observationUnavailable; foreign requests preserved")
            + line("automatic sleep deferred: otherRequests; foreign requests preserved \(secret)")
            + line("automatic sleep deferred: \(secret); foreign requests preserved")
            + line("automatic sleep deferred: futureReason; foreign requests preserved")
        let events = RecentActivity.parse(text)
        XCTAssertEqual(events.map(\.kind), [.sleepDeferredObservationUnavailable, .sleepDeferredOtherRequests])
        XCTAssertFalse(events.map { $0.kind.title }.joined().contains(secret))
    }
    func testInitialObservationIsNotReportedAsAConnectionEventAndRepeatedReadingsStayQuiet() {
        let first = "observed: power=ac lid=open block=none"
        let next = "observed: power=battery lid=closed block=heat"
        let events = RecentActivity.parse(line(first) + line(first) + line(next) + line(next))
        XCTAssertEqual(events.map(\.kind), [.protectionStop, .lidClosed, .powerDisconnected])
        XCTAssertEqual(Set(events.map(\.id)).count, 3)
    }
    func testBoundedHistoryHasUniqueIDsEvenWhenOneLineEmitsMultipleEvents() {
        var text = line("observed: power=ac lid=open block=none")
        for index in 0..<80 {
            text += line("observed: power=\(index.isMultiple(of: 2) ? "battery" : "ac") lid=\(index.isMultiple(of: 2) ? "closed" : "open") block=none")
        }
        let events = RecentActivity.parse(text, limit: 20)
        XCTAssertEqual(events.count, 20); XCTAssertEqual(Set(events.map(\.id)).count, 20)
        XCTAssertTrue(RecentActivity.parse(text, limit: 0).isEmpty)
    }
    func testUnknownPayloadsAndRawErrorsAreNeverPresented() {
        let secret = "/Users/alice/private-prompt"
        let text = line("rawURL=\(secret)") + line("error: pmset test failed \(secret)") + line("diagnostic marker \(secret)")
        let events = RecentActivity.parse(text)
        XCTAssertEqual(events.map(\.kind), [.commandFailed])
        XCTAssertFalse(events.map { $0.kind.title }.joined().contains(secret))
    }
    func testMalformedAndPartialLinesAreIgnoredWithoutReorderingClockCorrections() {
        let text = "partial line\n2026-99-99 88:88:88 sleep now requested\n" + line("battery hold armed", time: "13:00:00") + line("battery hold cancelled", time: "12:00:00")
        XCTAssertEqual(RecentActivity.parse(text).map(\.kind), [.cancelled, .holdStarted])
    }
    func testMarkerAndForeignOverrideAreRecognized() {
        XCTAssertEqual(RecentActivity.parse(line("diagnostic marker \(UUID().uuidString)")).first?.kind, .marker)
        XCTAssertEqual(RecentActivity.parse(line("power override changed externally; automatic reapplication suspended")).first?.kind, .foreignOverride)
    }

    func testDisplayRecoveryEventsAreDistinctFromSystemSleepAndDoNotExposeDiagnosticPayloads() {
        let text = line("display-off attempt 2/3; source=CoreGraphics; displayRequestPIDs=123")
            + line("activity: display recovery requested")
            + line("display sleep confirmed; hold retained; requests=2/3; source=CoreGraphics")
            + line("activity: display sleep confirmed")
            + line("activity: display recovery stopped")
            + line("activity: display recovery requested /Users/alice/private-prompt")
        let events = RecentActivity.parse(text)
        XCTAssertEqual(events.map(\.kind), [.screenStop, .screenConfirmed, .screenRetry])
        XCTAssertFalse(events.map { $0.kind.title }.joined().contains("123"))
    }

    func testEarlierDisplayStopLogRemainsReadable() {
        XCTAssertEqual(RecentActivity.parse(line("display sleep not maintained; hold stopped without repeated display-off requests")).map(\.kind), [.screenStop])
    }
}

final class SessionDurationTests: XCTestCase {
    func testFixedPresetsRespectTheCapWithoutAddingNewLongDurations() {
        XCTAssertEqual(SessionDuration.presets, [5, 10, 15, 30, 60, 120])
        XCTAssertEqual(SessionDuration.choices(maximum: 120), [5, 10, 15, 30, 60, 120])
        XCTAssertEqual(SessionDuration.choices(maximum: 90), [5, 10, 15, 30, 60])
        XCTAssertEqual(SessionDuration.choices(maximum: 30), [5, 10, 15, 30])
        XCTAssertEqual(SessionDuration.choices(maximum: 240), [5, 10, 15, 30, 60, 120])
        XCTAssertEqual(SessionDuration.choices(maximum: Int.max), [5, 10, 15, 30, 60, 120])
    }

    func testLegacySavedSelectionRemainsAvailableWithoutDuplicates() {
        XCTAssertEqual(SessionDuration.choices(maximum: 90, including: 45), [5, 10, 15, 30, 45, 60])
        XCTAssertEqual(SessionDuration.choices(maximum: 30, including: 45), [5, 10, 15, 30])
        XCTAssertEqual(SessionDuration.choices(maximum: 30, including: 30), [5, 10, 15, 30])
        XCTAssertEqual(SessionDuration.choices(maximum: 240, including: 180), [5, 10, 15, 30, 60, 120, 180])
        for invalid in [0, -1, 121] {
            XCTAssertEqual(SessionDuration.choices(maximum: 120, including: invalid), [5, 10, 15, 30, 60, 120])
        }
    }

    func testCapsBelowTheFirstPresetStillOfferOneSafeDuration() {
        XCTAssertEqual(SessionDuration.choices(maximum: 10), [5, 10])
        XCTAssertEqual(SessionDuration.choices(maximum: 10, including: 3), [3, 5, 10])
        XCTAssertEqual(SessionDuration.choices(maximum: 3), [3])
        XCTAssertEqual(SessionDuration.choices(maximum: 3, including: 2), [2, 3])
        XCTAssertEqual(SessionDuration.choices(maximum: 0), [1])
        XCTAssertEqual(SessionDuration.choices(maximum: -10), [1])
    }
}
