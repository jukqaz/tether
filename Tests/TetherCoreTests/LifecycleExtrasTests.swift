import Foundation
import XCTest
@testable import TetherCore

private final class ExtrasClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double
    init(_ time: Double) { self.time = time }
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return time }
    func set(_ time: Double) { lock.lock(); self.time = time; lock.unlock() }
}

private actor ExtrasHookBackend: LifecycleHookBackend {
    var calls: [(LifecycleHookAction, Double)] = []
    var result = LifecycleHookResult(.succeeded)
    var hold = false
    var pending: CheckedContinuation<LifecycleHookResult, Never>?
    var afterExecution: (@Sendable () -> Void)?
    func configure(result: LifecycleHookResult = .init(.succeeded), hold: Bool = false, after: (@Sendable () -> Void)? = nil) {
        self.result = result; self.hold = hold; afterExecution = after
    }
    func execute(_ action: LifecycleHookAction, until deadline: Double) async -> LifecycleHookResult {
        calls.append((action, deadline))
        let value: LifecycleHookResult
        if hold { value = await withCheckedContinuation { pending = $0 } } else { value = result }
        afterExecution?()
        return Task.isCancelled ? .init(.cancelled) : value
    }
    func release() { pending?.resume(returning: result); pending = nil }
    var count: Int { calls.count }
    var deadlines: [Double] { calls.map(\.1) }
}

