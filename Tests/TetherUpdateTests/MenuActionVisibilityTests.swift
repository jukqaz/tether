import Foundation
import XCTest
import TetherCore
@testable import Tether

private final class MenuVisibilityBackend: IdleAssertionBackend {
    private var ids: Set<UInt32> = []
    private var nextID: UInt32 = 1
    var releaseFails = false
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        let id = nextID; nextID += 1; ids.insert(id); return (0, id)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { ids.contains(id) ? 0 : -1 }
    func level(id: UInt32) -> Int? { ids.contains(id) ? 255 : 0 }
    func release(id: UInt32) -> Int32 {
        guard !releaseFails else { return -1 }
        ids.remove(id); return 0
    }
}

@MainActor
private final class MenuVisibilityFixture {
    let suite = "TetherMenuVisibility." + UUID().uuidString
    let defaults: UserDefaults
    let backend = MenuVisibilityBackend()
    let controller: UserSessionController
    let model: AppModel

    init(helperOutdated: Bool = false) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        controller = UserSessionController(defaults: defaults, backend: backend,
            displayBackend: MenuVisibilityBackend(), guiProbe: nil, environmentProbe: nil,
            boot: "menu-visibility-fixture")
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        var reply: ServiceReply?
        if helperOutdated {
            var status = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
                enabled: false, power: .ac, lidClosed: false, sleepDisabled: false,
                lastEvent: nil, lastEventAt: nil, thermal: 0)
            status.build = TetherPaths.build - 1
            status.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion - 1
            status.systemPowerObservationAvailable = true
            var value = ServiceReply(id: UUID(), ok: true, epoch: "menu-visibility-fixture",
                revision: 1, control: Control(), protection: .init(reason: nil, error: nil, dryRun: true))
            value.status = status; reply = value
        }
        model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller,
            previewLegacyObservation: { .init(power: .ac, lidClosed: false, sleepDisabled: false, fullWake: true) },
            previewWorkService: { _ in throw ServiceFailure("menu-visibility-fixture-isolated") },
            previewHelperReply: reply, previewDefaults: defaults, previewHelperFiles: { [] })
    }

    var actions: MenuActionVisibility { MenuActionVisibility(model: model) }
    func update(power: PowerSource = .ac, thermal: Int = 0) {
        controller.update(power: power, thermal: thermal, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
    }
    func close() {
        backend.releaseFails = false
        _ = controller.end()
        defaults.removePersistentDomain(forName: suite)
    }
}

/// Uses actual controller transitions with fake assertions; never opens a window or contacts the helper.
final class MenuActionVisibilityTests: XCTestCase {
    @MainActor
    func testIdleOffersNewManualAndQuickSetupWithoutRedundantCurrentOrStopRows() throws {
        let fixture = try MenuVisibilityFixture(); defer { fixture.close() }
        let actions = fixture.actions
        XCTAssertTrue(actions.showsNewManual)
        XCTAssertTrue(actions.showsAutomaticToggle)
        XCTAssertTrue(actions.showsQuickOptions)
        XCTAssertTrue(actions.showsWorkDetails)
        XCTAssertFalse(actions.showsCurrentWork)
        XCTAssertFalse(actions.showsStopAll)
        XCTAssertFalse(actions.showsAutomaticRest)
        XCTAssertFalse(actions.showsResume)
        XCTAssertFalse(actions.showsStartBlockedReason)
    }

    @MainActor
    func testAutomaticShowsCurrentWorkAndIndependentNewManualStart() throws {
        let fixture = try MenuVisibilityFixture(); defer { fixture.close() }
        fixture.controller.setAutomatic(true)
        XCTAssertTrue(fixture.model.automaticWorkReasonActive)
        XCTAssertTrue(fixture.actions.showsCurrentWork)
        XCTAssertTrue(fixture.actions.showsNewManual)
        XCTAssertTrue(fixture.actions.showsAutomaticRest)
        XCTAssertTrue(fixture.actions.showsStopAll)
        XCTAssertFalse(fixture.actions.showsResume)
    }

    @MainActor
    func testManualReplacesNewStartWithCurrentTimerActions() throws {
        let fixture = try MenuVisibilityFixture(); defer { fixture.close() }
        XCTAssertTrue(fixture.controller.start(duration: 1800))
        XCTAssertTrue(fixture.actions.showsCurrentWork)
        XCTAssertFalse(fixture.actions.showsNewManual)
        XCTAssertTrue(fixture.actions.showsStopAll)
        XCTAssertTrue(fixture.actions.showsQuickOptions)
        XCTAssertFalse(fixture.actions.showsAutomaticRest)
        fixture.controller.endManual()
        XCTAssertFalse(fixture.actions.showsCurrentWork)
        XCTAssertTrue(fixture.actions.showsNewManual)
        XCTAssertFalse(fixture.actions.showsStopAll)
    }

    @MainActor
    func testEndingManualDuringDualWorkKeepsAutomaticCurrentAndStopActions() throws {
        let fixture = try MenuVisibilityFixture(); defer { fixture.close() }
        fixture.controller.setAutomatic(true)
        XCTAssertTrue(fixture.controller.start(duration: 1800))
        XCTAssertTrue(fixture.actions.showsCurrentWork)
        XCTAssertFalse(fixture.actions.showsNewManual)
        XCTAssertTrue(fixture.actions.showsAutomaticRest)
        fixture.controller.endManual()
        XCTAssertTrue(fixture.model.automaticWorkReasonActive)
        XCTAssertTrue(fixture.actions.showsCurrentWork)
        XCTAssertTrue(fixture.actions.showsNewManual)
        XCTAssertTrue(fixture.actions.showsStopAll)
    }

