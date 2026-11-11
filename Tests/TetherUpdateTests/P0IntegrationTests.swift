import Foundation
import XCTest
@testable import Tether
import TetherCore

/// No persistent preferences, native assertions, helper service or OS Sleep.
private final class P0MemoryDefaults: UserDefaults {
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

private final class P0AssertionBackend: IdleAssertionBackend {
    var creates = 0
    var renews = 0
    var releases = 0
    var releaseCode: Int32 = 0
    private var ids: Set<UInt32> = []
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        creates += 1; let id = UInt32(creates); ids.insert(id); return (0, id)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { renews += 1; return ids.contains(id) ? 0 : -1 }
    func level(id: UInt32) -> Int? { ids.contains(id) ? 255 : 0 }
    func release(id: UInt32) -> Int32 {
        releases += 1
        if releaseCode == 0 { ids.remove(id) }
        return releaseCode
    }
}

@MainActor
final class P0IntegrationTests: XCTestCase {
    private func fixture(power: PowerSource = .ac, settings: IdleSessionSettings = .init(),
                         advancedClockRule: Bool = false) throws
        -> (P0MemoryDefaults, P0AssertionBackend, UserSessionController, Double) {
        let defaults = P0MemoryDefaults(), backend = P0AssertionBackend()
        var saved = settings; saved.legacyRootConfigurationPending = false
        if advancedClockRule {
            let condition = V4Condition(id: UUID(), kind: .timeWindow,
                timeWindow: .init(startMinute: 0, endMinute: 0))
            let preset = V4Preset(id: UUID(), name: "Explicit advanced clock", groups: [
                V4RuleGroup(id: UUID(), conditions: [condition])
            ])
            saved.v4.automaticMode = .advanced; saved.v4.presets = [preset]; saved.v4.activePresetID = preset.id
        }
        defaults.set(try JSONEncoder().encode(saved), forKey: UserSessionController.preferenceKey)
        let controller = UserSessionController(defaults: defaults, backend: backend,
            displayBackend: P0AssertionBackend(), guiProbe: nil, environmentProbe: nil, boot: "p0-integration")
        let now = ContinuousTime.now
        controller.update(power: power, thermal: 0, fullWake: true, controllingUser: true, now: now, batteryPercent: 80)
        return (defaults, backend, controller, now)
    }
    private func observe(_ controller: UserSessionController, _ power: PowerSource, _ now: Double,
                         thermal: Int? = 0, fullWake: Bool? = true, battery: Int? = 80) {
        controller.update(power: power, thermal: thermal, fullWake: fullWake, controllingUser: true,
            now: now, batteryPercent: battery)
    }

    func testDefaultUnplugConsumesManualAndOrdinaryWakeCannotRestoreIt() throws {
        let (_, backend, controller, now) = try fixture(); defer { _ = controller.end() }
        XCTAssertTrue(controller.start(duration: 600, now: now))
        let originalID = try XCTUnwrap(controller.manualRequestID)
        observe(controller, .battery, now + 1)
        XCTAssertFalse(controller.status.manualActive); XCTAssertFalse(controller.status.holding)
        XCTAssertEqual(controller.status.manualEndReason, .powerDisconnected)
        XCTAssertEqual(backend.releases, 1)
        controller.observeSystemSleep(observedAt: now + 2)
        observe(controller, .battery, now + 3)
        observe(controller, .ac, now + 4)
        XCTAssertNil(controller.manualRequestID); XCTAssertNotEqual(controller.manualRequestID, originalID)
        XCTAssertFalse(controller.status.holding)
    }

    func testContinueOptionKeepsTheSameManualRequestAndOriginalDeadline() throws {
        var settings = IdleSessionSettings(); settings.disconnectPolicy = .continueEligible
        let (_, _, controller, now) = try fixture(settings: settings); defer { _ = controller.end() }
        XCTAssertTrue(controller.start(duration: 3600, now: now))
        let id = controller.manualRequestID, deadline = controller.status.manualContinuousDeadline
        observe(controller, .battery, now + 20)
        XCTAssertEqual(controller.manualRequestID, id); XCTAssertTrue(controller.status.holding)
        XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
        observe(controller, .ac, now + 21)
        observe(controller, .battery, now + 22)
        XCTAssertEqual(controller.manualRequestID, id)
        XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
    }

