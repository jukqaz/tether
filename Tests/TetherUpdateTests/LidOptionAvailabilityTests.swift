import SwiftUI
import XCTest
import TetherCore
@testable import Tether

private final class C1LidDefaults: UserDefaults {
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

private final class C1LidAssertion: IdleAssertionBackend {
    var creates = 0
    var releases = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (0, 31) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { releases += 1; return 0 }
}

@MainActor
private final class C1LidFixture {
    enum HelperState: CaseIterable { case missing, down, outdated, ready }
    let defaults = C1LidDefaults()
    let backend = C1LidAssertion()
    let controller: UserSessionController
    let model: AppModel

    init(selected: Bool, helper: HelperState) throws {
        var settings = IdleSessionSettings()
        settings.enabled = false
        settings.automaticEnabled = false
        settings.allowClosedLid = selected
        settings.runtimeMarkers = RuntimeMarkers()
        settings.runtimeMarkers?.pauseReason = .userStop
        defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
        controller = UserSessionController(defaults: defaults, backend: backend,
            displayBackend: C1LidAssertion(), guiProbe: nil, environmentProbe: nil, boot: "c1-lid-option")
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                          now: ContinuousTime.now, batteryPercent: 80)
        let capabilities = MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true)
        if helper == .missing {
            model = AppModel(preview: true, capabilities: capabilities,
                previewSession: controller, previewDefaults: defaults)
        } else {
            var status = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
                enabled: false, power: .ac, lidClosed: false, sleepDisabled: false,
                lastEvent: nil, lastEventAt: nil, thermal: 0)
            status.build = helper == .outdated ? TetherPaths.build - 1 : TetherPaths.build
            status.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
            status.systemPowerObservationAvailable = true
            var control = Control(); control.schemaVersion = Control.currentSchema
            var reply = ServiceReply(id: UUID(), ok: true, epoch: "c1-lid-option", revision: 1,
                control: control, protection: .init(reason: nil, error: nil, dryRun: true))
            reply.status = helper == .down ? nil : status
            let observation = reply
            model = AppModel(preview: true, capabilities: capabilities, previewSession: controller,
                previewWorkService: { _ in observation }, previewHelperReply: observation,
                previewDefaults: defaults, previewHelperFiles: { [] })
        }
    }

    func close() { _ = controller.end() }
}

/// Shared menu/settings guards and real bindings, with memory-only preferences
/// and assertions. No app, helper transport, installation or OS power operation.
final class LidOptionAvailabilityTests: XCTestCase {
    @MainActor
    private func controls(_ model: AppModel) -> [(String, Bool, Binding<Bool>)] {
        let menu = MenuKeepAwakeControls(model: model)
        let settings = GeneralPage(model: model)
        return [("menu", menu.lidControlDisabled, menu.lidBinding),
                ("settings", settings.lidControlDisabled, settings.lidBinding)]
    }

    @MainActor
    func testMissingDownAndOutdatedHelperCannotTrapASavedOnChoice() throws {
        for helper in [C1LidFixture.HelperState.missing, .down, .outdated] {
            for surface in ["menu", "settings"] {
                let fixture = try C1LidFixture(selected: true, helper: helper)
                defer { fixture.close() }
                let model = fixture.model, controller = fixture.controller
                XCTAssertFalse(model.helperSetupConfirmed, "\(helper)")
                if helper == .missing { XCTAssertFalse(model.helperInstalled) }
                if helper == .down { XCTAssertFalse(model.helperResponding) }
                if helper == .outdated { XCTAssertTrue(model.helperOutdated) }
                let markers = controller.runtimeMarkers
                let (name, disabled, binding) = try XCTUnwrap(controls(model).first { $0.0 == surface })
                XCTAssertFalse(disabled, "\(name): a saved permission can be revoked without a helper")
                binding.wrappedValue = false
                XCTAssertFalse(controller.settings.allowClosedLid, "\(helper) / \(name)")
                let saved = try JSONDecoder().decode(IdleSessionSettings.self,
                    from: XCTUnwrap(fixture.defaults.data(forKey: UserSessionController.preferenceKey)))
                XCTAssertFalse(saved.allowClosedLid, "Revocation must be persisted, not just rendered off")
                XCTAssertEqual(controller.runtimeMarkers, markers)
                XCTAssertTrue(model.workPaused)
                XCTAssertFalse(model.automaticEnabled)
                XCTAssertFalse(model.manualSessionActive)
                XCTAssertFalse(model.workSessionHolding)
                XCTAssertNil(controller.manualRequestID)
                XCTAssertEqual(fixture.backend.creates, 0)
                XCTAssertEqual(fixture.backend.releases, 0)
                XCTAssertTrue(controls(model).allSatisfy { $0.1 }, "The now-off option requires preparation to enable again")
            }
        }
    }

    @MainActor
    func testUnpreparedMenuAndSettingsBindingsCannotGrantPermission() throws {
        for helper in [C1LidFixture.HelperState.missing, .down, .outdated] {
            let fixture = try C1LidFixture(selected: false, helper: helper)
            defer { fixture.close() }
            let saved = fixture.defaults.data(forKey: UserSessionController.preferenceKey)
            let before = fixture.controller.status
            for (name, disabled, binding) in controls(fixture.model) {
                XCTAssertTrue(disabled, name)
                binding.wrappedValue = true
                XCTAssertFalse(fixture.controller.settings.allowClosedLid, name)
                XCTAssertEqual(fixture.defaults.data(forKey: UserSessionController.preferenceKey), saved, name)
                XCTAssertEqual(fixture.controller.status, before, name)
            }
            XCTAssertEqual(fixture.backend.creates, 0)
        }
    }

    @MainActor
    func testPreparedChoiceRemainsEditableWhileWorkIsStopped() throws {
        let fixture = try C1LidFixture(selected: false, helper: .ready)
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.helperSetupConfirmed)
        let markers = fixture.controller.runtimeMarkers
        for (name, disabled, binding) in controls(fixture.model) {
            XCTAssertFalse(disabled, name)
            for selected in [true, false] {
                binding.wrappedValue = selected
                XCTAssertEqual(fixture.controller.settings.allowClosedLid, selected, name)
                XCTAssertEqual(fixture.controller.runtimeMarkers, markers, name)
                XCTAssertTrue(fixture.model.workPaused)
                XCTAssertFalse(fixture.model.workSessionHolding)
            }
        }
        XCTAssertEqual(fixture.backend.creates, 0)
    }

    func testPendingCommandsUnavailableOwnershipAndDesktopBlockBothDirections() {
        let cases: [(String, Bool, Bool, Bool)] = [
            ("command pending", true, true, true),
            ("command ownership unavailable", true, false, false),
            ("desktop has no lid option", false, true, false)
        ]
        for (name, showsLidOptions, acceptingUserCommands, commandPending) in cases {
            for selected in [false, true] {
                for ready in [false, true] {
                    let availability = LidOptionAvailability(showsLidOptions: showsLidOptions,
                        acceptingUserCommands: acceptingUserCommands, commandPending: commandPending,
                        isSelected: selected, helperSetupConfirmed: ready)
                    XCTAssertTrue(availability.isDisabled, name)
                    XCTAssertFalse(availability.permits(false), name)
                    XCTAssertFalse(availability.permits(true), name)
                }
            }
        }
    }
}
