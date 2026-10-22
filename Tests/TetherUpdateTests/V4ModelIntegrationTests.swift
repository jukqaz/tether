import Foundation
import XCTest
@testable import Tether
import TetherCore

private final class V4MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func register(defaults: [String: Any]) { registered.merge(defaults) { _, new in new } }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
    override func synchronize() -> Bool { true }
    override func persistentDomain(forName name: String) -> [String: Any]? { values }
}
private final class V4AssertionFixture: IdleAssertionBackend {
    var ids: Set<UInt32> = []
    var creates = 0
    var failCreate = false
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        guard !failCreate else { return (-1, nil) }
        creates += 1; let id = UInt32(creates); ids.insert(id); return (0, id)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { ids.contains(id) ? 0 : -1 }
    func level(id: UInt32) -> Int? { ids.contains(id) ? 255 : 0 }
    func release(id: UInt32) -> Int32 { ids.remove(id); return 0 }
}

final class V4ModelIntegrationTests: XCTestCase {
    func testRepeatedProtectionReceiptDoesNotPublishOrRenewAgain() async throws {
        await MainActor.run {
            let (_, controller, system, _) = fixture(); defer { _ = controller.end() }
            let now = ContinuousTime.now
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now)
            controller.setAutomatic(true)
            var bridge = WorkSessionBridge(coordinated: true, automaticBudget: ProtectionState(), manualBudget: nil)
            bridge.lidProtection = WorkSessionProtectionLatch(bootID: "v4-fixture", reason: "thermal",
                observedAt: now, sessionID: controller.sessionID, sequence: 0)
            var publications = 0
            controller.onChange = { _ in publications += 1 }
            controller.acceptBridge(bridge, protection: nil, now: now + 1)
            XCTAssertFalse(controller.status.holding)
            let first = publications, creates = system.creates
            for _ in 0..<100 { controller.acceptBridge(bridge, protection: nil, now: now + 1) }
            XCTAssertGreaterThan(first, 0)
            XCTAssertEqual(publications, first, "Identical protection ACKs cannot drive another publish/IPC cycle")
            XCTAssertEqual(system.creates, creates)
            XCTAssertEqual(controller.settings.blockReason, "thermal")
        }
    }
    @MainActor private func fixture() -> (V4MemoryDefaults, UserSessionController, V4AssertionFixture, V4AssertionFixture) {
        let defaults = V4MemoryDefaults(), system = V4AssertionFixture(), display = V4AssertionFixture()
        let subject = UserSessionController(defaults: defaults, backend: system, displayBackend: display,
            guiProbe: nil, environmentProbe: nil, boot: "v4-fixture")
        return (defaults, subject, system, display)
    }
    func testInitialIndependentFourCombinationsDoNotStartManualWork() async {
        await MainActor.run {
            for automatic in [false, true] { for lid in [false, true] {
                let (_, controller, system, _) = fixture(); defer { _ = controller.end() }
                controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 90)
                XCTAssertTrue(controller.applyInitialChoices(automatic: automatic, allowClosedLid: lid))
                XCTAssertEqual(controller.settings.automaticEnabled, automatic)
                XCTAssertEqual(controller.settings.allowClosedLid, lid)
                XCTAssertFalse(controller.status.manualActive)
                XCTAssertEqual(controller.status.holding, automatic)
                XCTAssertEqual(system.creates, automatic ? 1 : 0)
            } }
        }
    }
    func testDisplayIdleReleasesOnlyItsRequestAndResumesOnFreshInput() async {
        await MainActor.run {
            let (_, controller, system, display) = fixture(); defer { _ = controller.end() }
            let now = ContinuousTime.now
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now)
            controller.setKeepDisplayAwake(true)
            var choices = controller.v4Settings
            choices.nextManualOptions.releaseDisplayAfterIdle = 300
            XCTAssertTrue(controller.setV4Settings(choices))
            controller.idleSecondsProbe = { 400 }
            XCTAssertTrue(controller.start(duration: 1800, now: now))
            XCTAssertTrue(controller.status.holding); XCTAssertEqual(controller.status.displayHolding, false)
            XCTAssertFalse(system.ids.isEmpty); XCTAssertTrue(display.ids.isEmpty)
            controller.idleSecondsProbe = { 0 }
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now + 1)
            XCTAssertEqual(controller.status.displayHolding, true)
            controller.idleSecondsProbe = { nil }
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now + 2)
            XCTAssertEqual(controller.status.displayHolding, true) // no invented permission to turn the screen off
        }
    }
    func testUnplugConsumesBatteryOriginAfterAnACVisit() async {
        await MainActor.run {
            let (_, controller, system, _) = fixture(); defer { _ = controller.end() }
            let now = ContinuousTime.now
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: now, batteryPercent: 90)
            XCTAssertTrue(controller.start(duration: 1800, now: now))
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now + 1, batteryPercent: 90)
            controller.update(power: .unknown, thermal: 0, fullWake: true, controllingUser: true, now: now + 2, batteryPercent: 90)
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: now + 3, batteryPercent: 90)
            XCTAssertFalse(controller.status.manualActive)
            // The unknown-power observation already consumed it as unavailable/protection;
            // the subsequent battery edge must not relabel or revive that request.
            XCTAssertEqual(controller.status.manualEndReason, .protection)
            XCTAssertTrue(system.ids.isEmpty)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now + 4, batteryPercent: 90)
            XCTAssertFalse(controller.status.manualActive)
        }
    }
    func testDisplayStartFailureRejectsOnlyTheNewManualRequest() async {
        await MainActor.run {
            let (_, controller, _, display) = fixture(); defer { _ = controller.end() }
            let now = ContinuousTime.now
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now)
            controller.setAutomatic(true)
            var settings = controller.v4Settings
            settings.automaticMode = .advanced
            let condition = V4Condition(id: UUID(), kind: .appRunning, target: "fixture")
            let id = UUID()
            settings.presets = [V4Preset(id: id, name: "Fixture", groups: [V4RuleGroup(id: UUID(), conditions: [condition])], options: .init())]
            settings.activePresetID = id
            controller.v4ConditionSource.queryOverride = { _, _ in (.satisfied, nil) }
            XCTAssertTrue(controller.setV4Settings(settings))
            controller.setKeepDisplayAwake(true)
            display.failCreate = true
            XCTAssertFalse(controller.start(duration: 900, now: now + 1))
            XCTAssertFalse(controller.status.manualActive)
            XCTAssertTrue(controller.status.automaticActive)
        }
    }
    func testBatteryExtensionAddsWholeIntervalsAndStopsAtFirstStartCap() async throws {
        try await MainActor.run {
            let (_, controller, _, _) = fixture(); defer { _ = controller.end() }
            let now = ContinuousTime.now
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: now, batteryPercent: 90)
            XCTAssertTrue(controller.start(duration: 1800, now: now))
            let id = controller.manualRequestID
            XCTAssertTrue(controller.extend(duration: 900, now: now + 1))
            XCTAssertEqual(controller.status.manualContinuousDeadline, now + 2700)
            XCTAssertEqual(controller.manualRequestID, id)
            XCTAssertFalse(controller.extend(duration: 420, now: now + 2))
            XCTAssertTrue(controller.extend(duration: 1800, now: now + 2))
            XCTAssertTrue(controller.extend(duration: 1800, now: now + 3))
            XCTAssertTrue(controller.extend(duration: 900, now: now + 4))
            XCTAssertEqual(try XCTUnwrap(controller.status.manualContinuousDeadline), now + 7200, accuracy: 0.001)
            XCTAssertFalse(controller.canExtendManual(by: 15, now: now + 5))
        }
    }
    func testInactiveNativeProvidersHaveNoQueriesOrRegistrations() async {
        await MainActor.run {
            let source = V4NativeObservations()
            var settings = V4Settings(); settings.automaticMode = .advanced
            let id = UUID()
            settings.presets = [V4Preset(id: id, name: "Fixture", groups: [V4RuleGroup(id: UUID(), conditions: [V4Condition(id: UUID(), kind: .calendar, target: "never-read")])])]
            settings.activePresetID = id
            source.queryOverride = { _, _ in XCTFail("Disabled provider queried"); return (.satisfied, nil) }
            source.configure(settings: settings, enabled: false, scope: V4Scope(bootID: "test", ownerID: "test", powerGeneration: 0), observing: false)
            source.refresh(force: true)
            XCTAssertTrue(source.queryCounts.isEmpty)
            source.stop()
        }
    }
    func testHistoryDoesNotRestoreManualRuntimeAndProtectsActiveManualGlobals() async throws {
        try await MainActor.run {
            let (defaults, controller, _, _) = fixture(); defer { _ = controller.end() }
            let now = ContinuousTime.now
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now)
            let model = AppModel(preview: true, capabilities: MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false),
                previewSession: controller, previewDefaults: defaults)
            model.setKeepDisplayAwake(true)
            let entry = try XCTUnwrap(model.v4HistoryItems.first)
            XCTAssertTrue(controller.start(duration: 900, now: now + 1))
            let request = controller.manualRequestID, deadline = controller.status.manualContinuousDeadline
            let preview = try XCTUnwrap(model.historyRestorePreview(id: entry.id))
            XCTAssertNotNil(preview.blockedReason)
            XCTAssertFalse(model.applyHistoryRestore(id: entry.id, generation: preview.generation, groups: ["globalFeatures"]))
            XCTAssertEqual(controller.manualRequestID, request)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
        }
    }
    func testManualUsesCapturedFeaturesDespiteNewDefaultsAndIndependentAutomaticFailures() async {
        await MainActor.run {
            let (defaults, controller, _, display) = fixture(); defer { _ = controller.end() }
            let now = ContinuousTime.now
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now)
            controller.setKeepDisplayAwake(true); controller.setAllowClosedLid(true)
            var choices = controller.v4Settings
            choices.nextManualOptions = .init(display: false, closedLid: false)
            XCTAssertTrue(controller.setV4Settings(choices))
            let model = AppModel(preview: true, capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: controller, previewDefaults: defaults)
            model.startManualSession(minutes: 30)
            XCTAssertTrue(controller.status.manualActive); XCTAssertFalse(model.manualFeaturesNeedHelper)
            choices.nextManualOptions = .init(display: true, closedLid: true)
            XCTAssertTrue(controller.setV4Settings(choices))
            display.failCreate = true
            controller.setAutomatic(true) // Its display request fails independently.
            XCTAssertNotNil(controller.status.displayError)
            XCTAssertFalse(model.manualFeaturesNeedHelper)
            XCTAssertTrue(model.extendCommonManualSession(minutes: 15))
            XCTAssertTrue(controller.status.manualActive)
        }
    }
    func testDecisionArchiveIsOptInForTheCoordinatorAndNeverRestoresLiveWork() async throws {
        try await MainActor.run {
            let (defaults, controller, _, _) = fixture()
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
            XCTAssertNil(defaults.data(forKey: "v4DecisionHistory"))
            controller.activityPersistenceEnabled = true
            XCTAssertTrue(controller.start(duration: 900))
            let data = try XCTUnwrap(defaults.data(forKey: "v4DecisionHistory"))
            XCTAssertFalse(try UserSessionActivity(archive: data).entries.isEmpty)
            XCTAssertTrue(controller.end())
            let restarted = UserSessionController(defaults: defaults, backend: V4AssertionFixture(), displayBackend: V4AssertionFixture(),
                guiProbe: nil, environmentProbe: nil, boot: "v4-fixture")
            defer { _ = restarted.end() }
            XCTAssertFalse(restarted.status.manualActive); XCTAssertFalse(restarted.status.holding)
            XCTAssertFalse(restarted.activity.entries.isEmpty); XCTAssertFalse(restarted.activity.isRecording())
        }
    }
    func testFailedNewSettingsAndInitialChoicesPreserveThePriorSavedIntent() async {
        await MainActor.run {
            for initial in [false, true] {
                let (_, controller, _, _) = fixture(); defer { _ = controller.end() }
                controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                let original = controller.settings
                controller.persistenceProbe = { false }
                if initial { XCTAssertFalse(controller.applyInitialChoices(automatic: true, allowClosedLid: true)) }
                else {
                    var next = controller.v4Settings; next.notifyManualExpiry = true
                    XCTAssertFalse(controller.setV4Settings(next))
                }
                XCTAssertEqual(controller.settings, original)
                XCTAssertNotNil(controller.status.error); XCTAssertFalse(controller.status.holding)
            }
        }
    }
    func testExplicitPresetAppliesOnlyNextManualDefaultsAndPreservesAnActiveRequest() async throws {
        try await MainActor.run {
            let (defaults, controller, _, _) = fixture(); defer { _ = controller.end() }
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
            let model = AppModel(preview: true, capabilities: MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false),
                previewSession: controller, previewDefaults: defaults)
            model.startManualSession(minutes: 30)
            let request = controller.manualRequestID, deadline = controller.status.manualContinuousDeadline
            var next = model.v4Settings; next.automaticMode = .advanced
            let preset = V4Preset(id: UUID(), name: "Next only", groups: [], options: .init(display: false, closedLid: false), nextManualMinutes: 60)
            next.presets = [preset]; next.activePresetID = preset.id
            XCTAssertTrue(model.saveV4AutomaticRules(next))
            XCTAssertEqual(controller.settings.lastManualDurationSeconds, 3600)
            XCTAssertEqual(controller.v4Settings.nextManualOptions, preset.options)
            XCTAssertEqual(controller.manualRequestID, request); XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
        }
    }
    func testTentativeExtensionPastTheOldDeadlineIsConsumedOnFailedApproval() async throws {
        try await MainActor.run {
            let (_, controller, _, _) = fixture(); defer { _ = controller.end() }
            let now = ContinuousTime.now
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now)
            XCTAssertTrue(controller.start(duration: 10, now: now))
            XCTAssertTrue(controller.prepareManualExtension(minutes: 15, now: now + 8))
            XCTAssertTrue(controller.commitManualExtension(now: now + 8, requiresHelper: false))
            controller.cancelManualExtension(now: now + 10)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now + 10)
            XCTAssertFalse(controller.status.manualActive); XCTAssertFalse(controller.status.holding)
            XCTAssertEqual(controller.status.manualEndReason, .time)
        }
    }
    func testRehearsalDoesNotChangeSettingsHistoryOrExecution() async {
        await MainActor.run {
            let (defaults, controller, system, display) = fixture(); defer { _ = controller.end() }
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
            let model = AppModel(preview: true, capabilities: MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false),
                previewSession: controller, previewDefaults: defaults)
            let before = controller.settings, history = model.v4History
            let plan = model.rehearseV4(power: .battery, lidClosed: true, protected: false, event: "unplug")
            XCTAssertFalse(plan.isEmpty)
            XCTAssertEqual(controller.settings, before)
            XCTAssertEqual(model.v4History, history)
            XCTAssertEqual(system.creates, 0); XCTAssertEqual(display.creates, 0)
        }
    }
    func testUnplugConsumesEventScopeAndLateHeartbeatCannotRevive() async throws {
        try await MainActor.run {
            let (_, controller, _, _) = fixture(); defer { _ = controller.end() }
            let now = ContinuousTime.now
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now)
            controller.setAutomatic(true)
            let oldScope = controller.v4Scope, job = UUID()
            let begin = V4WorkEvent(jobID: job, eventID: UUID(), sequence: 1, scope: oldScope, producerID: "fixture", kind: .start)
            XCTAssertEqual(controller.applyWorkEvent(begin, now: now).disposition, .accepted)
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: now + 1, batteryPercent: 90)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now + 2, batteryPercent: 90)
            let heartbeat = V4WorkEvent(jobID: job, eventID: UUID(), sequence: 2, scope: oldScope, producerID: "fixture", kind: .heartbeat)
            XCTAssertEqual(controller.applyWorkEvent(heartbeat, now: now + 3).disposition, .rejected)
            XCTAssertEqual(try XCTUnwrap(controller.v4WorkEvents.records[job]).state, .revoked)
        }
    }
}
