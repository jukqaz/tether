import Foundation
import XCTest
import TetherCore
@testable import Tether

private final class ManualExtensionDefaults: UserDefaults {
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
    override func persistentDomain(forName name: String) -> [String: Any]? { values }
    override func setPersistentDomain(_ domain: [String: Any], forName name: String) { values = domain }
    override func removePersistentDomain(forName name: String) { values.removeAll() }
}

private final class ManualExtensionAssertion: IdleAssertionBackend {
    var creates = 0
    var renews = 0
    var releases = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (0, 61) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { renews += 1; return 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { releases += 1; return 0 }
}

/// Shipping presentation with the real controller/policy and fake executors.
/// Reading a reason must never extend, replace, release or persist a request.
final class ManualExtensionAvailabilityTests: XCTestCase {
    func testAllowedTimedExtensionsHaveNoBlockedReasonIncludingAutomaticOnlyPause() async throws {
        try await MainActor.run {
            for power in [PowerSource.ac, .battery] {
                let (model, controller, backend) = try fixture(power: power)
                defer { _ = controller.end() }
                model.startManualSession(minutes: 30)
                let controls = ManualSessionControls(model: model, clock: model.clock)
                XCTAssertTrue(controls.showsTimedExtension)
                XCTAssertTrue(controller.canExtendManual(by: 30))
                XCTAssertTrue(model.canExtendManual(by: 30))
                XCTAssertNil(model.manualExtensionUnavailableReason(by: 30))
                let before = controller.status
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                let creates = backend.creates
                XCTAssertTrue(model.pauseAutomatic(for: 15 * 60))
                XCTAssertTrue(model.automaticPauseActive)
                XCTAssertTrue(model.canExtendManual(by: 30), "Automatic-only rest must not block manual extension")
                for _ in 0..<3 { XCTAssertNil(model.manualExtensionUnavailableReason(by: 30)) }
                XCTAssertEqual(controller.manualRequestID, before.manualRequestID)
                XCTAssertEqual(controller.status.manualContinuousDeadline, before.manualContinuousDeadline)
                XCTAssertEqual(controller.status.manualStartedAt, before.manualStartedAt)
                XCTAssertEqual(backend.creates, creates)
                XCTAssertNotEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved,
                    "Only the explicit automatic-pause operation saves new intent")
            }
        }
    }

    func testBatteryLimitReasonUsesCapturedRequestEvenAfterDefaultChangesToUnlimited() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .korean
            let (model, controller, backend) = try fixture(power: .battery)
            defer { _ = controller.end() }
            model.setBatteryTimeLimit(.oneHour)
            model.startManualSession(minutes: 60)
            XCTAssertEqual(controller.v4ManualSnapshot?.batteryTimeLimit, .oneHour)
            XCTAssertTrue(ManualSessionControls(model: model, clock: model.clock).showsTimedExtension)
            let initial = try assertReadOnlyBlockedReason(model, controller, backend)
            XCTAssertTrue(initial.contains("배터리 한도"))
            XCTAssertTrue(initial.contains("30분"))

