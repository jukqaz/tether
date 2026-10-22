import XCTest
@testable import Tether
import TetherCore

private final class GeneralSessionAssertionFixture: IdleAssertionBackend {
    var creates = 0
    var releases = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (0, 19) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { releases += 1; return 0 }
}

final class GeneralSessionRoutingTests: XCTestCase {
    func testIncompleteHardwareObservationsStillRunAndEndGeneralWorkThroughTheApp() async {
        await MainActor.run {
            for battery: Bool? in [true, false, nil] {
                for lid: Bool? in [true, false, nil] where battery != true || lid != true {
                    withFixture { defaults, backend in
                        let capabilities = MacCapabilities(supportedPlatform: true, internalBattery: battery, lid: lid)
                        let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil)
                        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                        let model = AppModel(preview: true, capabilities: capabilities, previewSession: controller)
                        XCTAssertTrue(model.supportedMac); XCTAssertTrue(model.usesUserSession)
                        XCTAssertTrue(model.manualSessionAvailable); XCTAssertTrue(model.canStartUnlimitedManualSession)
                        XCTAssertFalse(model.helperInstalled); XCTAssertFalse(model.clamshellActive)
                        XCTAssertNil(model.problem)
                        model.startUntimedSession()
                        XCTAssertTrue(model.manualSessionActive); XCTAssertTrue(model.workSessionHolding)
                        XCTAssertFalse(model.clamshellActive); XCTAssertEqual(backend.creates, 1)
                        model.endManualSession()
                        XCTAssertFalse(model.workSessionHolding); XCTAssertEqual(backend.releases, 1)
                        XCTAssertEqual(model.hasInternalBattery, battery == true)
                        if capabilities.hardware != .desktop {
                            XCTAssertNotEqual(model.deviceStatusSymbol, "desktopcomputer")
                            XCTAssertTrue(model.lidDetail.contains("macOS"))
                        }
                        XCTAssertTrue(controller.end())
                    }
                }
            }
        }
    }

    func testSupportedNotebookUsesGeneralWorkWithoutClaimingLidSupportAndUnsupportedDoesNot() async {
        await MainActor.run {
            for platform in [true, false] {
                withFixture { defaults, backend in
                    let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil)
                    let model = AppModel(preview: true,
                        capabilities: MacCapabilities(supportedPlatform: platform, internalBattery: true, lid: true),
                        previewSession: controller)
                    XCTAssertEqual(model.usesUserSession, platform)
                    XCTAssertEqual(model.manualSessionAvailable, platform)
                    XCTAssertFalse(model.workSessionHolding); XCTAssertEqual(backend.creates, 0)
                    XCTAssertEqual(model.supportedMac, platform)
                    XCTAssertTrue(controller.end())
                }
            }
        }
    }

    func testCurrentAutomaticOffProjectionDoesNotBecomeWholeStopAtAppStartup() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                var settings = IdleSessionSettings()
                settings.enabled = true; settings.automaticEnabled = false
                settings.legacyRootConfigurationPending = false
                defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
                var rootProjection = Control(); rootProjection.enabled = false; rootProjection.powerCondition = .ac
                let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil,
                    legacyControl: rootProjection, requiresRootHandoff: true)
                defer { _ = controller.end() }
                controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                let model = AppModel(preview: true,
                    capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
                    previewSession: controller)
                XCTAssertTrue(controller.settings.enabled); XCTAssertFalse(controller.settings.automaticEnabled)
                XCTAssertNil(controller.runtimeMarkers.pauseReason); XCTAssertFalse(model.workSessionHolding)
                model.startUntimedSession()
                XCTAssertTrue(model.manualSessionActive); XCTAssertTrue(model.workSessionHolding)
                XCTAssertFalse(model.clamshellActive); XCTAssertEqual(backend.creates, 1)
            }
        }
    }

    func testNotebookCapturedManualOptionAndAutomaticToggleStayIndependentThroughAppCommands() async {
        await MainActor.run {
            withFixture { defaults, backend in
                let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil)
                let base = ContinuousTime.now
                controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: base, batteryPercent: 80)
                let model = AppModel(preview: true,
                    capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
                    previewSession: controller)
                model.startBatteryHold(minutes: 180)
                XCTAssertNil(model.pendingHoldMinutes)
                XCTAssertFalse(model.workSessionHolding); XCTAssertFalse(model.manualSessionActive)
                model.setManualBatteryContinuationMinutes(120)
                model.startUntimedSession()
                XCTAssertTrue(model.workSessionHolding); XCTAssertTrue(model.manualSessionActive)
                XCTAssertNil(model.manualBatteryContinuationMinutes)
                model.setManualBatteryContinuationMinutes(30)
                XCTAssertNil(model.manualBatteryContinuationMinutes, "No unplug continuation exists in v4")
                model.setAutomaticEnabled(true); model.setAutomaticEnabled(false)
                XCTAssertTrue(model.manualSessionActive); XCTAssertTrue(model.workSessionHolding)
                controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: base + 1, batteryPercent: 80)
                XCTAssertEqual(model.manualMaximumMinutes, 120)
                XCTAssertFalse(model.manualSessionActive); XCTAssertFalse(model.clamshellActive)
                XCTAssertEqual(controller.status.manualEndReason, .powerDisconnected)
                let deadline = controller.status.manualContinuousDeadline
                model.extendBatteryHold(minutes: 15)
                XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
                XCTAssertFalse(model.canExtendHold(minutes: 15))
                model.cancelBatteryHold()
                XCTAssertFalse(model.manualSessionActive); XCTAssertFalse(model.workSessionHolding)
                XCTAssertNil(model.pendingHoldMinutes)
                XCTAssertTrue(controller.end())
            }
        }
    }

    func testBatteryFallbackPublishesAndEnforcesItsOwnLimitsWithoutTheHelper() async {
        await MainActor.run {
            withFixture { defaults, backend in
                var legacy = Control(); legacy.enabled = true; legacy.limits = UserLimits(batteryFloor: 40, maxHoldHours: 0.5)
                let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil,
                    legacyControl: legacy)
                controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 60)
                let model = AppModel(preview: true,
                    capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: nil),
                    previewSession: controller)
                XCTAssertTrue(model.hasInternalBattery); XCTAssertEqual(model.percentText, "60%")
                XCTAssertEqual(model.batteryFloor, 40); XCTAssertEqual(model.manualMaximumMinutes, 120)
                XCTAssertNil(controller.settings.limits?.maxHoldHours)
                XCTAssertFalse(model.canStartUnlimitedManualSession)
                model.setAllowClosedLid(false) // Request only the available general executor.
                model.startManualSession(minutes: 60)
                XCTAssertTrue(model.workSessionHolding)
                model.setLimits(UserLimits(batteryFloor: 70, maxHoldHours: 0.5))
                XCTAssertEqual(model.batteryFloor, 70); XCTAssertFalse(model.workSessionHolding)
                XCTAssertEqual(model.protection?.blockReason, "battery"); XCTAssertEqual(backend.releases, 1)
                XCTAssertEqual(model.userSessionStatus?.manualEndReason, .protection)
                XCTAssertTrue(controller.end())
            }
        }
    }

    func testMissingLiveBatteryReadingIsNotReplacedByAHostReadingOrPresentedAsClamshell() async {
        await MainActor.run {
            withFixture { defaults, backend in
                let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil)
                controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: nil)
                let model = AppModel(preview: true,
                    capabilities: MacCapabilities(supportedPlatform: true, internalBattery: nil, lid: nil),
                    previewSession: controller)
                XCTAssertTrue(model.manualSessionAvailable); XCTAssertFalse(model.canStartManualSession)
                XCTAssertNil(model.batteryPercent); XCTAssertEqual(model.percentText, "–")
                XCTAssertFalse(model.clamshellActive); XCTAssertEqual(model.deviceStatusSymbol, "display")
                model.startManualSession(minutes: 10)
                XCTAssertFalse(model.manualSessionActive); XCTAssertEqual(backend.creates, 0)
                XCTAssertTrue(controller.end())
            }
        }
    }

    @MainActor
    private func withFixture(_ body: (UserDefaults, GeneralSessionAssertionFixture) throws -> Void) rethrows {
        let suite = "tether-general-routing-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, GeneralSessionAssertionFixture())
    }
}
