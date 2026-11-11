import XCTest
@testable import TetherCore

final class V4UpdateRehearsalTests: XCTestCase {
    func snapshot(_ work: [V4UpdateWork] = [], verified: Bool = true) -> V4UpdateSnapshot {
        .init(context: V4Fixture.context(), identity: .init(version: "2", packageIdentity: "package", channel: "stable", settingsGeneration: 1),
              work: work, packageValidated: verified, compatible: true)
    }
    func testAuthenticationCanWaitBeforeAnyPackageIsPreparedAndCancelDropsAuthority() {
        var engine = V4UpdateWaitEngine(), s = snapshot(verified: false)
        s.authenticationRequired = true
        XCTAssertEqual(engine.reserve(id: UUID(), snapshot: s, now: 0).state, .authenticationRequired)
        XCTAssertFalse(s.packageValidated)
        engine.cancel(); XCTAssertNil(engine.reservationID); XCTAssertTrue(engine.acceptsNewWork)
    }
    func testFollowOSChoiceRehearsalNeverInventsClosedUnplugSleepRequest() {
        var context = V4Fixture.context(); context.lidClosed = true
        let plan = V4RehearsalEngine.evaluate(settings: .init(), context: context, observations: [], capabilities: [],
            manual: V4Fixture.manual(), event: .disconnect, now: 100, wallDate: Date(), calendar: V4Fixture.calendar,
            closedLidAvailable: true, disconnectAction: .followOS)
        XCTAssertFalse(plan.general); XCTAssertEqual(plan.sleep, .notRequested)
        var settings = V4Settings(); settings.nextManualOptions.releaseDisplayAfterIdle = 1
        XCTAssertTrue(V4RuleEngine.validate(settings).contains("invalid-manual-display-idle"))
    }
    func testReservationAllowsDownloadVerificationAndIgnoresSimpleAC() {
        var engine = V4UpdateWaitEngine()
        var s = snapshot([.init(id: UUID(), kind: .simpleAutomatic, state: .active)], verified: false)
        XCTAssertEqual(engine.reserve(id: UUID(), snapshot: s, now: 0).state, .waiting)
        s.packageValidated = true
        XCTAssertEqual(engine.evaluate(snapshot: s, now: 1).state, .ready)
    }
    func testMissingOrExpiredTaskIsNotCompletion() {
        let task = V4UpdateWork(id: UUID(), kind: .taskEvent, state: .active)
        for state in [V4UpdateWorkState.observationExpired, .safetyConsumed] {
            var engine = V4UpdateWaitEngine(); _ = engine.reserve(id: UUID(), snapshot: snapshot([task]), now: 0)
            var ended = task; ended.state = state
            XCTAssertEqual(engine.evaluate(snapshot: snapshot([ended]), now: 1).state, .confirmationRequired)
        }
        var engine = V4UpdateWaitEngine(); _ = engine.reserve(id: UUID(), snapshot: snapshot([task]), now: 0)
        XCTAssertEqual(engine.evaluate(snapshot: snapshot(), now: 1).state, .confirmationRequired)
    }
    func testNormalEndBecomesReadyAndCommittingNeverReopensForWork() {
        var task = V4UpdateWork(id: UUID(), kind: .timedManual, state: .active)
        var engine = V4UpdateWaitEngine(); _ = engine.reserve(id: UUID(), snapshot: snapshot([task]), now: 0)
        task.state = .completed
        XCTAssertEqual(engine.beginReplacement(snapshot: snapshot([task]), now: 1).state, .committing)
        XCTAssertEqual(engine.evaluate(snapshot: snapshot([task]), now: 2).state, .committing)
        XCTAssertFalse(engine.acceptsNewWork)
        XCTAssertEqual(engine.finalCheck(snapshot: snapshot([task]), now: 3).state, .committing)
    }
    func testUnlinkedUnlimitedAndClosedLidNeverAutoInstall() {
        var engine = V4UpdateWaitEngine()
        XCTAssertEqual(engine.reserve(id: UUID(), snapshot: snapshot([.init(id: UUID(), kind: .unlimitedManual, state: .active)]), now: 0).state, .confirmationRequired)
        var s = snapshot(); s.context.lidClosed = true
        XCTAssertEqual(engine.reserve(id: UUID(), snapshot: s, now: 0).state, .waiting)
        s.context.lidClosed = false; s.authenticationRequired = true
        XCTAssertEqual(engine.evaluate(snapshot: s, now: 1).state, .authenticationRequired)
    }
    func testReservationRetryCannotRenew24HourLifetimeOrChangeIdentity() {
        var engine = V4UpdateWaitEngine(); let id = UUID(); let s = snapshot()
        _ = engine.reserve(id: id, snapshot: s, now: 0)
        XCTAssertEqual(engine.reserve(id: id, snapshot: s, now: 86400).state, .expired)
        XCTAssertEqual(engine.expiresAt, 86400)
    }
    func plan(_ context: V4ExecutionContext, settings: V4Settings = .init(), manual: V4ManualSnapshot? = nil, event: V4RehearsalEvent = .none) -> V4RehearsalPlan {
        V4RehearsalEngine.evaluate(settings: settings, context: context, observations: [], capabilities: [], manual: manual,
            event: event, now: 100, wallDate: Date(timeIntervalSince1970: 0), calendar: V4Fixture.calendar, closedLidAvailable: true)
    }
    func testRehearsalDisconnectConsumesCopiesWithoutExecutingEffects() {
        var context = V4Fixture.context(); context.lidClosed = true
        let manual = V4Fixture.manual(); let p = plan(context, manual: manual, event: .disconnect)
        XCTAssertFalse(p.general); XCTAssertFalse(p.manualRemains); XCTAssertEqual(p.consumedRequestIDs, [manual.requestID])
        XCTAssertEqual(p.sleep, .afterOwnRestoration); XCTAssertFalse(p.executesEffects)
        XCTAssertEqual(context.power, .ac); XCTAssertTrue(manual.isActive(at: 100))
    }
    func testRehearsalNoOwnRequestOrStaleFactsCannotInventSleep() {
        var c = V4Fixture.context(); c.lidClosed = true; c.automaticEnabled = false
        XCTAssertEqual(plan(c, event: .disconnect).sleep, .notRequested)
        c.validUntil = 100
        XCTAssertEqual(plan(c, manual: V4Fixture.manual(), event: .disconnect).sleep, .notRequested)
    }
    func testGlobalFeatureAllowIsCeilingAndRequestOptionsOR() {
        var c = V4Fixture.context(); c.automaticEnabled = false
        var manual = V4Fixture.manual(); manual.options = .init(display: true, closedLid: true)
        XCTAssertTrue(plan(c, manual: manual).display)
        c.allowDisplay = false; c.allowClosedLid = false
        let p = plan(c, manual: manual)
        XCTAssertTrue(p.general); XCTAssertFalse(p.display); XCTAssertFalse(p.closedLid)
    }
    func testBasicACRequestsGloballyAllowedDisplayAndLidInRehearsal() {
        let p = plan(V4Fixture.context())
        XCTAssertTrue(p.general); XCTAssertTrue(p.display); XCTAssertTrue(p.closedLid)
        var c = V4Fixture.context(); c.allowDisplay = false; c.allowClosedLid = false
        let disallowed = plan(c)
        XCTAssertTrue(disallowed.general); XCTAssertFalse(disallowed.display); XCTAssertFalse(disallowed.closedLid)
    }
}