    func testMandatoryUnknownDoesNotRenewNativeOrIssueANewLidPermit() throws {
        let (_, backend, controller, now) = try fixture(); defer { _ = controller.end() }
        XCTAssertTrue(controller.start(duration: 600, now: now))
        XCTAssertNotNil(controller.workLease(now: now))
        let renews = backend.renews, creates = backend.creates
        observe(controller, .unknown, now + 5)
        XCTAssertEqual(controller.status.observationLimited, true)
        XCTAssertEqual(backend.renews, renews); XCTAssertEqual(backend.creates, creates)
        XCTAssertNil(controller.workLease(now: now + 5))
        XCTAssertFalse(controller.start(duration: 600, now: now + 6))
        XCTAssertFalse(controller.extend(duration: 900, now: now + 6))
        observe(controller, .unknown, now + 15)
        XCTAssertFalse(controller.status.manualActive); XCTAssertFalse(controller.status.holding)
        observe(controller, .ac, now + 16)
        XCTAssertFalse(controller.status.manualActive); XCTAssertFalse(controller.status.holding)
    }

    func testExplicitSleepSurvivesWakeUnknownAndControllerRestart() throws {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        let (defaults, _, controller, now) = try fixture(settings: settings)
        defer { _ = controller.end() }
        XCTAssertTrue(controller.status.automaticActive)
        XCTAssertTrue(controller.start(duration: 600, now: now))
        XCTAssertTrue(controller.pauseForUserSleep(now: now + 1))
        controller.observeSystemSleep(observedAt: now + 2)
        observe(controller, .ac, now + 3)
        observe(controller, .unknown, now + 4)
        observe(controller, .ac, now + 5)
        XCTAssertEqual(controller.runtimeMarkers.pauseReason, .userSleep)
        XCTAssertFalse(controller.status.holding); XCTAssertNil(controller.manualRequestID)
        let restarted = UserSessionController(defaults: defaults, backend: P0AssertionBackend(),
            displayBackend: P0AssertionBackend(), guiProbe: nil, environmentProbe: nil, boot: "p0-integration")
        defer { _ = restarted.end() }
        observe(restarted, .ac, now + 6)
        XCTAssertEqual(restarted.runtimeMarkers.pauseReason, .userSleep)
        XCTAssertFalse(restarted.status.holding)
    }

    func testStopAllCannotBeClearedByNewACOrOrdinaryWake() throws {
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        let (_, _, controller, now) = try fixture(settings: settings); defer { _ = controller.end() }
        XCTAssertTrue(controller.setEnabled(false))
        controller.observeSystemSleep(observedAt: now + 1)
        observe(controller, .battery, now + 2)
        observe(controller, .ac, now + 3)
        XCTAssertEqual(controller.runtimeMarkers.pauseReason, .userStop)
        XCTAssertFalse(controller.status.holding)
        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertTrue(controller.status.automaticActive)
    }

    func testExplicitBatteryAutomaticUsesTheSelectedRuleGateAndCannotBypassUnplugEnd() throws {
        var settings = IdleSessionSettings()
        settings.automaticEnabled = true; settings.automaticPowerCondition = .any
        let (_, _, controller, now) = try fixture(settings: settings, advancedClockRule: true); defer { _ = controller.end() }
        XCTAssertTrue(controller.status.automaticActive)
        observe(controller, .battery, now + 1)
        XCTAssertFalse(controller.status.automaticActive); XCTAssertFalse(controller.status.holding)
        controller.observeSystemSleep(observedAt: now + 2)
        observe(controller, .battery, now + 3)
        XCTAssertFalse(controller.status.automaticActive, "Wake must not evade the already consumed unplug boundary")

        settings.automaticPowerCondition = .battery
        let (_, _, direct, next) = try fixture(power: .battery, settings: settings, advancedClockRule: true)
        defer { _ = direct.end() }
        XCTAssertEqual(direct.v4RuleEvaluation?.gate.isSatisfied, true)
        XCTAssertTrue(direct.status.automaticActive)
        let previousID = direct.workLease(now: next)?.automaticRequestID
        direct.observeSystemSleep(observedAt: next + 1)
        observe(direct, .battery, next + 2)
        XCTAssertTrue(direct.status.automaticActive)
        XCTAssertNotEqual(direct.workLease(now: next + 2)?.automaticRequestID, previousID)
    }

