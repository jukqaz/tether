import XCTest
@testable import TetherCore

final class V4NotificationsTests: XCTestCase {
    func testNoticeCrossingIsOnceAndExtensionInvalidatesOldAction() {
        var engine = V4ExpiryNoticeEngine(); var manual = V4Fixture.manual()
        XCTAssertEqual(engine.update(manual: manual, context: V4Fixture.context(), now: 100, enabled: true, notificationsAuthorized: true).nextEvaluation, 700)
        let token = engine.update(manual: manual, context: V4Fixture.context(), now: 700, enabled: true, notificationsAuthorized: true).submit
        XCTAssertNotNil(token)
        manual.deadline = 1900; manual.revisionID = UUID()
        XCTAssertFalse(engine.update(manual: manual, context: V4Fixture.context(), now: 701, enabled: true, notificationsAuthorized: true).invalidate.isEmpty)
        XCTAssertNil(engine.update(manual: manual, context: V4Fixture.context(), now: 1600, enabled: true, notificationsAuthorized: true).submit)
        XCTAssertEqual(V4ExpiryNoticeEngine.validate(action: .extend15, token: token!, manual: manual, context: V4Fixture.context(), now: 701).disposition, .rejected)
    }
    func testLateEnableAndShortSessionNeverCatchUp() {
        for manual in [V4Fixture.manual(deadline: 300), V4Fixture.manual(deadline: 1000)] {
            var engine = V4ExpiryNoticeEngine()
            XCTAssertNil(engine.update(manual: manual, context: V4Fixture.context(), now: 800, enabled: true, notificationsAuthorized: true).submit)
        }
    }
    func testExtensionBeforeAttemptMovesNoticeDeadline() {
        var engine = V4ExpiryNoticeEngine(); var manual = V4Fixture.manual()
        _ = engine.update(manual: manual, context: V4Fixture.context(), now: 100, enabled: true, notificationsAuthorized: true)
        manual.deadline = 1900; manual.revisionID = UUID()
        XCTAssertEqual(engine.update(manual: manual, context: V4Fixture.context(), now: 200, enabled: true, notificationsAuthorized: true).nextEvaluation, 1600)
        XCTAssertNil(engine.update(manual: manual, context: V4Fixture.context(), now: 700, enabled: true, notificationsAuthorized: true).submit)
        XCTAssertNotNil(engine.update(manual: manual, context: V4Fixture.context(), now: 1600, enabled: true, notificationsAuthorized: true).submit)
    }
    func testBatteryFullExtensionUnavailableEvenWhenUIHintIsTrue() {
        var manual = V4Fixture.manual(deadline: 6500); manual.batteryStartedAt = 0
        var engine = V4ExpiryNoticeEngine()
        _ = engine.update(manual: manual, context: V4Fixture.context(.battery), now: 100, enabled: true, notificationsAuthorized: true)
        let token = engine.update(manual: manual, context: V4Fixture.context(.battery), now: 6200, enabled: true, notificationsAuthorized: true).submit!
        XCTAssertFalse(token.mayExtend15)
        XCTAssertEqual(V4ExpiryNoticeEngine.validate(action: .extend15, token: token, manual: manual, context: V4Fixture.context(.battery), now: 6201).disposition, .rejected)
        XCTAssertEqual(V4ExpiryNoticeEngine.validate(action: .checkDeadline, token: token, manual: manual, context: V4Fixture.context(.battery), now: 6201).intent, .showDeadline)
    }
    func testLatePermissionGrantDoesNotRetryNotice() {
        var engine = V4ExpiryNoticeEngine(); let manual = V4Fixture.manual()
        _ = engine.update(manual: manual, context: V4Fixture.context(), now: 100, enabled: true, notificationsAuthorized: false)
        XCTAssertNil(engine.update(manual: manual, context: V4Fixture.context(), now: 700, enabled: true, notificationsAuthorized: false).submit)
        XCTAssertNil(engine.update(manual: manual, context: V4Fixture.context(), now: 701, enabled: true, notificationsAuthorized: true).submit)
    }
    func testEndOptionsAreIndependentAndExternalExitIsNotSuccess() {
        var settings = V4Settings(); settings.notifyTaskEnd = true
        func notice(_ kind: V4CompletionKind) -> V4CompletionNotice? {
            V4CompletionNotificationPolicy.notice(eventID: UUID(), kind: kind, exitCode: 0, occurredAt: 0, validUntil: 200,
                now: 100, settings: settings, notificationsAuthorized: true, otherTetherWorkContinues: true)
        }
        XCTAssertNil(notice(.manualExpired)); XCTAssertNil(notice(.protection))
        XCTAssertNil(notice(.externalPIDEnded)?.exitCode)
        XCTAssertEqual(notice(.ownedCommandEnded)?.exitCode, 0)
    }
}
