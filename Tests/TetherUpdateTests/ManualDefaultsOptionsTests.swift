import Foundation
import XCTest
import TetherCore
@testable import Tether

private final class ManualDefaultsMemory: UserDefaults {
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
}

private final class ManualDefaultsAssertion: IdleAssertionBackend {
    var ids = Set<UInt32>()
    var creates = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        creates += 1
        let id = UInt32(creates); ids.insert(id)
        return (0, id)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { ids.contains(id) ? 0 : -1 }
    func level(id: UInt32) -> Int? { ids.contains(id) ? 255 : 0 }
    func release(id: UInt32) -> Int32 { ids.remove(id); return 0 }
}

/// The new defaults entry point with real policy/controller and memory-only
/// executors. These checks do not establish helper or physical display behavior.
final class ManualDefaultsOptionsTests: XCTestCase {
    func testApplyingDefaultsKeepsCurrentIdentityDeadlineAndCapturedOptionsUntilANewRequest() async throws {
        try await MainActor.run {
            let (model, controller, system, display) = try fixture()
            defer { _ = controller.end() }
            model.setKeepDisplayAwake(true)
            model.setAllowClosedLid(true)
            model.startManualSession(minutes: 30)
            XCTAssertTrue(model.manualSessionActive)
            let current = try XCTUnwrap(controller.v4ManualSnapshot)
            let deadline = controller.status.manualContinuousDeadline
            let options = V4RequestOptions(display: true, closedLid: true, releaseDisplayAfterIdle: 600)
            let creates = (system.creates, display.creates)

            _ = ManualDefaultsOptionsView(model: model)
            XCTAssertEqual(model.v4Settings.nextManualOptions, current.options,
                "Constructing the draft must not apply it")
            XCTAssertTrue(model.saveManualDefaultsOptions(options, expectedGeneration: model.v4Settings.generation))
            XCTAssertEqual(model.v4Settings.nextManualOptions, options)
            XCTAssertEqual(controller.v4ManualSnapshot?.options, current.options)
            XCTAssertEqual(controller.manualRequestID, current.requestID)
            XCTAssertEqual(controller.status.manualStartedAt, current.startedAt)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertFalse(controller.sessionDecision.displayRequired)
            XCTAssertFalse(controller.sessionDecision.closedLidRequired)
            XCTAssertEqual(system.creates, creates.0); XCTAssertEqual(display.creates, creates.1)

            controller.endManual()
            // Exercise common-policy capture with fake executors. This is not
            // a claim that an unprepared real lid helper accepted the request.
            XCTAssertTrue(controller.start(duration: 1800))
            XCTAssertNotEqual(controller.manualRequestID, current.requestID)
            XCTAssertEqual(controller.v4ManualSnapshot?.options, options)
            XCTAssertTrue(controller.sessionDecision.displayRequired)
            XCTAssertTrue(controller.sessionDecision.closedLidRequired)
        }
    }

    func testRequestDefaultsDoNotGrantGlobalDisplayOrLidPermissions() async throws {
        try await MainActor.run {
            let (model, controller, system, display) = try fixture()
            defer { _ = controller.end() }
            let requested = V4RequestOptions(display: true, closedLid: true, releaseDisplayAfterIdle: 300)
            XCTAssertFalse(model.v3Settings.keepDisplayAwake)
            XCTAssertFalse(model.v3Settings.allowClosedLid)
            XCTAssertTrue(model.saveManualDefaultsOptions(requested, expectedGeneration: model.v4Settings.generation))
            XCTAssertFalse(controller.status.manualActive, "Saving defaults must not start work")
            XCTAssertEqual(system.creates, 0); XCTAssertEqual(display.creates, 0)
            XCTAssertFalse(model.v3Settings.keepDisplayAwake)
            XCTAssertFalse(model.v3Settings.allowClosedLid)

            XCTAssertTrue(controller.start(duration: 1800))
            XCTAssertEqual(controller.v4ManualSnapshot?.options, requested)
            XCTAssertTrue(controller.status.holding)
            XCTAssertFalse(controller.sessionDecision.displayRequired)
            XCTAssertFalse(controller.sessionDecision.closedLidRequired)
            XCTAssertEqual(display.creates, 0)
        }
    }