    func testBatteryAutomaticWakeCannotRefillItsOriginalBudget() throws {
        var settings = IdleSessionSettings()
        settings.automaticEnabled = true; settings.automaticPowerCondition = .battery
        settings.batteryTimeLimit = .thirtyMinutes
        let (_, _, controller, now) = try fixture(power: .battery, settings: settings, advancedClockRule: true)
        defer { _ = controller.end() }
        let first = try XCTUnwrap(controller.workLease(now: now)?.automaticBatteryDeadline)
        controller.observeSystemSleep(observedAt: now + 60)
        observe(controller, .battery, now + 61)
        XCTAssertEqual(controller.workLease(now: now + 61)?.automaticBatteryDeadline, first)
        observe(controller, .battery, now + 1800)
        XCTAssertFalse(controller.status.holding)
        controller.observeSystemSleep(observedAt: now + 1801)
        observe(controller, .battery, now + 1802)
        XCTAssertFalse(controller.status.automaticActive); XCTAssertFalse(controller.status.holding)
    }

    func testProtectionResumeNeedsFreshSixtySecondWindowAndNeverRevivesManual() throws {
        let (_, _, controller, now) = try fixture(); defer { _ = controller.end() }
        XCTAssertTrue(controller.start(duration: 600, now: now))
        observe(controller, .ac, now + 1, thermal: 3)
        XCTAssertFalse(controller.status.holding); XCTAssertFalse(controller.canResume)
        for second in stride(from: 2, through: 62, by: 10) {
            observe(controller, .ac, now + Double(second))
            if second < 62 { XCTAssertFalse(controller.canResume) }
        }
        XCTAssertTrue(controller.canResume)
        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertFalse(controller.status.manualActive); XCTAssertNil(controller.manualRequestID)
    }

    func testProtectionConsumesWorkingAndWaitingJobsEvenWhenTTLRemainsAfterAutoRecovery() throws {
        for waiting in [false, true] {
            var settings = IdleSessionSettings()
            settings.automaticEnabled = true; settings.automaticallyResumeAfterProtection = true
            let (_, _, controller, now) = try fixture(settings: settings)
            defer { _ = controller.end() }
            let job = UUID(), scope = controller.v4Scope
            func event(_ id: UUID, _ sequence: UInt64, _ kind: V4WorkEventKind) -> V4WorkEvent {
                .init(jobID: id, eventID: UUID(), sequence: sequence, scope: scope,
                      producerID: "p0-fixture", kind: kind, ttl: 300)
            }
            XCTAssertEqual(controller.applyWorkEvent(event(job, 1, .start), now: now).disposition, .accepted)
            if waiting {
                XCTAssertEqual(controller.applyWorkEvent(event(job, 2, .waiting), now: now).disposition, .accepted)
            }
            observe(controller, .ac, now + 1, thermal: 3)
            XCTAssertEqual(controller.v4WorkEvents.records[job]?.state, .revoked)
            for second in stride(from: 2, through: 62, by: 10) { observe(controller, .ac, now + Double(second)) }
            XCTAssertTrue(controller.status.automaticActive)
            let late = controller.applyWorkEvent(event(job, 3, .heartbeat), now: now + 63)
            XCTAssertEqual(late.disposition, .rejected); XCTAssertEqual(late.reason, "consumed-job")
            XCTAssertEqual(controller.v4WorkEvents.records[job]?.state, .revoked)
            XCTAssertEqual(controller.applyWorkEvent(event(UUID(), 1, .start), now: now + 63).disposition, .accepted)
        }
    }

