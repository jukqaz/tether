import XCTest
@testable import TetherCore

final class NotificationOptionsTests: XCTestCase {
    func testSelectedWarningTimeIsUsedAndChangingItNeverReplaysAnAttempt() {
        var engine = V4ExpiryNoticeEngine()
        let manual = V4Fixture.manual(deadline: 1000), context = V4Fixture.context()
        XCTAssertEqual(engine.update(manual: manual, context: context, now: 100, enabled: true,
            notificationsAuthorized: true, warningMinutes: 2).nextEvaluation, 880)
        let warning = engine.update(manual: manual, context: context, now: 880, enabled: true,
            notificationsAuthorized: true, warningMinutes: 2).submit
        XCTAssertEqual(warning?.warningMinutes, 2)
        XCTAssertNil(engine.update(manual: manual, context: context, now: 881, enabled: true,
            notificationsAuthorized: true, warningMinutes: 1).submit)
        XCTAssertNil(engine.update(manual: manual, context: context, now: 940, enabled: true,
            notificationsAuthorized: true, warningMinutes: 1).submit)
    }
    func testChangingAnUnsentWarningRearmsOnlyInTheFuture() {
        var engine = V4ExpiryNoticeEngine()
        let manual = V4Fixture.manual(deadline: 1000), context = V4Fixture.context()
        _ = engine.update(manual: manual, context: context, now: 100, enabled: true, notificationsAuthorized: true)
        let changed = engine.update(manual: manual, context: context, now: 200, enabled: true,
            notificationsAuthorized: true, warningMinutes: 1)
        XCTAssertFalse(changed.invalidate.isEmpty)
        XCTAssertEqual(changed.nextEvaluation, 940)
        XCTAssertNil(engine.update(manual: manual, context: context, now: 941, enabled: true,
            notificationsAuthorized: true, warningMinutes: 0).submit)
    }
    func testLegacySettingsDefaultsAndSelectiveNotificationTransfer() throws {
        let legacy = try JSONDecoder().decode(V4Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.expiryNoticeMinutes, 5)
        XCTAssertFalse(legacy.notificationSound)
        var source = V4SettingsDocument(generation: 0, settings: legacy, preferences: .init())
        let current = source
        source.settings.expiryNoticeMinutes = 10
        source.settings.notificationSound = true
        source.settings.notifyTaskEnd = true
        XCTAssertEqual(V4SettingsTransfer.changedParts(from: current, to: source), [.notifications])
        let preview = V4SettingsTransfer.preview(source: source, current: current,
            selected: [.notifications], activeManual: true)
        XCTAssertEqual(preview.candidate.settings.expiryNoticeMinutes, 10)
        XCTAssertTrue(preview.candidate.settings.notificationSound)
        XCTAssertFalse(preview.candidate.settings.notifyManualExpiry)
    }
}