    func testEverySupportedIdleChoiceReleasesOnlyTheDisplayAndPreservesTheTimer() async throws {
        try await MainActor.run {
            let choices: [Double?] = [nil, 300, 600, 900, 1800]
            for idleLimit in choices {
                let (model, controller, _, display) = try fixture(portable: false)
                defer { _ = controller.end() }
                model.setKeepDisplayAwake(true)
                let options = V4RequestOptions(display: true, closedLid: false, releaseDisplayAfterIdle: idleLimit)
                XCTAssertTrue(model.saveManualDefaultsOptions(options, expectedGeneration: model.v4Settings.generation))
                controller.idleSecondsProbe = { 0 }
                XCTAssertTrue(controller.start(duration: 1800))
                let request = controller.manualRequestID
                let deadline = controller.status.manualContinuousDeadline
                XCTAssertEqual(controller.status.displayHolding, true)
                XCTAssertFalse(display.ids.isEmpty)

                controller.idleSecondsProbe = { idleLimit.map { $0 + 1 } ?? 10_000 }
                controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: nil)
                XCTAssertEqual(controller.status.displayHolding, idleLimit == nil)
                XCTAssertEqual(display.ids.isEmpty, idleLimit != nil)
                XCTAssertTrue(controller.status.holding)
                XCTAssertEqual(controller.manualRequestID, request)
                XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            }
        }
    }

    func testStaleDraftAndInvalidIdleChoiceAreRejectedWithoutOverwritingCurrentWork() async throws {
        try await MainActor.run {
            let (model, controller, system, display) = try fixture()
            defer { _ = controller.end() }
            model.startManualSession(minutes: 30)
            let request = controller.manualRequestID
            let deadline = controller.status.manualContinuousDeadline
            let staleGeneration = model.v4Settings.generation
            model.setNotifyExpiryWarning(true)
            XCTAssertNotEqual(model.v4Settings.generation, staleGeneration)
            let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
            let before = model.v4Settings
            let creates = (system.creates, display.creates)
            XCTAssertFalse(model.saveManualDefaultsOptions(.init(display: true, closedLid: true),
                expectedGeneration: staleGeneration))
            XCTAssertEqual(model.v4Settings, before)
            XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)

            for invalid in [301.0, -1, .infinity, .nan] {
                XCTAssertFalse(model.saveManualDefaultsOptions(.init(display: true, closedLid: false,
                    releaseDisplayAfterIdle: invalid), expectedGeneration: model.v4Settings.generation))
                XCTAssertEqual(model.v4Settings, before)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
            }
            XCTAssertEqual(controller.manualRequestID, request)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertEqual(system.creates, creates.0); XCTAssertEqual(display.creates, creates.1)
        }
    }

    func testUnavailableLidControlPreservesItsSavedChoiceWhileOtherDefaultsRemainEditable() async throws {
        try await MainActor.run {
            let (model, controller, _, _) = try fixture(portable: false,
                initial: .init(display: false, closedLid: true))
            defer { _ = controller.end() }
            XCTAssertFalse(model.capabilities.lidControlAvailable)
            let preserved = V4RequestOptions(display: true, closedLid: true, releaseDisplayAfterIdle: 900)
            XCTAssertTrue(model.saveManualDefaultsOptions(preserved, expectedGeneration: model.v4Settings.generation))
            XCTAssertEqual(model.v4Settings.nextManualOptions, preserved)
            let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
            XCTAssertFalse(model.saveManualDefaultsOptions(.init(display: true, closedLid: false),
                expectedGeneration: model.v4Settings.generation))
            XCTAssertEqual(model.v4Settings.nextManualOptions, preserved)
            XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)

            let (unsupported, other, _, _) = try fixture(supported: false)
            defer { _ = other.end() }
            let original = unsupported.defaults.data(forKey: UserSessionController.preferenceKey)
            XCTAssertFalse(unsupported.saveManualDefaultsOptions(.init(display: true),
                expectedGeneration: unsupported.v4Settings.generation))
            XCTAssertEqual(unsupported.defaults.data(forKey: UserSessionController.preferenceKey), original)
            XCTAssertFalse(other.status.manualActive)
        }
    }

    @MainActor
    private func fixture(portable: Bool = true, supported: Bool = true,
                         initial: V4RequestOptions = .init(display: false, closedLid: false)) throws
        -> (AppModel, UserSessionController, ManualDefaultsAssertion, ManualDefaultsAssertion) {
        let defaults = ManualDefaultsMemory(), system = ManualDefaultsAssertion(), display = ManualDefaultsAssertion()
        var settings = IdleSessionSettings()
        settings.legacyRootConfigurationPending = false
        settings.automaticEnabled = false
        settings.v4.nextManualOptions = initial
        defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
        let controller = UserSessionController(defaults: defaults, backend: system, displayBackend: display,
            guiProbe: nil, environmentProbe: nil, boot: "manual-defaults-fixture")
        controller.idleSecondsProbe = { 0 }
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: portable ? 80 : nil)
        let model = AppModel(preview: true,
            capabilities: MacCapabilities(supportedPlatform: supported, internalBattery: portable, lid: portable),
            previewSession: controller, previewDefaults: defaults)
        return (model, controller, system, display)
    }
}