    func testFailedNativeReleaseIsReportedUntilRetryConfirmsOwnRelease() throws {
        let (_, backend, controller, now) = try fixture()
        XCTAssertTrue(controller.start(duration: 600, now: now))
        backend.releaseCode = -1
        XCTAssertFalse(controller.end())
        XCTAssertEqual(controller.status.ownReleasePending, true)
        XCTAssertNotNil(controller.status.error)
        backend.releaseCode = 0
        XCTAssertTrue(controller.end())
        XCTAssertEqual(controller.status.ownReleasePending, false)
        XCTAssertFalse(controller.status.holding)
    }

    func testLidOnlyObservationFailureDoesNotConsumeHealthyGeneralWorkButThermalDoes() throws {
        let (_, backend, controller, now) = try fixture()
        defer { _ = controller.end() }
        controller.setAllowClosedLid(true)
        XCTAssertTrue(controller.start(duration: 600, now: now))
        let original = try XCTUnwrap(controller.workLease(now: now))
        let request = controller.manualRequestID, deadline = controller.status.manualContinuousDeadline
        var lidOnly = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
        lidOnly.lidProtection = WorkSessionProtectionLatch(bootID: "p0-integration",
            reason: "powerObservationUnavailable", observedAt: now + 1,
            sessionID: controller.sessionID, sequence: original.sequence)
        lidOnly.lidEndReceipt = WorkSessionEndReceipt(bootID: "p0-integration", sessionID: controller.sessionID,
            sequence: original.sequence, observedAt: now + 1, kind: .protection, action: .followOS)
        controller.acceptBridge(lidOnly, protection: nil, now: now + 2)
        XCTAssertEqual(controller.manualRequestID, request)
        XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
        XCTAssertTrue(controller.status.holding); XCTAssertNil(controller.status.blockReason)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
        let acknowledged = try XCTUnwrap(controller.workLease(now: now + 2))
        XCTAssertEqual(acknowledged.endConsumptionID, lidOnly.lidEndReceipt?.id)

        var thermal = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
        thermal.lidProtection = WorkSessionProtectionLatch(bootID: "p0-integration",
            reason: "thermal", observedAt: now + 3,
            sessionID: controller.sessionID, sequence: acknowledged.sequence)
        thermal.lidEndReceipt = WorkSessionEndReceipt(bootID: "p0-integration", sessionID: controller.sessionID,
            sequence: acknowledged.sequence, observedAt: now + 3, kind: .protection, action: .followOS)
        controller.acceptBridge(thermal, protection: nil, now: now + 4)
        XCTAssertFalse(controller.status.holding); XCTAssertFalse(controller.status.manualActive)
        XCTAssertEqual(controller.status.blockReason, "thermal")
    }

    func testApprovedPolicyChoicesPersistWithoutRestoringTemporaryWorkAndUnlimitedStatusEncodes() throws {
        let (defaults, _, controller, now) = try fixture(power: .battery)
        defer { _ = controller.end() }
        XCTAssertTrue(controller.setDisconnectPolicy(.continueEligible))
        XCTAssertTrue(controller.setManualPowerCondition(.any))
        XCTAssertTrue(controller.setBatteryTimeLimit(.unlimited))
        XCTAssertTrue(controller.setAutomaticallyResumeAfterProtection(true))
        XCTAssertTrue(controller.setStopOnSeriousThermal(false))
        XCTAssertTrue(controller.setStartAutomaticOnBatteryDisconnect(true))
        XCTAssertTrue(controller.start(duration: nil, now: now))
        let data = try JSONEncoder().encode(controller.status)
        XCTAssertEqual(try JSONDecoder().decode(UserSessionStatus.self, from: data).batteryTimeLimit, .unlimited)
        let restarted = UserSessionController(defaults: defaults, backend: P0AssertionBackend(),
            displayBackend: P0AssertionBackend(), guiProbe: nil, environmentProbe: nil, boot: "p0-integration")
        defer { _ = restarted.end() }
        XCTAssertEqual(restarted.settings.disconnectPolicy, .continueEligible)
        XCTAssertEqual(restarted.settings.batteryTimeLimit, .unlimited)
        XCTAssertTrue(restarted.settings.automaticallyResumeAfterProtection)
        XCTAssertFalse(restarted.settings.stopOnSeriousThermal)
        XCTAssertTrue(restarted.settings.startAutomaticOnBatteryDisconnect)
        observe(restarted, .battery, now + 1)
        XCTAssertNil(restarted.manualRequestID); XCTAssertFalse(restarted.status.holding)
    }

