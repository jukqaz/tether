import Foundation
import XCTest
import TetherCore
@testable import Tether

private final class AutomaticPauseDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func register(defaults: [String: Any]) { registered.merge(defaults) { _, new in new } }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
    override func synchronize() -> Bool { true }
    override func persistentDomain(forName name: String) -> [String: Any]? { values }
}

private final class AutomaticPauseBackend: IdleAssertionBackend {
    var creates = 0
    var releases = 0
    private var ids: Set<UInt32> = []
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        creates += 1; let id = UInt32(creates); ids.insert(id); return (0, id)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { ids.contains(id) ? 0 : -1 }
    func level(id: UInt32) -> Int? { ids.contains(id) ? 255 : 0 }
    func release(id: UInt32) -> Int32 { releases += 1; ids.remove(id); return 0 }
}

private final class AutomaticPauseClock {
    let origin = ContinuousTime.now
    var elapsed: Double = 0
    var now: Double { origin + elapsed }
    var wall: Date { Date(timeIntervalSince1970: 1_800_000_000 + elapsed) }
}

/// Product controller and model with memory-only executors/defaults and an
/// explicitly advanced clock. No helper, native assertion or OS Sleep is used.
@MainActor
final class AutomaticPauseTests: XCTestCase {
    private struct Fixture {
        let defaults: AutomaticPauseDefaults
        let clock: AutomaticPauseClock
        let backend: AutomaticPauseBackend
        let display: AutomaticPauseBackend
        let controller: UserSessionController
        let model: AppModel
    }
    private func fixture(settings: IdleSessionSettings = .init(), power: PowerSource = .ac,
                         defaults previous: AutomaticPauseDefaults? = nil, clock: AutomaticPauseClock = .init(),
                         boot: String = "automatic-pause", advancedSatisfied: Bool? = nil) throws -> Fixture {
        let defaults = previous ?? AutomaticPauseDefaults()
        if previous == nil {
            var saved = settings; saved.automaticEnabled = true; saved.legacyRootConfigurationPending = false
            if advancedSatisfied != nil {
                let preset = V4Preset(id: UUID(), name: "Selected conditions", groups: [
                    V4RuleGroup(id: UUID(), conditions: [V4Condition(id: UUID(), kind: .appRunning, target: "fixture.editor")])
                ])
                saved.v4.automaticMode = .advanced; saved.v4.presets = [preset]; saved.v4.activePresetID = preset.id
            }
            defaults.set(try JSONEncoder().encode(saved), forKey: UserSessionController.preferenceKey)
        }
        let backend = AutomaticPauseBackend(), display = AutomaticPauseBackend()
        let controller = UserSessionController(defaults: defaults, backend: backend, displayBackend: display,
            guiProbe: nil, environmentProbe: nil, boot: boot, wallClock: { clock.wall }, continuousClock: { clock.now })
        if let advancedSatisfied {
            controller.v4ConditionSource.queryOverride = { _, _ in (advancedSatisfied ? .satisfied : .notSatisfied, nil) }
        }
        controller.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
            now: clock.now, batteryPercent: 80)
        let model = AppModel(preview: true, capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller, previewDefaults: defaults)
        return Fixture(defaults: defaults, clock: clock, backend: backend, display: display, controller: controller, model: model)
    }
    private func observe(_ f: Fixture, after seconds: Double, power: PowerSource = .ac, thermal: Int? = 0,
                         fullWake: Bool? = true) {
        f.clock.elapsed += seconds
        f.controller.update(power: power, thermal: thermal, fullWake: fullWake, controllingUser: true,
            now: f.clock.now, batteryPercent: 80)
    }

    func testTimedPauseEndsOnlyAutomaticReasonAndExpiryKeepsOriginalManualAndDisplayRequest() throws {
        var settings = IdleSessionSettings(); settings.keepDisplayAwake = true
        let f = try fixture(settings: settings); defer { _ = f.controller.end() }
        XCTAssertTrue(f.controller.start(duration: 3600, now: f.clock.now))
        let requestID = try XCTUnwrap(f.controller.manualRequestID)
        let deadline = try XCTUnwrap(f.controller.status.manualContinuousDeadline)
        let activation = f.controller.runtimeMarkers.automaticActivation?.id
        XCTAssertTrue(f.model.pauseAutomatic(for: 1800))
        XCTAssertTrue(f.model.automaticPauseActive)
        XCTAssertEqual(f.model.automaticPauseUntil, f.clock.wall.addingTimeInterval(1800))
        XCTAssertTrue(f.model.automaticEnabled)
        XCTAssertFalse(f.model.automaticWorkReasonActive)
        XCTAssertTrue(f.model.manualSessionActive)
        XCTAssertTrue(f.model.workSessionHolding)
        XCTAssertEqual(f.controller.status.displayHolding, true)
        XCTAssertEqual(f.controller.manualRequestID, requestID)
        XCTAssertEqual(f.controller.status.manualContinuousDeadline, deadline)
        XCTAssertEqual(f.backend.creates, 1); XCTAssertEqual(f.backend.releases, 0)
        XCTAssertEqual(f.display.creates, 1); XCTAssertEqual(f.display.releases, 0)
        let saved = try JSONDecoder().decode(IdleSessionSettings.self,
            from: XCTUnwrap(f.defaults.data(forKey: UserSessionController.preferenceKey)))
        XCTAssertTrue(saved.automaticEnabled)
        XCTAssertEqual(saved.runtimeMarkers?.automaticPause?.until, f.clock.now + 1800)

        observe(f, after: 1800)
        XCTAssertFalse(f.model.automaticPauseActive)
        XCTAssertNil(f.model.automaticPauseUntil)
        XCTAssertNil(f.controller.status.automaticPauseUntil)
        XCTAssertTrue(f.model.automaticWorkReasonActive)
        XCTAssertEqual(f.controller.runtimeMarkers.automaticActivation?.id, activation)
        XCTAssertEqual(f.controller.manualRequestID, requestID)
        XCTAssertEqual(f.controller.status.manualContinuousDeadline, deadline)
        XCTAssertEqual(f.controller.status.displayHolding, true)
        XCTAssertEqual(f.backend.creates, 1); XCTAssertEqual(f.display.creates, 1)
    }

    func testManualStartAndAutomaticOnDoNotResumeAnIndefinitePauseButAutomaticOffClearsIt() throws {
        let f = try fixture(); defer { _ = f.controller.end() }
        XCTAssertTrue(f.model.pauseAutomatic(for: nil))
        XCTAssertNil(f.model.automaticPauseUntil)
        XCTAssertTrue(f.controller.start(duration: 600, now: f.clock.now))
        let id = f.controller.manualRequestID, deadline = f.controller.status.manualContinuousDeadline
        f.model.setAutomaticEnabled(true)
        XCTAssertTrue(f.model.automaticPauseActive)
        XCTAssertFalse(f.model.automaticWorkReasonActive)
        XCTAssertEqual(f.controller.manualRequestID, id)
        XCTAssertEqual(f.controller.status.manualContinuousDeadline, deadline)
        XCTAssertTrue(f.model.resumeAutomatic())
        XCTAssertFalse(f.model.automaticPauseActive)
        XCTAssertTrue(f.model.automaticWorkReasonActive)
        XCTAssertEqual(f.controller.manualRequestID, id)
        XCTAssertEqual(f.controller.status.manualContinuousDeadline, deadline)
        XCTAssertTrue(f.model.pauseAutomatic(for: nil))
        f.model.setAutomaticEnabled(false)
        XCTAssertFalse(f.model.automaticPauseActive)
        XCTAssertFalse(f.model.automaticEnabled)
        XCTAssertTrue(f.model.manualSessionActive)
        XCTAssertEqual(f.controller.manualRequestID, id)
    }

    func testBatteryAutomaticPauseExpiryAndExplicitResumeKeepTheSameActivationAndFirstCap() throws {
        for duration: Double? in [1800, nil] {
            var settings = IdleSessionSettings(); settings.automaticPowerCondition = .battery
            settings.batteryTimeLimit = .fourHours; settings.disconnectPolicy = .continueEligible
            let f = try fixture(settings: settings, power: .battery); defer { _ = f.controller.end() }
            let activation = try XCTUnwrap(f.controller.runtimeMarkers.automaticActivation)
            let deadline = try XCTUnwrap(activation.batteryDeadline)
            let oldExecution = try XCTUnwrap(f.controller.sessionDecision.automaticRequestID)
            XCTAssertTrue(f.model.pauseAutomatic(for: duration))
            XCTAssertFalse(f.model.automaticWorkReasonActive)
            XCTAssertTrue(f.controller.setBatteryTimeLimit(.thirtyMinutes))
            observe(f, after: duration ?? 60, power: .battery)
            if duration == nil { XCTAssertTrue(f.model.resumeAutomatic()) }
            XCTAssertFalse(f.model.automaticPauseActive)
            XCTAssertTrue(f.model.automaticWorkReasonActive)
            XCTAssertEqual(f.controller.runtimeMarkers.automaticActivation?.id, activation.id)
            XCTAssertEqual(f.controller.runtimeMarkers.automaticActivation?.batteryDeadline, deadline)
            XCTAssertEqual(f.controller.sessionDecision.automaticBatteryDeadline, deadline)
            XCTAssertEqual(f.controller.runtimeMarkers.automaticActivation?.batteryLimit, .fourHours)
            XCTAssertNotEqual(f.controller.sessionDecision.automaticRequestID, oldExecution)
            XCTAssertLessThan(deadline - f.clock.now, 4 * 3600)
        }
    }

    func testEndAllUnplugDuringPauseRemainsConsumedAfterPauseExpires() throws {
        var settings = IdleSessionSettings(); settings.automaticPowerCondition = .any; settings.disconnectPolicy = .endAll
        let f = try fixture(settings: settings); defer { _ = f.controller.end() }
        XCTAssertTrue(f.controller.start(duration: 600, now: f.clock.now))
        XCTAssertTrue(f.model.pauseAutomatic(for: 1800))
        observe(f, after: 1, power: .battery)
        XCTAssertFalse(f.model.manualSessionActive)
        XCTAssertNil(f.controller.manualRequestID)
        XCTAssertEqual(f.controller.runtimeMarkers.automaticRestartBlocked, true)
        observe(f, after: 1799, power: .battery)
        XCTAssertFalse(f.model.automaticPauseActive)
        XCTAssertNil(f.model.automaticPauseUntil)
        XCTAssertFalse(f.model.automaticWorkReasonActive)
        XCTAssertFalse(f.model.workSessionHolding)
        XCTAssertEqual(f.controller.runtimeMarkers.automaticRestartBlocked, true)
        XCTAssertTrue(f.model.resumeAutomatic(), "Removing no remaining pause is idempotent, not permission to clear unplug consumption")
        XCTAssertFalse(f.model.workSessionHolding)
    }

    func testPauseExpiryNeverClearsStopAllOrProtectionAndNeverRestoresAnEndedTimer() throws {
        for thermalProtection in [false, true] {
            let f = try fixture(); defer { _ = f.controller.end() }
            XCTAssertTrue(f.controller.start(duration: 600, now: f.clock.now))
            XCTAssertTrue(f.model.pauseAutomatic(for: 1800))
            if thermalProtection { observe(f, after: 1, thermal: 2) }
            else { f.model.setEnabled(false) }
            let pauseReason = f.controller.runtimeMarkers.pauseReason
            let protection = f.controller.runtimeMarkers.protectionReason
            observe(f, after: 1800)
            XCTAssertFalse(f.model.automaticPauseActive)
            XCTAssertNil(f.controller.status.automaticPauseUntil)
            XCTAssertEqual(f.controller.runtimeMarkers.pauseReason, pauseReason)
            XCTAssertEqual(f.controller.runtimeMarkers.protectionReason, protection)
            XCTAssertTrue(f.model.workPaused)
            XCTAssertFalse(f.model.workSessionHolding)
            XCTAssertFalse(f.model.automaticWorkReasonActive)
            XCTAssertNil(f.controller.manualRequestID)
            XCTAssertNil(f.controller.status.manualContinuousDeadline)
            XCTAssertTrue(f.model.automaticEnabled)
        }
    }

    func testSameBootRestartKeepsPauseDeadlineAndIndefinitePauseUntilExplicitResume() throws {
        for duration: Double? in [3600, nil] {
            let original = try fixture()
            XCTAssertTrue(original.model.pauseAutomatic(for: duration))
            let marker = try XCTUnwrap(original.controller.runtimeMarkers.automaticPause)
            observe(original, after: 10)
            XCTAssertTrue(original.controller.end())
            let restarted = try fixture(defaults: original.defaults, clock: original.clock)
            defer { _ = restarted.controller.end() }
            XCTAssertTrue(restarted.model.automaticPauseActive)
            XCTAssertEqual(restarted.controller.runtimeMarkers.automaticPause, marker)
            XCTAssertFalse(restarted.model.automaticWorkReasonActive)
            XCTAssertEqual(restarted.backend.creates, 0)
            if duration != nil {
                observe(restarted, after: 3590)
                XCTAssertFalse(restarted.model.automaticPauseActive)
                XCTAssertNil(restarted.model.automaticPauseUntil)
                XCTAssertTrue(restarted.model.automaticWorkReasonActive)
            } else {
                observe(restarted, after: 7200)
                XCTAssertTrue(restarted.model.automaticPauseActive)
                XCTAssertNil(restarted.model.automaticPauseUntil)
                XCTAssertTrue(restarted.model.resumeAutomatic())
                XCTAssertTrue(restarted.model.automaticWorkReasonActive)
            }
        }
    }

    func testDifferentBootCannotTurnAnOldPauseClockIntoNewAutomaticPermission() throws {
        let original = try fixture()
        XCTAssertTrue(original.model.pauseAutomatic(for: 1800))
        let marker = original.controller.runtimeMarkers.automaticPause
        XCTAssertTrue(original.controller.end())
        let restarted = try fixture(defaults: original.defaults, clock: original.clock, boot: "different-boot")
        defer { _ = restarted.controller.end() }
        observe(restarted, after: 7200)
        XCTAssertTrue(restarted.model.automaticPauseActive)
        XCTAssertNil(restarted.model.automaticPauseUntil)
        XCTAssertEqual(restarted.controller.runtimeMarkers.automaticPause, marker)
        XCTAssertFalse(restarted.model.automaticWorkReasonActive)
        XCTAssertEqual(restarted.backend.creates, 0)
        XCTAssertTrue(restarted.model.resumeAutomatic())
        XCTAssertTrue(restarted.model.automaticWorkReasonActive)
    }

    func testExpiryRechecksAdvancedConditionsAndUnknownPowerBeforeAcquiring() throws {
        let advanced = try fixture(advancedSatisfied: false); defer { _ = advanced.controller.end() }
        XCTAssertTrue(advanced.model.pauseAutomatic(for: 1800))
        observe(advanced, after: 1800)
        XCTAssertFalse(advanced.model.automaticPauseActive)
        XCTAssertFalse(advanced.model.automaticWorkReasonActive)
        XCTAssertEqual(advanced.backend.creates, 0)

        let unknown = try fixture(); defer { _ = unknown.controller.end() }
        XCTAssertTrue(unknown.model.pauseAutomatic(for: 1800))
        let creates = unknown.backend.creates
        observe(unknown, after: 1800, power: .unknown)
        XCTAssertFalse(unknown.model.automaticPauseActive)
        XCTAssertFalse(unknown.model.workSessionHolding)
        XCTAssertEqual(unknown.backend.creates, creates)
        observe(unknown, after: 1)
        XCTAssertTrue(unknown.model.automaticWorkReasonActive)
    }

    func testPauseDuringUnknownImmediatelyRemovesOnlyAutomaticAuthorityAndReadsDoNotMutateState() throws {
        var settings = IdleSessionSettings(); settings.keepDisplayAwake = true
        let f = try fixture(settings: settings); defer { _ = f.controller.end() }
        XCTAssertTrue(f.controller.start(duration: 600, now: f.clock.now))
        let id = f.controller.manualRequestID, deadline = f.controller.status.manualContinuousDeadline
        observe(f, after: 5, power: .unknown)
        XCTAssertTrue(f.model.pauseAutomatic(for: nil))
        XCTAssertEqual(f.controller.sessionDecision.reasons, [.manual])
        XCTAssertFalse(f.model.automaticWorkReasonActive)
        XCTAssertTrue(f.model.manualSessionActive)
        XCTAssertEqual(f.controller.status.displayHolding, true)
        let before = f.controller.status
        let saved = f.defaults.data(forKey: UserSessionController.preferenceKey)
        let creates = f.backend.creates, displayCreates = f.display.creates
        for _ in 0..<5 { XCTAssertTrue(f.model.automaticPauseActive); XCTAssertNil(f.model.automaticPauseUntil) }
        XCTAssertEqual(f.controller.status, before)
        XCTAssertEqual(f.defaults.data(forKey: UserSessionController.preferenceKey), saved)
        XCTAssertEqual(f.controller.manualRequestID, id)
        XCTAssertEqual(f.controller.status.manualContinuousDeadline, deadline)
        XCTAssertEqual(f.backend.creates, creates); XCTAssertEqual(f.display.creates, displayCreates)
    }

    func testUnsupportedPauseDurationDoesNotChangeSavedChoicesOrRequest() throws {
        let f = try fixture(); defer { _ = f.controller.end() }
        let before = f.controller.status
        let saved = f.defaults.data(forKey: UserSessionController.preferenceKey)
        let creates = f.backend.creates
        for duration in [0, -1, 60, 1799, 3601, Double.infinity, Double.nan] {
            XCTAssertFalse(f.model.pauseAutomatic(for: duration))
        }
        XCTAssertEqual(f.controller.status, before)
        XCTAssertEqual(f.defaults.data(forKey: UserSessionController.preferenceKey), saved)
        XCTAssertEqual(f.backend.creates, creates)
        XCTAssertFalse(f.model.automaticPauseActive)
        f.model.setAutomaticEnabled(false)
        XCTAssertFalse(f.model.pauseAutomatic(for: 1800))
        XCTAssertFalse(f.model.automaticEnabled)
    }
}
