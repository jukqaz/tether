import Foundation
import SwiftUI
import XCTest
import TetherCore
@testable import Tether

private final class ManualDurationDefaults: UserDefaults {
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

private final class ManualDurationAssertion: IdleAssertionBackend {
    var creates = 0
    var releases = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (0, 59) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { releases += 1; return 0 }
}

/// The shipping Picker's item source and selection binding with the real model
/// and policy, memory-only defaults and fake assertion executors. No native UI.
final class ManualDurationAvailabilityTests: XCTestCase {
    func testUntimedSelectionHasAPickerTagOnACAndExplicitlyUnlimitedBattery() async throws {
        try await MainActor.run {
            let scenarios: [(PowerSource, WorkSessionBatteryLimit)] = [
                (.ac, .thirtyMinutes), (.ac, .unlimited), (.battery, .unlimited)
            ]
            for (power, limit) in scenarios {
                let (model, controller, backend) = fixture(power: power)
                defer { _ = controller.end() }
                model.setBatteryTimeLimit(limit)
                let picker = ManualDurationPicker(model: model)
                let creates = backend.creates
                XCTAssertTrue(model.canStartUnlimitedManualSession)
                XCTAssertFalse(picker.controlsDisabled)
                XCTAssertEqual(picker.durationChoices.filter { $0 == 0 }.count, 1,
                    "An allowed untimed choice needs exactly one real Picker tag")

                picker.durationSelection.wrappedValue = 0
                XCTAssertEqual(model.selectedManualMinutes, 0)
                XCTAssertEqual(picker.durationSelection.wrappedValue, 0)
                XCTAssertTrue(picker.durationChoices.contains(picker.durationSelection.wrappedValue),
                    "The selected untimed value must be represented by the actual Picker item source")
                XCTAssertNil(controller.settings.lastManualDurationSeconds)
                XCTAssertFalse(model.manualSessionActive, "Choosing unlimited must not start work")
                XCTAssertEqual(backend.creates, creates)

                model.startUntimedSession()
                XCTAssertTrue(model.manualSessionActive)
                XCTAssertNil(model.manualSessionUntil)
                XCTAssertTrue(picker.controlsDisabled, "A running request owns its existing duration")
                XCTAssertTrue(picker.durationChoices.contains(picker.durationSelection.wrappedValue))
            }
        }
    }

    func testFiniteBatteryLimitsRemoveUntimedAfterUnplugAndRejectAStaleMenuItem() async throws {
        try await MainActor.run {
            for limit in [WorkSessionBatteryLimit.thirtyMinutes, .oneHour, .twoHours, .fourHours] {
                let (model, controller, backend) = fixture(power: .ac)
                defer { _ = controller.end() }
                model.setBatteryTimeLimit(limit)
                let picker = ManualDurationPicker(model: model)
                XCTAssertTrue(picker.durationChoices.contains(0))
                picker.durationSelection.wrappedValue = 0
                XCTAssertNil(controller.settings.lastManualDurationSeconds)

                controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
                let maximum = Int(try XCTUnwrap(limit.seconds) / 60)
                XCTAssertFalse(model.canStartUnlimitedManualSession)
                XCTAssertFalse(picker.controlsDisabled)
                XCTAssertEqual(picker.durationSelection.wrappedValue, min(120, maximum))
                XCTAssertTrue(picker.durationChoices.contains(picker.durationSelection.wrappedValue))
                XCTAssertFalse(picker.durationChoices.contains(0))
                XCTAssertTrue(picker.durationChoices.allSatisfy { (1...maximum).contains($0) })
                XCTAssertNil(controller.settings.lastManualDurationSeconds,
                    "Representing the finite battery fallback must preserve the saved AC default")

                picker.durationSelection.wrappedValue = min(60, maximum)
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                let creates = backend.creates
                let selected = picker.durationSelection.wrappedValue
                // This is the same binding held by a menu opened before unplug.
                picker.durationSelection.wrappedValue = 0
                XCTAssertEqual(picker.durationSelection.wrappedValue, selected)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved,
                    "A stale untimed item must not overwrite the available finite choice")
                XCTAssertFalse(model.manualSessionActive)
                XCTAssertEqual(backend.creates, creates)
                XCTAssertFalse(controller.start(duration: nil), "Finite battery policy must still reject untimed work")
                XCTAssertEqual(backend.creates, creates)
            }
        }
    }

    func testBatteryLimitDowngradeRemovesUntimedTagAndKeepsSelectionRepresentable() async throws {
        try await MainActor.run {
            let (model, controller, backend) = fixture(power: .battery)
            defer { _ = controller.end() }
            model.setBatteryTimeLimit(.unlimited)
            let picker = ManualDurationPicker(model: model)
            picker.durationSelection.wrappedValue = 0
            XCTAssertEqual(picker.durationSelection.wrappedValue, 0)
            XCTAssertTrue(picker.durationChoices.contains(0))
            let creates = backend.creates

            model.setBatteryTimeLimit(.thirtyMinutes)
            XCTAssertEqual(picker.durationSelection.wrappedValue, 30)
            XCTAssertEqual(picker.durationChoices, [30])
            XCTAssertFalse(model.canStartUnlimitedManualSession)
            XCTAssertNil(controller.settings.lastManualDurationSeconds,
                "Changing the displayable choice must not rewrite the saved duration")
            XCTAssertFalse(model.manualSessionActive)
            XCTAssertEqual(backend.creates, creates)
        }
    }

