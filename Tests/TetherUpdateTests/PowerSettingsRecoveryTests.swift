import AppKit
import SwiftUI
import XCTest
import TetherCore
@testable import Tether

/// Shipping presentation and bindings with isolated controllers and executors.
/// Native visibility and sidebar interaction are checked by the UI suite.
final class PowerSettingsRecoveryTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { _ = NSApplication.shared }
    }

    func testAutomaticEventTitleUsesTheSelectedModeAndPowerRangeInBothLanguages() async {
        await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                for condition in PowerCondition.allCases {
                    let fixture = PowerSettingsFixture(power: condition == .battery ? .battery : .ac)
                    defer { fixture.close() }
                    fixture.model.setPowerCondition(condition)
                    XCTAssertEqual(fixture.model.v3Settings.condition, condition)
                    let page = SafetyPage(model: fixture.model)
                    XCTAssertEqual(page.automaticEventTitle, L("Power connected", "전원 연결"),
                        "A saved advanced range cannot change basic AC-only presentation")

                    var advanced = fixture.controller.v4Settings
                    let preset = V4Preset(id: UUID(), name: "Selected conditions", groups: [
                        V4RuleGroup(id: UUID(), conditions: [
                            V4Condition(id: UUID(), kind: .appRunning, target: "fixture.editor")
                        ])
                    ])
                    advanced.automaticMode = .advanced
                    advanced.presets = [preset]; advanced.activePresetID = preset.id
                    fixture.controller.v4ConditionSource.queryOverride = { _, _ in (.satisfied, nil) }
                    XCTAssertTrue(fixture.controller.setV4Settings(advanced))
                    let saved = fixture.defaults.data(forKey: UserSessionController.preferenceKey)
                    let status = fixture.controller.status
                    XCTAssertEqual(page.automaticEventTitle, condition.title)
                    XCTAssertEqual(fixture.controller.status, status)
                    XCTAssertEqual(fixture.defaults.data(forKey: UserSessionController.preferenceKey), saved)
                    XCTAssertEqual(fixture.assertion.creates, 0,
                        "Reading the settings event cannot start automatic work")

                    fixture.model.setAutomaticEnabled(true)
                    fixture.controller.update(power: condition == .battery ? .battery : .ac,
                        thermal: 0, fullWake: true, controllingUser: true,
                        now: ContinuousTime.now, batteryPercent: 80)
                    XCTAssertTrue(fixture.model.automaticWorkReasonActive)
                    XCTAssertEqual(fixture.controller.runtimeMarkers.automaticActivation?.condition, condition)
                    let next: PowerCondition = condition == .battery ? .ac : .battery
                    fixture.model.setPowerCondition(next)
                    let activeStatus = fixture.controller.status
                    let creates = fixture.assertion.creates
                    XCTAssertEqual(fixture.controller.runtimeMarkers.automaticActivation?.condition, condition)
                    XCTAssertEqual(page.automaticEventTitle, next.title,
                        "Settings describe the saved range, separately from an active request's captured range")
                    XCTAssertEqual(fixture.controller.status, activeStatus)
                    XCTAssertEqual(fixture.assertion.creates, creates)
                }
            }
        }
    }

    func testBrightnessRecoveryStaysVisibleAfterCapabilityLossWithoutAuthorizingNewLidUse() async {
        await MainActor.run {
            let brightness = PowerSettingsBrightness()
            let journal = PowerSettingsJournal(record: .init(target: brightness.target, original: 0.8, phase: .applied))
            let driver = ClosedLidDisplayDriver(backend: brightness, journal: journal)
            let fixture = PowerSettingsFixture(driver: driver)
            defer { fixture.close() }
            let page = SafetyPage(model: fixture.model)
            XCTAssertTrue(fixture.model.showsLidOptions)
            XCTAssertTrue(fixture.model.closedLidDisplayRecoveryPending)
            XCTAssertTrue(page.showsClosedLidStatus)

            fixture.observation.value = .init(supportedPlatform: true, internalBattery: nil, lid: nil)
            fixture.model.refresh()
            XCTAssertFalse(fixture.model.showsLidOptions)
            XCTAssertTrue(page.showsClosedLidStatus,
                "Missing capabilities hide new feature controls, never an existing recovery")
            let saved = fixture.defaults.data(forKey: UserSessionController.preferenceKey)
            let status = fixture.controller.status
            let general = GeneralPage(model: fixture.model)
            XCTAssertTrue(general.lidControlDisabled)
            general.lidBinding.wrappedValue = true
            fixture.model.setClosedLidDisplayMode(.unchanged)
            XCTAssertFalse(fixture.model.v3Settings.allowClosedLid)
            XCTAssertEqual(fixture.model.v3Settings.closedLidDisplayMode, .off,
                "Recovery authority cannot authorize a new display-mode selection")
            XCTAssertEqual(fixture.controller.status, status)
            XCTAssertEqual(fixture.defaults.data(forKey: UserSessionController.preferenceKey), saved)

            brightness.readUnavailable = false
            fixture.model.retryClosedLidDisplayRecovery()
            XCTAssertEqual(brightness.writes, [0.8])
            XCTAssertNil(journal.record)
            XCTAssertFalse(fixture.model.closedLidDisplayRecoveryPending)
            XCTAssertFalse(page.showsClosedLidStatus)
            XCTAssertEqual(fixture.assertion.creates, 0)
            XCTAssertEqual(fixture.defaults.data(forKey: UserSessionController.preferenceKey), saved)
        }
    }

    func testPendingLidReleaseRemainsVisibleAfterCapabilityLossWhileNormalDesktopStaysHidden() async {
        await MainActor.run {
            let fixture = PowerSettingsFixture(attachedHelper: true)
            defer { fixture.close() }
            XCTAssertTrue(fixture.model.showsLidOptions)
            fixture.observation.value = .init(supportedPlatform: true, internalBattery: true, lid: nil)
            fixture.model.refresh()
            XCTAssertTrue(fixture.model.lidReleasePending)
            XCTAssertFalse(fixture.model.showsLidOptions)
            XCTAssertTrue(SafetyPage(model: fixture.model).showsClosedLidStatus)
            XCTAssertTrue(GeneralPage(model: fixture.model).lidControlDisabled)

            let desktop = PowerSettingsFixture(capabilities: .init(supportedPlatform: true, internalBattery: false, lid: false))
            defer { desktop.close() }
            XCTAssertFalse(desktop.model.showsLidOptions)
            XCTAssertFalse(SafetyPage(model: desktop.model).showsClosedLidStatus,
                "A desktop without recovery debt must not gain closed-lid UI")
        }
    }

    func testUnplugDisclosureUsesWindowOwnedStateAcrossPageRecreation() async {
        await MainActor.run {
            let fixture = PowerSettingsFixture()
            defer { fixture.close() }
            for expandedDetails in [false, true] {
                var window = SettingsDisclosureState(expanded: expandedDetails)
                let initialClosedLidDisplay = window.closedLidDisplay
                let binding = Binding(get: { window }, set: { window = $0 })
                let initial = SafetyPage(model: fixture.model, disclosures: binding)
                XCTAssertTrue(initial.unplugExpansion.wrappedValue,
                    "The unplug policy starts open in both normal and expanded previews")
                initial.unplugExpansion.wrappedValue = false
                fixture.model.settingsPage = .general
                let recreated = SafetyPage(model: fixture.model, disclosures: binding)
                fixture.model.settingsPage = .safety
                XCTAssertFalse(recreated.unplugExpansion.wrappedValue)
                recreated.unplugExpansion.wrappedValue = true
                XCTAssertTrue(window.powerDisconnect)
                XCTAssertEqual(window.closedLidDisplay, initialClosedLidDisplay,
                    "The unplug binding cannot overwrite another disclosure")
            }
            XCTAssertEqual(fixture.assertion.creates, 0)
            XCTAssertFalse(fixture.controller.status.manualActive)
            XCTAssertFalse(fixture.controller.status.automaticActive)
        }
    }
}