    func testActiveRequestsKeepIndependentCapturedScopesAndCapsWhenNextDefaultsChange() throws {
        var settings = IdleSessionSettings()
        settings.automaticEnabled = true; settings.automaticPowerCondition = .any
        settings.disconnectPolicy = .continueEligible; settings.batteryTimeLimit = .thirtyMinutes
        let (_, _, controller, now) = try fixture(power: .battery, settings: settings, advancedClockRule: true)
        defer { _ = controller.end() }
        XCTAssertTrue(controller.status.automaticActive)
        XCTAssertTrue(controller.setBatteryTimeLimit(.fourHours))
        XCTAssertTrue(controller.start(duration: 4 * 3600, now: now))
        let manualID = controller.manualRequestID
        XCTAssertTrue(controller.setBatteryTimeLimit(.thirtyMinutes))
        XCTAssertTrue(controller.setManualPowerCondition(.ac))
        let lease = try XCTUnwrap(controller.workLease(now: now))
        XCTAssertEqual(lease.manualRequestID, manualID)
        XCTAssertEqual(lease.manualPowerCondition, .any)
        XCTAssertEqual(lease.manualBatteryTimeLimit, .fourHours)
        XCTAssertEqual(lease.automaticBatteryTimeLimit, .thirtyMinutes)
        XCTAssertEqual(lease.configuration.batteryTimeLimit, .thirtyMinutes, "A next default remains distinct from both live request limits")
        XCTAssertTrue(lease.isValid(now: now))
        observe(controller, .battery, now + 1800)
        XCTAssertFalse(controller.status.automaticActive)
        XCTAssertEqual(controller.manualRequestID, manualID)
        let manualOnly = try XCTUnwrap(controller.workLease(now: now + 1800))
        XCTAssertEqual(manualOnly.manualBatteryTimeLimit, .fourHours)
        XCTAssertTrue(manualOnly.isValid(now: now + 1800))
        observe(controller, .ac, now + 1801)
        observe(controller, .battery, now + 1802)
        XCTAssertEqual(controller.manualRequestID, manualID)
    }

    func testAppSleepFailurePreservesTheExplicitStopAndEndedTimer() async throws {
        let (defaults, _, controller, now) = try fixture()
        defer { _ = controller.end() }
        XCTAssertTrue(controller.start(duration: 600, now: now))
        let owner = GUISessionObservation(login: .init(uid: getuid(), sessionID: 100001), consoleUID: getuid())
        var effects = 0
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller, previewDefaults: defaults,
            previewSleepExecutor: { effects += 1; return false }, previewSleepSettled: { true },
            previewSleepAuthority: { owner })
        let intent = try model.beginExplicitSleep(deadline: ContinuousTime.now + 15)
        XCTAssertTrue(controller.pauseForUserSleep())
        let failure = await model.executeExplicitSleep(intent)
        XCTAssertEqual(failure, "pmsetFailed"); XCTAssertEqual(effects, 1)
        XCTAssertEqual(controller.runtimeMarkers.pauseReason, .userSleep)
        XCTAssertFalse(controller.status.manualActive); XCTAssertFalse(controller.status.holding)
        controller.observeSystemSleep(observedAt: now + 1)
        observe(controller, .ac, now + 2)
        XCTAssertEqual(controller.runtimeMarkers.pauseReason, .userSleep)
        XCTAssertFalse(controller.status.holding)
    }

