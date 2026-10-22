import XCTest
@testable import TetherCore

final class V4WorkEventsTests: XCTestCase {
    func event(_ job: UUID, _ sequence: UInt64, _ kind: V4WorkEventKind, scope: V4Scope = V4Fixture.scope) -> V4WorkEvent {
        .init(jobID: job, eventID: UUID(), sequence: sequence, scope: scope, producerID: "build", kind: kind)
    }
    func testDetachConsumesJobAndReconnectDoesNotReviveIt() {
        var store = V4WorkEventStore(); let job = UUID()
        XCTAssertEqual(store.apply(event(job, 0, .start), context: V4Fixture.context(), now: 0).disposition, .accepted)
        store.reconcile(context: V4Fixture.context(.battery), now: 1)
        XCTAssertEqual(store.records[job]?.state, .revoked)
        XCTAssertEqual(store.apply(event(job, 1, .working), context: V4Fixture.context(), now: 2).disposition, .rejected)
    }
    func testHeartbeatRetryIsIdempotentAndNeverRevivesExpiredJob() {
        var store = V4WorkEventStore(); let job = UUID(); let start = event(job, 0, .start)
        _ = store.apply(start, context: V4Fixture.context(), now: 0)
        XCTAssertEqual(store.apply(start, context: V4Fixture.context(), now: 100).disposition, .alreadyProcessed)
        XCTAssertEqual(store.records[job]?.updatedAt, 0)
        XCTAssertEqual(store.apply(start, context: V4Fixture.context(), now: 121).record?.state, .expired)
    }
    func testWaitingHeartbeatCannotResetFiveMinuteResponseDeadline() {
        var store = V4WorkEventStore(); let job = UUID()
        _ = store.apply(event(job, 0, .start), context: V4Fixture.context(), now: 0)
        _ = store.apply(event(job, 1, .waiting), context: V4Fixture.context(), now: 1)
        for sequence in 2...10 { _ = store.apply(event(job, UInt64(sequence), .heartbeat), context: V4Fixture.context(), now: Double(sequence * 30)) }
        store.reconcile(context: V4Fixture.context(), now: 301)
        XCTAssertEqual(store.records[job]?.state, .expired)
    }
    func testNormalACHeartbeatHasNoArbitraryTotalLifetime() {
        var store = V4WorkEventStore(); let job = UUID()
        _ = store.apply(event(job, 0, .start), context: V4Fixture.context(), now: 0)
        for sequence in 1...1000 { _ = store.apply(event(job, UInt64(sequence), .heartbeat), context: V4Fixture.context(), now: Double(sequence * 30)) }
        XCTAssertEqual(store.records[job]?.state, .working)
    }
    func testStaleSequenceAndChangedProducerAreRejected() {
        var store = V4WorkEventStore(); let job = UUID()
        _ = store.apply(event(job, 3, .start), context: V4Fixture.context(), now: 0)
        XCTAssertEqual(store.apply(event(job, 2, .working), context: V4Fixture.context(), now: 1).disposition, .rejected)
        var other = event(job, 4, .working); other.producerID = "other"
        XCTAssertEqual(store.apply(other, context: V4Fixture.context(), now: 1).disposition, .rejected)
    }
    func testChangedReplayAndDeadlineCannotMutateApprovedJob() {
        var store = V4WorkEventStore(); let job = UUID()
        var start = event(job, 0, .start); start.fixedDeadline = 100
        _ = store.apply(start, context: V4Fixture.context(), now: 0)
        var altered = start; altered.kind = .idle
        XCTAssertEqual(store.apply(altered, context: V4Fixture.context(), now: 1).disposition, .rejected)
        var extensionEvent = event(job, 1, .heartbeat); extensionEvent.fixedDeadline = 1000
        XCTAssertEqual(store.apply(extensionEvent, context: V4Fixture.context(), now: 1).disposition, .rejected)
        XCTAssertEqual(store.apply(start, context: V4Fixture.context(), now: 101).disposition, .alreadyProcessed)
        XCTAssertEqual(store.records[job]?.state, .expired)
    }
    func testTerminalExternalPIDHasNoExitStatusAndTombstonesAreBounded() {
        var store = V4WorkEventStore(maximumRecords: 1); let job = UUID()
        var start = event(job, 0, .start); start.evidence = .externalPID
        _ = store.apply(start, context: V4Fixture.context(), now: 0)
        var end = event(job, 1, .finished); end.evidence = .externalPID; end.exitCode = 0
        XCTAssertNil(store.apply(end, context: V4Fixture.context(), now: 1).record?.exitCode)
        XCTAssertEqual(store.apply(event(UUID(), 0, .start), context: V4Fixture.context(), now: 2).disposition, .limited)
    }
    func testPIDReuseIsNotTheOriginalTask() {
        let identity = V4ProcessIdentity(pid: 42, startIdentity: 100, executableIdentity: "/bin/task")
        let binding = V4PIDBinding(identity: identity, scope: V4Fixture.scope, fixedDeadline: nil)
        var replacement = identity; replacement.startIdentity = 101
        XCTAssertEqual(binding.evaluate(presence: .alive, observed: replacement, observedUntil: 200, context: V4Fixture.context(), now: 100), .identityChanged)
        XCTAssertEqual(binding.evaluate(presence: .unknown, observed: nil, observedUntil: 200, context: V4Fixture.context(), now: 100), .observationUnavailable)
    }
    func testPartialSilenceAndDisappearanceAreNotSuccess() {
        var tracker = V4DownloadTracker()
        func sample(_ names: [String], _ progress: Double?, _ now: Double) -> V4DownloadSample {
            .init(scope: V4Fixture.scope, partialNames: names, lastProgressAt: progress, observedAt: now, validUntil: now + 5)
        }
        XCTAssertEqual(tracker.evaluate(sample(["file.part"], 0, 0), context: V4Fixture.context(), now: 0), .satisfied)
        XCTAssertEqual(tracker.evaluate(sample([], nil, 1), context: V4Fixture.context(), now: 1), .satisfied)
        XCTAssertEqual(tracker.evaluate(sample([], nil, 31), context: V4Fixture.context(), now: 31), .notSatisfied)
        XCTAssertEqual(tracker.evaluate(sample(["file.part"], 0, 301), context: V4Fixture.context(), now: 301), .unknown)
    }
}