    @MainActor
    func testAutomaticRestStillOffersManualAndAutomaticResumeControls() throws {
        let fixture = try MenuVisibilityFixture(); defer { fixture.close() }
        fixture.controller.setAutomatic(true)
        XCTAssertTrue(fixture.controller.pauseAutomatic(for: 1800))
        XCTAssertTrue(fixture.model.automaticPauseActive)
        XCTAssertFalse(fixture.actions.showsCurrentWork)
        XCTAssertTrue(fixture.actions.showsNewManual)
        XCTAssertTrue(fixture.actions.showsAutomaticRest)
        XCTAssertTrue(fixture.actions.showsAutomaticToggle)
        XCTAssertTrue(fixture.actions.showsStopAll)
        XCTAssertFalse(fixture.actions.showsResume, "Automatic-only rest is not the global stop latch")
        XCTAssertTrue(fixture.controller.start(duration: 1800))
        XCTAssertTrue(fixture.actions.showsCurrentWork)
        XCTAssertFalse(fixture.actions.showsNewManual)
    }

    @MainActor
    func testGlobalStopOffersOnlyResumeUntilExplicitlyAllowedAgain() throws {
        let fixture = try MenuVisibilityFixture(); defer { fixture.close() }
        fixture.controller.setAutomatic(true)
        XCTAssertTrue(fixture.controller.start(duration: 1800))
        fixture.controller.stopCurrent()
        XCTAssertTrue(fixture.model.workPaused)
        XCTAssertTrue(fixture.actions.showsResume)
        assertNoAcquisitionOrCurrentWork(fixture.actions)
        XCTAssertFalse(fixture.actions.showsStopAll)
        XCTAssertFalse(fixture.actions.showsStartBlockedReason)
    }

    @MainActor
    func testProtectionHidesUnsafeActionsAndRevealsResumeOnlyAfterHealthyReadings() throws {
        let fixture = try MenuVisibilityFixture(); defer { fixture.close() }
        fixture.controller.setAutomatic(true)
        fixture.update(thermal: 2)
        XCTAssertEqual(fixture.model.workProtectionReason, "thermal")
        assertNoAcquisitionOrCurrentWork(fixture.actions)
        XCTAssertFalse(fixture.actions.showsResume)
        fixture.update()
        XCTAssertEqual(fixture.model.workProtectionReason, "thermal", "Healthy input alone cannot clear the user-resume latch")
        XCTAssertFalse(fixture.actions.showsResume)
        let base = ContinuousTime.now
        for seconds in stride(from: 0, through: 60, by: 10) {
            fixture.controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: base + Double(seconds), batteryPercent: 80)
        }
        XCTAssertTrue(fixture.actions.showsResume)
        assertNoAcquisitionOrCurrentWork(fixture.actions)
    }

    @MainActor
    func testHelperErrorDoesNotRemoveOrdinaryManualAndAutomaticControls() throws {
        let fixture = try MenuVisibilityFixture(helperOutdated: true); defer { fixture.close() }
        XCTAssertTrue(fixture.model.helperOutdated)
        XCTAssertTrue(fixture.actions.showsNewManual)
        XCTAssertTrue(fixture.actions.showsAutomaticToggle)
        XCTAssertTrue(fixture.actions.showsQuickOptions)
        XCTAssertTrue(fixture.controller.start(duration: 1800))
        XCTAssertTrue(fixture.actions.showsCurrentWork)
        XCTAssertTrue(fixture.actions.showsStopAll, "A helper problem must not trap a running ordinary session")
    }

    @MainActor
    func testUnknownObservationBlocksNewActionsButKeepsCurrentWorkStopEscape() throws {
        let fixture = try MenuVisibilityFixture(); defer { fixture.close() }
        fixture.update(power: .unknown)
        assertNoAcquisitionOrCurrentWork(fixture.actions)
        XCTAssertTrue(fixture.actions.showsStartBlockedReason)
        fixture.update()
        XCTAssertTrue(fixture.controller.start(duration: 1800))
        fixture.update(power: .unknown)
        XCTAssertTrue(fixture.actions.showsCurrentWork)
        XCTAssertTrue(fixture.actions.showsStopAll)
        XCTAssertFalse(fixture.actions.showsNewManual)
        XCTAssertFalse(fixture.actions.showsAutomaticToggle)
        XCTAssertFalse(fixture.actions.showsQuickOptions)
        XCTAssertFalse(fixture.actions.showsWorkDetails)
    }

    @MainActor
    func testUnconfirmedReleaseCannotOfferRestartOrResume() throws {
        let fixture = try MenuVisibilityFixture(); defer { fixture.close() }
        XCTAssertTrue(fixture.controller.start(duration: 1800))
        fixture.backend.releaseFails = true
        fixture.controller.endManual()
        XCTAssertEqual(fixture.controller.status.ownReleasePending, true)
        assertNoAcquisitionOrCurrentWork(fixture.actions)
        XCTAssertFalse(fixture.actions.showsStopAll)
        XCTAssertFalse(fixture.actions.showsResume)
        // Settings and Quit remain unconditional in TetherPanel's persistent footer.
    }

    private func assertNoAcquisitionOrCurrentWork(_ actions: MenuActionVisibility,
                                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(actions.showsCurrentWork, file: file, line: line)
        XCTAssertFalse(actions.showsNewManual, file: file, line: line)
        XCTAssertFalse(actions.showsAutomaticToggle, file: file, line: line)
        XCTAssertFalse(actions.showsAutomaticRest, file: file, line: line)
        XCTAssertFalse(actions.showsQuickOptions, file: file, line: line)
        XCTAssertFalse(actions.showsWorkDetails, file: file, line: line)
    }
}