            model.setBatteryTimeLimit(.unlimited)
            XCTAssertEqual(model.v3Settings.batteryTimeLimit, .unlimited)
            XCTAssertEqual(controller.v4ManualSnapshot?.batteryTimeLimit, .oneHour)
            XCTAssertEqual(try assertReadOnlyBlockedReason(model, controller, backend), initial,
                "A new unlimited default cannot relabel the current request's captured limit")
        }
    }

    func testUnlimitedCapturedBatteryLimitDoesNotInventAFiniteExtensionCap() async throws {
        try await MainActor.run {
            let (model, controller, backend) = try fixture(power: .battery)
            defer { _ = controller.end() }
            model.setBatteryTimeLimit(.unlimited)
            model.startManualSession(minutes: 120)
            let before = controller.status
            model.setBatteryTimeLimit(.thirtyMinutes)
            XCTAssertEqual(controller.v4ManualSnapshot?.batteryTimeLimit, .unlimited)
            XCTAssertTrue(controller.canExtendManual(by: 30))
            XCTAssertTrue(model.canExtendManual(by: 30))
            let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
            let creates = backend.creates
            for _ in 0..<3 { XCTAssertNil(model.manualExtensionUnavailableReason(by: 30)) }
            XCTAssertEqual(controller.manualRequestID, before.manualRequestID)
            XCTAssertEqual(controller.status.manualContinuousDeadline, before.manualContinuousDeadline)
            XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
            XCTAssertEqual(backend.creates, creates)
        }
    }

    func testUnknownAndLimitedObservationsExplainBlockedExtensionWithoutRetiming() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .korean
            let scenarios: [(PowerSource, Int?, Bool?, String)] = [
                (.unknown, 0, true, "전원 상태"),
                (.ac, nil, true, "전원·보호 관측"),
                (.ac, 0, nil, "전원·보호 관측")
            ]
            for (power, thermal, fullWake, expected) in scenarios {
                let (model, controller, backend) = try fixture(power: .ac)
                defer { _ = controller.end() }
                model.startManualSession(minutes: 30)
                let request = controller.manualRequestID
                let deadline = controller.status.manualContinuousDeadline
                controller.update(power: power, thermal: thermal, fullWake: fullWake, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
                XCTAssertTrue(model.manualSessionActive, "Unconfirmed observations do not create a new request")
                XCTAssertTrue(ManualSessionControls(model: model, clock: model.clock).showsTimedExtension)
                XCTAssertTrue(try assertReadOnlyBlockedReason(model, controller, backend).contains(expected))
                XCTAssertEqual(controller.manualRequestID, request)
                XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            }
        }
    }

    func testPendingApprovalAndPreparedExtensionShareTheWaitingReason() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .korean
            let (model, controller, backend) = try fixture(power: .ac)
            defer { _ = controller.end() }
            model.startManualSession(minutes: 30)
            let request = controller.manualRequestID
            let deadline = controller.status.manualContinuousDeadline
            model.v4ManualApprovalPending = true
            XCTAssertTrue(controller.canExtendManual(by: 30), "The app approval gate is independent of the core policy")
            let approvalReason = try assertReadOnlyBlockedReason(model, controller, backend)
            XCTAssertTrue(approvalReason.contains("승인·연장"))
            model.v4ManualApprovalPending = false
            XCTAssertNil(model.manualExtensionUnavailableReason(by: 30))

            XCTAssertTrue(controller.prepareManualExtension(minutes: 30))
            XCTAssertTrue(controller.manualExtensionPending)
            XCTAssertEqual(try assertReadOnlyBlockedReason(model, controller, backend), approvalReason)
            XCTAssertEqual(controller.manualRequestID, request)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline,
                "Presenting a preparation must not commit its proposed deadline")
            controller.cancelManualExtension()
            XCTAssertFalse(controller.manualExtensionPending)
            XCTAssertNil(model.manualExtensionUnavailableReason(by: 30))
            XCTAssertEqual(controller.manualRequestID, request)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
        }
    }

    func testProtectionAndWholePauseUseObservedReasonsAndRemoveEndedTimerControls() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .korean
            for protect in [true, false] {
                let (model, controller, backend) = try fixture(power: .ac)
                defer { _ = controller.end() }
                model.startManualSession(minutes: 30)
                if protect {
                    controller.update(power: .ac, thermal: 2, fullWake: true, controllingUser: true,
                        now: ContinuousTime.now, batteryPercent: 80)
                    XCTAssertEqual(model.workProtectionReason, "thermal")
                    XCTAssertEqual(try assertReadOnlyBlockedReason(model, controller, backend), protectionReason("thermal"))
                } else {
                    model.setEnabled(false)
                    XCTAssertTrue(model.workPaused)
                    XCTAssertTrue(try assertReadOnlyBlockedReason(model, controller, backend).contains("중지"))
                }
                XCTAssertFalse(model.manualSessionActive)
                XCTAssertFalse(ManualSessionControls(model: model, clock: model.clock).showsTimedExtension)
            }
        }
    }

    func testUnconfirmedSessionAuthorityDoesNotGuessABatteryOrTimerLimit() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .korean
            let (model, controller, backend) = try fixture(power: .ac)
            defer { controller.ownershipProbe = { true }; _ = controller.end() }
            model.startManualSession(minutes: 30)
            controller.ownershipProbe = { false }
            XCTAssertFalse(controller.hasConfirmedSessionAuthority)
            let reason = try assertReadOnlyBlockedReason(model, controller, backend)
            XCTAssertTrue(reason.contains("로그인 세션·깨움 상태"))
            XCTAssertFalse(reason.contains("배터리 한도"))
        }
    }

    func testClosedLidHelperGateExplainsItsOwnExtensionBlock() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .korean
            let (model, controller, backend) = try fixture(power: .ac)
            defer { _ = controller.end() }
            model.startManualSession(minutes: 30)
            model.setAllowClosedLid(true)
            XCTAssertTrue(model.manualFeaturesNeedHelper)
            XCTAssertTrue(controller.canExtendManual(by: 30))
            XCTAssertFalse(model.canAcquireManualFeatures)
            XCTAssertTrue(try assertReadOnlyBlockedReason(model, controller, backend).contains("덮개 도우미"))
        }
    }

    func testUntimedManualWorkNeverShowsAnExtensionControl() async throws {
        try await MainActor.run {
            for power in [PowerSource.ac, .battery] {
                let (model, controller, backend) = try fixture(power: power)
                defer { _ = controller.end() }
                model.setBatteryTimeLimit(.unlimited)
                model.startUntimedSession()
                XCTAssertTrue(model.manualSessionActive)
                XCTAssertNil(model.manualSessionUntil)
                XCTAssertFalse(ManualSessionControls(model: model, clock: model.clock).showsTimedExtension)
                _ = try assertReadOnlyBlockedReason(model, controller, backend)
            }
        }
    }

    func testStaleObservationGateUsesConservativeFallbackWithoutInventingANumericCap() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .korean
            let observedAt = ContinuousTime.now - 20
            let (model, controller, backend) = try fixture(power: .ac, observedAt: observedAt)
            defer { _ = controller.end() }
            XCTAssertTrue(controller.start(duration: 30 * 60, now: observedAt))
            XCTAssertTrue(model.manualSessionActive)
            XCTAssertEqual(controller.status.observationLimited, false,
                "This snapshot predates the current freshness failure")
            XCTAssertTrue(controller.hasConfirmedSessionAuthority)
            XCTAssertTrue(try assertReadOnlyBlockedReason(model, controller, backend).contains("기한·전원·보호 상태"))
        }
    }

    @MainActor
    private func assertReadOnlyBlockedReason(_ model: AppModel, _ controller: UserSessionController,
                                             _ backend: ManualExtensionAssertion,
                                             file: StaticString = #filePath, line: UInt = #line) throws -> String {
        XCTAssertFalse(model.canExtendManual(by: 30), file: file, line: line)
        let status = controller.status
        let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
        let creates = backend.creates, renews = backend.renews, releases = backend.releases
        let reason = try XCTUnwrap(model.manualExtensionUnavailableReason(by: 30), file: file, line: line)
        XCTAssertFalse(reason.isEmpty, file: file, line: line)
        for _ in 0..<3 { XCTAssertEqual(model.manualExtensionUnavailableReason(by: 30), reason, file: file, line: line) }
        XCTAssertEqual(controller.status, status, file: file, line: line)
        XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved, file: file, line: line)
        XCTAssertEqual(backend.creates, creates, file: file, line: line)
        XCTAssertEqual(backend.renews, renews, file: file, line: line)
        XCTAssertEqual(backend.releases, releases, file: file, line: line)
        return reason
    }

    @MainActor
    private func fixture(power: PowerSource, observedAt: Double = ContinuousTime.now) throws
        -> (AppModel, UserSessionController, ManualExtensionAssertion) {
        let defaults = ManualExtensionDefaults(), backend = ManualExtensionAssertion()
        var settings = IdleSessionSettings()
        settings.automaticEnabled = false
        settings.legacyRootConfigurationPending = false
        defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
        let controller = UserSessionController(defaults: defaults, backend: backend,
            displayBackend: ManualExtensionAssertion(), guiProbe: nil, environmentProbe: nil, boot: "extension-fixture")
        controller.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
            now: observedAt, batteryPercent: 80)
        let model = AppModel(preview: true,
            capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller, previewDefaults: defaults)
        return (model, controller, backend)
    }
}