    func testUnknownPowerShowsItsSavedSelectionButCannotAcceptANewChoiceOrStart() async throws {
        try await MainActor.run {
            for limit in [WorkSessionBatteryLimit.twoHours, .unlimited] {
                let (model, controller, backend) = fixture(power: .ac)
                defer { _ = controller.end() }
                model.setBatteryTimeLimit(limit)
                let picker = ManualDurationPicker(model: model)
                picker.durationSelection.wrappedValue = 0
                controller.update(power: .unknown, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
                let selected = limit == .unlimited ? 0 : 120
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                let creates = backend.creates
                XCTAssertEqual(picker.durationSelection.wrappedValue, selected)
                XCTAssertTrue(picker.durationChoices.contains(selected),
                    "Unknown power must not leave the disabled Picker without its selected tag")
                XCTAssertEqual(picker.durationChoices.contains(0), limit == .unlimited)
                XCTAssertTrue(picker.controlsDisabled)
                XCTAssertFalse(model.canStartManualSession)
                XCTAssertFalse(model.canStartUnlimitedManualSession)

                picker.durationSelection.wrappedValue = 30
                XCTAssertEqual(picker.durationSelection.wrappedValue, selected)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
                XCTAssertFalse(controller.start(duration: nil))
                XCTAssertFalse(model.manualSessionActive)
                XCTAssertEqual(backend.creates, creates)
            }
        }
    }

    func testSavedFiniteDurationRemainsAnItemOnFiniteAndUnlimitedBattery() async throws {
        try await MainActor.run {
            for limit in [WorkSessionBatteryLimit.oneHour, .unlimited] {
                let (model, controller, backend) = fixture(power: .battery)
                defer { _ = controller.end() }
                model.setBatteryTimeLimit(limit)
                model.selectManualDuration(45 * 60)
                let picker = ManualDurationPicker(model: model)
                let creates = backend.creates
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                let status = controller.status
                for _ in 0..<3 {
                    XCTAssertEqual(picker.durationSelection.wrappedValue, 45)
                    XCTAssertEqual(picker.durationChoices.filter { $0 == 45 }.count, 1)
                    XCTAssertTrue(picker.durationChoices.contains(picker.durationSelection.wrappedValue))
                    XCTAssertEqual(picker.durationChoices.contains(0), limit == .unlimited)
                    XCTAssertFalse(picker.controlsDisabled)
                }
                XCTAssertEqual(controller.status, status, "Reading Picker items must be side-effect free")
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
                XCTAssertFalse(model.manualSessionActive)
                XCTAssertEqual(backend.creates, creates)
            }
        }
    }

    func testCustomStartAndAbsoluteEndUseTheCommonPolicyAndRememberTheAcceptedFiniteDuration() async throws {
        try await MainActor.run {
            let (model, controller, backend) = fixture(power: .ac)
            defer { _ = controller.end() }
            let saved = controller.settings.lastManualDurationSeconds
            let before = backend.creates
            XCTAssertNotNil(model.manualStartSelectionDuration(.minutes(47)))
            XCTAssertEqual(backend.creates, before, "Reading a draft must not start work")
            XCTAssertEqual(controller.settings.lastManualDurationSeconds, saved)
            XCTAssertTrue(model.startManualSelection(.minutes(47)))
            let id = controller.manualRequestID
            XCTAssertTrue(model.manualSessionActive)
            XCTAssertEqual(controller.settings.lastManualDurationSeconds, 47 * 60, "Accepted finite starts keep the existing remember-last-duration behavior")
            XCTAssertFalse(model.startManualSelection(.minutes(60)), "A new draft must not replace current work")
            XCTAssertEqual(controller.manualRequestID, id)
            model.endManualSession()
            let now = Date()
            XCTAssertTrue(model.startManualSelection(.until(now.addingTimeInterval(1234.5)), now: now))
            XCTAssertEqual(model.manualSessionUntil!.timeIntervalSince(now), 1234.5, accuracy: 0.25)
        }
    }

    func testCustomStartRechecksAChangedPowerLimitAndExplicitAllStop() async throws {
        try await MainActor.run {
            let (model, controller, backend) = fixture(power: .ac)
            defer { _ = controller.end() }
            model.setBatteryTimeLimit(.thirtyMinutes)
            XCTAssertNotNil(model.manualStartSelectionDuration(.minutes(60)))
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            let creates = backend.creates
            XCTAssertFalse(model.startManualSelection(.minutes(60)))
            XCTAssertFalse(model.manualSessionActive)
            XCTAssertEqual(backend.creates, creates)
            model.setEnabled(false)
            XCTAssertFalse(model.startManualSelection(.minutes(15)))
            XCTAssertFalse(model.manualSessionActive)
        }
    }

    func testInjectedPreviewDoesNotInheritTheHostPhysicalLidState() async {
        await MainActor.run {
            let (model, controller, _) = fixture(power: .ac)
            defer { _ = controller.end() }
            XCTAssertEqual(model.snapshot.power, .ac)
            XCTAssertNil(model.snapshot.observedLidClosed,
                "An injected controller must not read this Mac's physical lid before binding")
            XCTAssertNil(model.snapshot.observedSleepDisabled)
            controller.setKeepDisplayAwake(true)
            XCTAssertTrue(controller.start(duration: 600))
            XCTAssertEqual(controller.status.displayHolding, true)
        }
    }

    @MainActor
    private func fixture(power: PowerSource) -> (AppModel, UserSessionController, ManualDurationAssertion) {
        let defaults = ManualDurationDefaults(), backend = ManualDurationAssertion()
        let controller = UserSessionController(defaults: defaults, backend: backend,
            displayBackend: ManualDurationAssertion(), guiProbe: nil, environmentProbe: nil, boot: "duration-fixture")
        controller.setAutomatic(false)
        controller.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        let model = AppModel(preview: true,
            capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller, previewDefaults: defaults)
        return (model, controller, backend)
    }
}
