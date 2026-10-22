import XCTest
@testable import TetherCore

final class UserSessionActivityTests: XCTestCase {
    private func sample() -> UserSessionStatus {
        UserSessionStatus(power: .battery, thermal: 0, batteryPercent: 80, limits: nil, enabled: true,
            automaticEnabled: false, automaticActive: false, powerCondition: .ac, automaticMinutes: 60,
            batteryHoldUntil: nil, pendingBatteryMinutes: nil, manualActive: true, holding: true,
            until: Date(timeIntervalSince1970: 2000), blockReason: nil, error: nil, canStart: true,
            manualBatteryRemaining: 7200, manualEndReason: nil, manualMaximumMinutes: 120,
            canStartBatteryHold: true, batteryRemaining: 14400)
    }
    func testArchiveRetainsOnlyBoundedDecisionsAndNeverRestoresActiveRecording() throws {
        let date = Date(timeIntervalSince1970: 2_000_000)
        var activity = UserSessionActivity()
        activity.observe(sample(), now: 0, date: date)
        activity.setRecording(true, now: 0, date: date)
        var status = sample(); status.batteryPercent = 79
        activity.observe(status, now: 1, date: date.addingTimeInterval(1))
        let saved = try activity.archivedDecisions(date: date.addingTimeInterval(2))
        XCTAssertLessThan(saved.count, UserSessionActivity.maximumArchiveBytes)
        let restored = try UserSessionActivity(archive: saved, date: date.addingTimeInterval(2))
        XCTAssertFalse(restored.entries.contains { $0.kind == .detail })
        XCTAssertFalse(restored.isRecording(now: 2)); XCTAssertNil(restored.recordingUntil)
        XCTAssertEqual(restored.entries.first?.state?.manualActive, true) // historical fact only
        let expired = try UserSessionActivity(archive: saved, date: date.addingTimeInterval(72 * 3600 + 10))
        XCTAssertTrue(expired.entries.isEmpty)
    }
    func testArchiveFailureCannotTurnIntoRuntimeOrFreeText() throws {
        XCTAssertThrowsError(try UserSessionActivity(archive: Data(repeating: 0, count: UserSessionActivity.maximumArchiveBytes + 1)))
        XCTAssertThrowsError(try UserSessionActivity(archive: Data("corrupt".utf8)))
        var activity = UserSessionActivity(), state = sample()
        state.error = "private secret"; state.blockReason = "private endpoint"
        activity.observe(state)
        let saved = try activity.archivedDecisions()
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("private"))
    }
    func testCountdownAndChargeChangesDoNotFloodBasicRecords() {
        var activity = UserSessionActivity(), status = sample()
        XCTAssertEqual(activity.observe(status, now: 100).count, 1)
        for index in 1...100 {
            status.manualBatteryRemaining -= 3; status.batteryRemaining -= 3
            status.batteryPercent = 80 - index / 10
            XCTAssertTrue(activity.observe(status, now: Double(100 + index)).isEmpty)
        }
        status.holding = false; status.error = "release unconfirmed"
        XCTAssertEqual(activity.observe(status, now: 201).first?.kind, .released)
        XCTAssertEqual(activity.entries.count, 2)
    }
    func testDetailedRecordingUsesContinuousTimeAndClampsDuration() {
        var activity = UserSessionActivity(), status = sample()
        let wall = Date(timeIntervalSince1970: 1000)
        activity.observe(status, now: 100, date: wall)
        activity.setRecording(true, minutes: 1, now: 100, date: wall)
        status.manualBatteryRemaining = 7199
        XCTAssertEqual(activity.observe(status, now: 101, date: wall.addingTimeInterval(-999)).first?.kind, .detail)
        XCTAssertTrue(activity.isRecording(now: 159.999))
        XCTAssertFalse(activity.isRecording(now: 160))
        status.manualBatteryRemaining = 7100
        let ended = activity.observe(status, now: 160, date: wall.addingTimeInterval(-2000))
        XCTAssertEqual(ended.map(\.kind), [.recordingEnded]); XCTAssertNil(activity.recordingUntil)
        activity.setRecording(true, minutes: Int.max, now: 200, date: wall)
        XCTAssertEqual(activity.recordingUntil, wall.addingTimeInterval(14400))
        XCTAssertFalse(activity.isRecording(now: 14600))
        activity.setRecording(false, now: 201, date: wall)
        XCTAssertFalse(activity.isRecording(now: 202))
    }
    func testBufferAndExportsKeepCausalOrderAfterClockCorrection() {
        var activity = UserSessionActivity()
        for index in 0..<200 { activity.mark(date: Date(timeIntervalSince1970: Double(1000 - index))) }
        XCTAssertEqual(activity.entries.count, 128)
        XCTAssertEqual(activity.entries.first?.id, 73); XCTAssertEqual(activity.entries.last?.id, 200)
        XCTAssertEqual(activity.recent(limit: Int.max).first?.id, 200)
        XCTAssertTrue(activity.recent(limit: -1).isEmpty)
        let report = activity.report(since: Date(timeIntervalSince1970: 0))
        XCTAssertLessThan(report.range(of: "sequence 73")!.lowerBound, report.range(of: "sequence 200")!.lowerBound)
        XCTAssertTrue(report.contains("do not prove physical Sleep/Wake"))
        XCTAssertFalse(report.contains("sequence 72 ·"))
    }
    func testFreeFormErrorsAndMalformedReadingsNeverEnterRecords() {
        var activity = UserSessionActivity(), status = sample()
        status.blockReason = "secret account endpoint"; status.error = "password secret token"
        status.thermal = -1; status.batteryPercent = 999
        status.manualBatteryRemaining = .infinity; status.batteryRemaining = .nan
        status.until = Date(timeIntervalSince1970: .infinity)
        activity.setRecording(true, now: 10)
        activity.observe(status, now: 11)
        let report = activity.report(since: .distantPast)
        for secret in ["secret", "password", "account", "endpoint", "token", "nan", "inf"] { XCTAssertFalse(report.contains(secret)) }
        XCTAssertTrue(report.contains("block=other")); XCTAssertTrue(report.contains("failed=true"))
        XCTAssertTrue(report.contains("batteryPercent=unknown")); XCTAssertTrue(report.contains("manualRemaining=unknown"))
        XCTAssertTrue(activity.observe(status, now: .nan).isEmpty)
    }
    func testReportRangeAndNewLifetimeNeverRevivePreviousRecording() {
        var activity = UserSessionActivity()
        activity.mark(date: Date(timeIntervalSince1970: 100))
        activity.setRecording(true, minutes: 15, now: 10, date: Date(timeIntervalSince1970: 200))
        activity.mark(date: Date(timeIntervalSince1970: 300))
        let report = activity.report(since: Date(timeIntervalSince1970: 250))
        XCTAssertTrue(report.contains("sequence 3")); XCTAssertFalse(report.contains("sequence 1"))
        let restarted = UserSessionActivity()
        XCTAssertTrue(restarted.entries.isEmpty); XCTAssertFalse(restarted.isRecording(now: 11))
        XCTAssertNil(restarted.recordingUntil)
    }
    func testReadableHistoryShowsEndReasonAndRemainingAutomaticScopeWithoutRawErrors() {
        let old = Localization.current; defer { Localization.current = old }
        Localization.current = .english
        var activity = UserSessionActivity(), status = sample()
        activity.observe(status, now: 100)
        status.manualActive = false; status.manualEndReason = .time; status.automaticActive = true
        activity.observe(status, now: 101)
        let ending = activity.recent()[0]
        XCTAssertEqual(ending.title, "Manual work ended")
        XCTAssertTrue(ending.detail!.contains("Manual duration ended"))
        XCTAssertTrue(ending.detail!.contains("Automatic active"))
        status.blockReason = "thermal"; status.holding = false; status.automaticActive = false
        status.error = "secret password error"
        activity.observe(status, now: 102)
        let protected = activity.recent()[0]
        XCTAssertEqual(protected.title, "Work stopped for protection")
        XCTAssertTrue(protected.detail!.contains("Request or observation needs review"))
        XCTAssertFalse(protected.detail!.contains("secret")); XCTAssertFalse(protected.detail!.contains("asleep"))
    }
}