private final class PowerSettingsAssertion: IdleAssertionBackend {
    var creates = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (0, 42) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { 0 }
}

private final class PowerSettingsObservation {
    var value: MacCapabilities
    init(_ value: MacCapabilities) { self.value = value }
}

@MainActor
private final class PowerSettingsFixture {
    let defaults = PreviewDefaults()
    let assertion = PowerSettingsAssertion()
    let observation: PowerSettingsObservation
    let controller: UserSessionController
    let model: AppModel

    init(power: PowerSource = .ac,
         capabilities: MacCapabilities = .init(supportedPlatform: true, internalBattery: true, lid: true),
         driver: ClosedLidDisplayDriver? = nil, attachedHelper: Bool = false) {
        let observation = PowerSettingsObservation(capabilities)
        self.observation = observation
        controller = UserSessionController(defaults: defaults, backend: assertion, displayBackend: PowerSettingsAssertion(),
            guiProbe: nil, environmentProbe: nil, boot: "power-settings-recovery")
        controller.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        var reply: ServiceReply?
        if attachedHelper {
            var status = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
                enabled: false, power: .ac, lidClosed: false, sleepDisabled: true,
                lastEvent: nil, lastEventAt: nil, thermal: 0)
            status.build = TetherPaths.build; status.appPID = getpid()
            status.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
            var value = ServiceReply(id: UUID(), ok: true, epoch: "power-settings-recovery", revision: 1,
                control: Control(), protection: .init(reason: nil, error: nil, dryRun: true))
            value.status = status; reply = value
        }
        model = AppModel(preview: true, capabilities: capabilities, previewSession: controller,
            previewWorkService: { _ in throw ServiceFailure("power-settings-recovery-isolated") },
            previewHelperReply: reply, previewDefaults: defaults, previewCapabilitiesProbe: { observation.value },
            previewHelperFiles: { [] }, previewClosedLidDisplayDriver: driver)
    }

    func close() { _ = controller.end(); model.finishSessionFeatures() }
}

private final class PowerSettingsBrightness: ClosedLidDisplayBrightnessBackend {
    let target = ClosedLidDisplayTarget(id: 123, vendor: 456, model: 789)
    var readUnavailable = true
    var value: Float = 0
    var writes: [Float] = []
    var support: ClosedLidDisplaySupport { .init(availability: .candidateRequiresPhysicalValidation, target: target) }
    func read(target: ClosedLidDisplayTarget) -> Float? { readUnavailable ? nil : value }
    func write(_ brightness: Float, target: ClosedLidDisplayTarget) -> Bool {
        writes.append(brightness); value = brightness; return true
    }
}

private final class PowerSettingsJournal: ClosedLidDisplayRecoveryJournaling {
    var record: ClosedLidDisplayRecoveryRecord?
    init(record: ClosedLidDisplayRecoveryRecord?) { self.record = record }
    func load() throws -> ClosedLidDisplayRecoveryRecord? { record }
    func save(_ record: ClosedLidDisplayRecoveryRecord) throws { self.record = record }
    func remove() throws { record = nil }
}
