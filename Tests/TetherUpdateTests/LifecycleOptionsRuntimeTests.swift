import XCTest
import TetherCore
@testable import Tether

final class LifecycleOptionsRuntimeTests: XCTestCase {
    func testInitialObservationAndNewOwnerNeverReplayTheCurrentWork() {
        let scope = V4Scope(bootID: "boot", ownerID: "owner", powerGeneration: 0)
        let active = LifecycleOptionsObservation(scope: scope, manualID: UUID(), automatic: true, protection: false)
        XCTAssertTrue(LifecycleOptionsObservation.changes(from: nil, to: active).isEmpty)
        var newOwner = active; newOwner.scope.ownerID = "new-owner"
        XCTAssertTrue(LifecycleOptionsObservation.changes(from: active, to: newOwner).isEmpty)
    }
    func testPowerTransitionUsesTheFreshScopeButStillReportsTheConfirmedEnd() {
        let scope = V4Scope(bootID: "boot", ownerID: "owner", powerGeneration: 0)
        let old = LifecycleOptionsObservation(scope: scope, manualID: UUID(), automatic: true, protection: false)
        var next = old; next.scope.powerGeneration += 1; next.manualID = nil; next.automatic = false; next.protection = true
        XCTAssertEqual(LifecycleOptionsObservation.changes(from: old, to: next), [.sessionEnded, .triggerEnded, .protectionStopped])
    }
    func testProductionRejectsEveryChildProcessActionBeforeLaunchingIt() async {
        let backend = AppLifecycleHookBackend()
        for action in [LifecycleHookAction.shell(command: "this-must-never-run"), .shortcut(name: "this-must-never-run")] {
            let result = await backend.execute(action, until: ContinuousTime.now + 1)
            XCTAssertEqual(result.status, .invalid)
        }
    }
    func testUnsupportedActionsAndEventsCannotEnterAppSettings() async {
        await MainActor.run {
            let valid = LifecycleHookRule(enabled: true, events: [.sessionEnded], action: .webhook(url: URL(string: "https://example.invalid/hook")!))
            XCTAssertTrue(LifecycleOptionsRuntime.supports(.init(enabled: true, rules: [valid])))
            var shell = valid; shell.action = .shell(command: "ignored")
            XCTAssertFalse(LifecycleOptionsRuntime.supports(.init(enabled: true, rules: [shell])))
            var unsupported = valid; unsupported.events = [.activityStarted]
            XCTAssertFalse(LifecycleOptionsRuntime.supports(.init(enabled: true, rules: [unsupported])))
        }
    }
}

private actor RuntimeHookRecorder: LifecycleHookBackend {
    private(set) var count = 0
    private(set) var actions: [LifecycleHookAction] = []
    func execute(_ action: LifecycleHookAction, until deadline: Double) async -> LifecycleHookResult {
        count += 1; actions.append(action)
        return .init(.succeeded)
    }
}

extension LifecycleOptionsRuntimeTests {
    @MainActor
    func testAllStopConsumesTheEndEventAndResumingDoesNotReplayIt() async throws {
        let scope = V4Scope(bootID: "boot", ownerID: "owner", powerGeneration: 0)
        let backend = RuntimeHookRecorder()
        let runtime = LifecycleOptionsRuntime(scope: scope, defaults: nil, backend: backend)
        let rule = LifecycleHookRule(enabled: true, events: [.sessionStarted, .sessionEnded],
            action: .webhook(url: URL(string: "https://example.invalid/hook")!))
        XCTAssertTrue(runtime.save(.init(enabled: true, rules: [rule]), expectedRevision: 0))
        let active = LifecycleOptionsObservation(scope: scope, manualID: UUID(), automatic: false, protection: false)
        runtime.observe(active, fresh: true)
        var stopped = active; stopped.manualID = nil
        runtime.observe(stopped, fresh: true, paused: true)
        runtime.observe(stopped, fresh: true)
        for _ in 0..<30 { await Task.yield() }
        let before = await backend.count
        XCTAssertEqual(before, 0, "All Stop must not start an end action or replay it on resume")
        runtime.observe(active, fresh: true)
        for _ in 0..<1000 { if await backend.count == 1 { break }; await Task.yield() }
        let after = await backend.count
        XCTAssertEqual(after, 1, "A later explicit start remains eligible")
        let drained = await runtime.shutdown()
        XCTAssertTrue(drained)
    }
}

extension LifecycleOptionsRuntimeTests {
    @MainActor
    func testUnconfirmedExecutionNeitherEndsNorRestartsTheSameTimer() async {
        let scope = V4Scope(bootID: "boot", ownerID: "owner", powerGeneration: 0)
        let backend = RuntimeHookRecorder()
        let runtime = LifecycleOptionsRuntime(scope: scope, defaults: nil, backend: backend)
        let rule = LifecycleHookRule(enabled: true, events: [.sessionStarted, .sessionEnded],
            action: .webhook(url: URL(string: "https://example.invalid/hook")!))
        XCTAssertTrue(runtime.save(.init(enabled: true, rules: [rule]), expectedRevision: 0))
        var state = LifecycleOptionsObservation(scope: scope, manualID: nil, automatic: false, protection: false)
        runtime.observe(state, fresh: true)
        state.manualID = UUID()
        runtime.observe(state, fresh: true, executionConfirmed: false)
        for _ in 0..<30 { await Task.yield() }
        let pending = await backend.count
        XCTAssertEqual(pending, 0)
        runtime.observe(state, fresh: true)
        for _ in 0..<1000 { if await backend.count == 1 { break }; await Task.yield() }
        runtime.observe(state, fresh: true, executionConfirmed: false)
        runtime.observe(state, fresh: true)
        for _ in 0..<30 { await Task.yield() }
        let confirmed = await backend.count
        XCTAssertEqual(confirmed, 1, "A brief unverified executor must not invent an end/start pair")
        _ = await runtime.shutdown()
    }
}

extension LifecycleOptionsRuntimeTests {
    @MainActor
    func testUnplugCancelsAQueuedOldStartAndKeepsOnlyTheNewScopeEnd() async {
        let scope = V4Scope(bootID: "boot", ownerID: "owner", powerGeneration: 0)
        let backend = RuntimeHookRecorder()
        let runtime = LifecycleOptionsRuntime(scope: scope, defaults: nil, backend: backend)
        let start = LifecycleHookAction.webhook(url: URL(string: "https://example.invalid/start")!)
        let end = LifecycleHookAction.webhook(url: URL(string: "https://example.invalid/end")!)
        let settings = LifecycleHooksSettings(enabled: true, rules: [
            .init(enabled: true, events: [.sessionStarted], action: start),
            .init(enabled: true, events: [.sessionEnded], action: end)])
        XCTAssertTrue(runtime.save(settings, expectedRevision: 0))
        var state = LifecycleOptionsObservation(scope: scope, manualID: nil, automatic: false, protection: false)
        runtime.observe(state, fresh: true)
        state.manualID = UUID(); runtime.observe(state, fresh: true)
        state.scope.powerGeneration += 1; state.manualID = nil
        runtime.observe(state, fresh: true)
        for _ in 0..<1000 { if await backend.count == 1 { break }; await Task.yield() }
        let actions = await backend.actions
        XCTAssertEqual(actions, [end], "An old queued start must not escape after power-generation changes")
        _ = await runtime.shutdown()
    }
}