final class LifecycleExtrasTests: XCTestCase {
    private let scope = V4Scope(bootID: "boot", ownerID: "owner", powerGeneration: 1)
    private func event(_ kind: LifecycleHookKind = .sessionStarted, at: Double = 100, deadline: Double = 120) -> LifecycleHookEvent {
        .init(scope: scope, kind: kind, observedAt: at, deadline: deadline)
    }
    private func settings(timeout: Double = 10) -> LifecycleHooksSettings {
        .init(enabled: true, rules: [.init(enabled: true, events: [.sessionStarted], action: .shell(command: "stored user command"), timeout: timeout)])
    }
    func testSettingsAreVersionedOffByDefaultAndImportedRulesCannotExecute() throws {
        XCTAssertFalse(LifecycleHooksSettings().enabled)
        let original = settings(), imported = original.normalizedForImport()
        XCTAssertFalse(imported.enabled); XCTAssertFalse(imported.rules[0].enabled)
        XCTAssertEqual(imported.rules[0].action, original.rules[0].action)
        XCTAssertEqual(try JSONDecoder().decode(LifecycleHooksSettings.self, from: JSONEncoder().encode(imported)), imported)
        var future = original; future.version = 99
        XCTAssertFalse(future.isValid)
    }
    func testHTTPAndCommandsValidateBeforeAnyBackendWork() {
        for value in ["http://example.com", "https://user:secret@example.com", "https://example.com/#fragment", "file:///tmp/hook"] {
            XCTAssertFalse(LifecycleHookAction.webhook(url: URL(string: value)!).isValid)
        }
        XCTAssertTrue(LifecycleHookAction.webhook(url: URL(string: "https://example.com/hook")!).isValid)
        XCTAssertFalse(LifecycleHookAction.shell(command: " ").isValid)
        XCTAssertFalse(LifecycleHookAction.shortcut(name: "\0").isValid)
        XCTAssertFalse(settings(timeout: .infinity).isValid)
        XCTAssertFalse(settings(timeout: 30.1).isValid)
    }
    func testFreshEventRunsOnceAndImportOffDoesNotReplayWhenEnabled() async {
        let clock = ExtrasClock(100), backend = ExtrasHookBackend()
        let driver = LifecycleHookDriver(scope: scope, backend: backend, clock: { clock.now() })
        let first = event()
        let disabled = await driver.handle(first, settings: settings().normalizedForImport())
        XCTAssertEqual(disabled.first?.result.status, .disabled)
        let replay = await driver.handle(first, settings: settings())
        XCTAssertEqual(replay.first?.result.status, .alreadyHandled)
        let second = event()
        let result = await driver.handle(second, settings: settings())
        XCTAssertEqual(result.first?.result.status, .succeeded)
        let duplicate = await driver.handle(second, settings: settings())
        XCTAssertEqual(duplicate.first?.result.status, .alreadyHandled)
        let count = await backend.count
        XCTAssertEqual(count, 1)
    }
    func testAbsoluteDeadlineIsClampedAndExpiredFollowingActionNeverStarts() async {
        let clock = ExtrasClock(100), backend = ExtrasHookBackend()
        await backend.configure(after: { clock.set(116) })
        let driver = LifecycleHookDriver(scope: scope, backend: backend, clock: { clock.now() })
        var config = settings(timeout: 30)
        config.rules.append(.init(enabled: true, events: [.sessionStarted], action: .shortcut(name: "Second")))
        let results = await driver.handle(event(deadline: 115), settings: config)
        XCTAssertEqual(results.map(\.result.status), [.succeeded, .expired])
        let deadlines = await backend.deadlines
        XCTAssertEqual(deadlines, [115])
    }
    func testExpiredFutureAndWrongScopeEventsHaveNoEffects() async {
        let backend = ExtrasHookBackend(), driver = LifecycleHookDriver(scope: scope, backend: backend, clock: { 100 })
        let expired = await driver.handle(event(at: 70, deadline: 100), settings: settings())
        XCTAssertEqual(expired.first?.result.status, .expired)
        let future = await driver.handle(event(at: 101, deadline: 110), settings: settings())
        XCTAssertEqual(future.first?.result.status, .invalid)
        var other = event(); other.scope.ownerID = "other"
        let wrong = await driver.handle(other, settings: settings())
        XCTAssertEqual(wrong.first?.result.status, .wrongScope)
        let count = await backend.count
        XCTAssertEqual(count, 0)
    }
    func testConcurrencyIsBoundedBusyEventIsNotQueuedAndCancellationReachesBackend() async {
        let backend = ExtrasHookBackend()
        await backend.configure(hold: true)
        let driver = LifecycleHookDriver(scope: scope, backend: backend, clock: { 100 })
        let first = event(), second = event(), config = settings()
        let operation = Task { await driver.handle(first, settings: config) }
        for _ in 0..<1000 { if await backend.count == 1 { break }; await Task.yield() }
        let busy = await driver.handle(second, settings: config)
        XCTAssertEqual(busy.first?.result.status, .busy)
        await driver.cancelAll(); await backend.release()
        let result = await operation.value
        XCTAssertEqual(result.first?.result.status, .cancelled)
        let replay = await driver.handle(second, settings: config)
        XCTAssertEqual(replay.first?.result.status, .alreadyHandled)
        let count = await backend.count
        XCTAssertEqual(count, 1)
    }
    func testCancellingTheCallerPropagatesToTheUnstructuredBackendTask() async {
        let backend = ExtrasHookBackend()
        await backend.configure(hold: true)
        let driver = LifecycleHookDriver(scope: scope, backend: backend, clock: { 100 })
        let input = event(), config = settings()
        let caller = Task { await driver.handle(input, settings: config) }
        for _ in 0..<1000 { if await backend.count == 1 { break }; await Task.yield() }
        caller.cancel()
        await backend.release()
        let result = await caller.value
        XCTAssertEqual(result.first?.result.status, .cancelled)
        let running = await driver.runningCount
        XCTAssertEqual(running, 0)
    }
    func testUnconfirmedProcessTerminationBlocksSubsequentExecutionWithoutRetry() async {
        let backend = ExtrasHookBackend()
        await backend.configure(result: .init(.terminationUnconfirmed, terminationConfirmed: false))
        let driver = LifecycleHookDriver(scope: scope, backend: backend, clock: { 100 })
        _ = await driver.handle(event(), settings: settings())
        let next = await driver.handle(event(), settings: settings())
        XCTAssertEqual(next.first?.result.status, .terminationUnconfirmed)
        let count = await backend.count
        XCTAssertEqual(count, 1)
        XCTAssertFalse(String(describing: next).contains("stored user command"))
    }
    func testDeduplicationProtectsLiveIDsAndPurgesExpiredEntriesForLongRunningACWork() async {
        let clock = ExtrasClock(100), backend = ExtrasHookBackend()
        let driver = LifecycleHookDriver(scope: scope, backend: backend, clock: { clock.now() })
        let config = LifecycleHooksSettings()
        let original = event()
        _ = await driver.handle(original, settings: config)
        for _ in 1..<512 { _ = await driver.handle(event(), settings: config) }
        let capped = await driver.handle(event(), settings: settings())
        XCTAssertEqual(capped.first?.result.status, .capacityReached)
        let duplicate = await driver.handle(original, settings: settings())
        XCTAssertEqual(duplicate.first?.result.status, .alreadyHandled)
        let count = await backend.count
        XCTAssertEqual(count, 0)
        clock.set(121)
        let next = await driver.handle(event(at: 121, deadline: 141), settings: settings())
        XCTAssertEqual(next.first?.result.status, .succeeded)
        let old = await driver.handle(original, settings: settings())
        XCTAssertEqual(old.first?.result.status, .expired)
        let after = await backend.count
        XCTAssertEqual(after, 1)
    }
}