    func testGUIAndCommandSleepEntryPointsKeepStopAfterMockEffectFailure() async throws {
        let (defaults, _, controller, now) = try fixture()
        defer { _ = controller.end() }
        XCTAssertTrue(controller.start(duration: 600, now: now))
        let owner = GUISessionObservation(login: .init(uid: getuid(), sessionID: 100001), consoleUID: getuid())
        var effects = 0
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller, previewDefaults: defaults,
            previewSleepExecutor: { effects += 1; return false }, previewSleepSettled: { true },
            previewSleepAuthority: { owner })
        model.sleepNow()
        for _ in 0..<100 where effects == 0 { await Task.yield() }
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(controller.runtimeMarkers.pauseReason, .userSleep)
        XCTAssertFalse(controller.status.holding); XCTAssertFalse(controller.status.manualActive)
        // The same-account command path still uses the same stop-before-effect contract.
        let process = try XCTUnwrap(ProcessIdentity.capture(pid: getpid()))
        model.userCommandCompanion = process.executable
        model.userCommandOwnerProbe = { owner }
        let peer = UserSessionPeer(uid: getuid(), process: process, login: nil)
        let current = model.userCommandReply(UserSessionRequest())
        let request = UserSessionRequest(.sleep, epoch: current.epoch, revision: current.revision)
        let reply = await model.handleUserCommand(request, peer: peer)
        XCTAssertFalse(reply.ok); XCTAssertEqual(reply.error, "pmsetFailed")
        XCTAssertEqual(effects, 2)
        XCTAssertEqual(controller.runtimeMarkers.pauseReason, .userSleep)
        XCTAssertFalse(controller.status.manualActive)
        observe(controller, .ac, now + 1)
        XCTAssertEqual(controller.runtimeMarkers.pauseReason, .userSleep)
        XCTAssertFalse(controller.status.holding)
    }

    func testK09NotebookGeneralSetupRequiresNoHelperAndRejectsUnpreparedLidBeforeApplyingAutomatic() throws {
        let (defaults, backend, controller, _) = try fixture()
        defer { _ = controller.end() }
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller, previewDefaults: defaults)
        XCTAssertTrue(model.canFinishOnboarding)
        XCTAssertFalse(model.canFinishOnboarding(allowClosedLid: true))
        let before = defaults.data(forKey: UserSessionController.preferenceKey)
        XCTAssertFalse(model.finishOnboarding(automaticEnabled: true, allowClosedLid: true))
        XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), before)
        XCTAssertFalse(model.automaticEnabled); XCTAssertFalse(controller.settings.allowClosedLid)
        XCTAssertEqual(backend.creates, 0)
        XCTAssertTrue(model.finishOnboarding(automaticEnabled: false, allowClosedLid: false))
        XCTAssertFalse(model.needsOnboarding); XCTAssertFalse(model.helperInstalled)
        model.startManualSession(minutes: 30)
        XCTAssertTrue(controller.status.manualActive); XCTAssertTrue(controller.status.holding)
        XCTAssertEqual(backend.creates, 1)
    }

    func testK09ExistingLidUserCanChooseGeneralWorkWithoutChangingStopOrApprovedOptions() throws {
        var settings = IdleSessionSettings()
        settings.allowClosedLid = true; settings.automaticEnabled = true
        settings.disconnectPolicy = .continueEligible; settings.batteryTimeLimit = .fourHours
        settings.runtimeMarkers = RuntimeMarkers(pauseReason: .userStop)
        let (defaults, backend, controller, _) = try fixture(settings: settings)
        defer { _ = controller.end() }
        defaults.set(true, forKey: "onboarded")
        defaults.set(true, forKey: "helperUpgradePending")
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller, previewDefaults: defaults)
        XCTAssertTrue(model.requiresHelperSetup); XCTAssertTrue(model.needsOnboarding)
        XCTAssertFalse(model.canFinishOnboarding)
        XCTAssertTrue(model.canFinishOnboarding(allowClosedLid: false))
        XCTAssertTrue(model.finishOnboarding(automaticEnabled: false, allowClosedLid: false))
        XCTAssertFalse(controller.settings.allowClosedLid); XCTAssertFalse(model.needsOnboarding)
        XCTAssertTrue(controller.settings.automaticEnabled, "An existing automatic choice is not reapplied or replaced by the draft")
        XCTAssertEqual(controller.runtimeMarkers.pauseReason, .userStop)
        XCTAssertEqual(controller.settings.disconnectPolicy, .continueEligible)
        XCTAssertEqual(controller.settings.batteryTimeLimit, .fourHours)
        XCTAssertTrue(defaults.bool(forKey: "helperUpgradePending"), "Opting out does not uninstall or discard pending helper repair")
        XCTAssertEqual(backend.creates, 0); XCTAssertFalse(controller.status.holding)
    }

    func testK09ExistingManualDeadlineSurvivesLidOptOutAndFailedChoicePersistence() throws {
        for writeSucceeds in [true, false] {
            var settings = IdleSessionSettings(); settings.allowClosedLid = true
            let (defaults, backend, controller, now) = try fixture(settings: settings)
            defer { _ = controller.end() }
            XCTAssertTrue(controller.start(duration: 600, now: now))
            let request = controller.manualRequestID, deadline = controller.status.manualContinuousDeadline
            defaults.set(true, forKey: "onboarded")
            let model = AppModel(preview: true,
                capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: controller, previewDefaults: defaults)
            let saved = defaults.data(forKey: UserSessionController.preferenceKey)
            controller.persistenceProbe = { writeSucceeds }
            XCTAssertEqual(model.finishOnboarding(automaticEnabled: true, allowClosedLid: false), writeSucceeds)
            XCTAssertEqual(controller.manualRequestID, request)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertEqual(controller.settings.allowClosedLid, !writeSucceeds)
            XCTAssertFalse(controller.settings.automaticEnabled)
            XCTAssertEqual(backend.creates, 1, "Preparation never recreates the native request")
            if writeSucceeds { XCTAssertTrue(controller.status.holding) }
            else { XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), saved) }
            controller.persistenceProbe = { true }
        }
    }

    func testK09HelperAuthenticationAloneNeverEnablesAutomaticLidOrStartsWork() async throws {
        let (defaults, backend, controller, _) = try fixture()
        defer { _ = controller.end() }
        var authentications = 0
        var status = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
            enabled: true, power: .ac, lidClosed: false, sleepDisabled: false,
            lastEvent: nil, lastEventAt: nil, thermal: 0)
        status.build = TetherPaths.build; status.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
        status.systemPowerObservationAvailable = true
        var control = Control(); control.schemaVersion = Control.currentSchema
        var reply = ServiceReply(id: UUID(), ok: true, epoch: "p0-preparation", revision: 1,
            control: control, protection: .init(reason: nil, error: nil, dryRun: true))
        reply.status = status
        XCTAssertTrue(reply.isCurrentHelperReady(), "Authentication fixture must satisfy the complete current helper contract")
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller,
            previewLegacyObservation: { .init(power: .ac, lidClosed: false, sleepDisabled: false) }, previewDefaults: defaults,
            previewHelperInstaller: { authentications += 1 }, previewHelperReadiness: { reply }, previewHelperFiles: { [] })
        model.installHelper()
        for _ in 0..<1000 where model.helperInstallInFlight { await Task.yield() }
        XCTAssertEqual(authentications, 1); XCTAssertTrue(model.helperInstallationComplete)
        XCTAssertTrue(model.helperSetupConfirmed)
        XCTAssertFalse(controller.settings.automaticEnabled); XCTAssertFalse(controller.settings.allowClosedLid)
        XCTAssertFalse(controller.status.holding); XCTAssertNil(controller.manualRequestID)
        XCTAssertEqual(backend.creates, 0)
        XCTAssertTrue(model.canFinishOnboarding(allowClosedLid: true))
    }
}
