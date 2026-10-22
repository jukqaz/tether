import XCTest
import TetherCore
@testable import Tether

/// Dedicated previews now use the shipping controller with isolated defaults and executors.
final class DesignPreviewStateTests: XCTestCase {
    @MainActor
    func testRetiredPreviewFlagsNeverFallThroughToNormalAppLaunch() {
        for flag in ["--render-history", "--render-rehearsal", "--render-update-wait"] {
            XCTAssertTrue(PreviewRenderer.handle([flag]), "A removed preview must be consumed without launching the live app")
        }
    }

    @MainActor
    func testAutomaticOffLeavesCurrentManualRequestUnchanged() throws {
        let state = DesignPreviewState()
        let work = try XCTUnwrap(state.model.userSession); defer { _ = work.end() }
        let request = try XCTUnwrap(work.manualRequestID)
        let deadline = work.status.manualContinuousDeadline
        state.model.setAutomaticEnabled(false)
        XCTAssertFalse(state.model.automaticWorkReasonActive)
        XCTAssertTrue(state.model.manualSessionActive)
        XCTAssertEqual(work.manualRequestID, request)
        XCTAssertEqual(work.status.manualContinuousDeadline, deadline)
    }

    @MainActor
    func testManualACUnlimitedStartsWithAutomaticOff() throws {
        let model = DesignPreviewState().model
        let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
        model.endManualSession(); model.setAutomaticEnabled(false)
        model.startUntimedSession()
        XCTAssertTrue(model.manualSessionActive)
        XCTAssertTrue(model.workSessionHolding)
        XCTAssertNil(model.manualSessionUntil)
        XCTAssertFalse(model.automaticWorkReasonActive)
    }

    @MainActor
    func testAutomaticToggleDoesNotClearPauseAllOrRestoreManual() throws {
        let model = DesignPreviewState().model
        let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
        model.setEnabled(false)
        model.setAutomaticEnabled(false); model.setAutomaticEnabled(true)
        XCTAssertTrue(model.workPaused)
        XCTAssertFalse(model.manualSessionActive)
        XCTAssertFalse(model.workSessionHolding)
        XCTAssertTrue(model.automaticEnabled)
    }

    @MainActor
    func testManualEndKeepsACAutomaticActive() throws {
        let model = DesignPreviewState().model
        let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
        model.endManualSession()
        XCTAssertFalse(model.manualSessionActive)
        XCTAssertTrue(model.automaticEnabled)
        XCTAssertTrue(model.automaticWorkReasonActive)
        XCTAssertTrue(model.workSessionHolding)
    }

    @MainActor
    func testBatteryPreviewHasManualReasonOnlyAndUnplugConsumesIt() throws {
        let model = DesignPreviewState(scenario: .battery).model
        let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
        XCTAssertTrue(model.manualSessionActive)
        XCTAssertFalse(model.automaticWorkReasonActive)
        model.setAutomaticEnabled(true)
        XCTAssertFalse(model.automaticWorkReasonActive, "Saved automatic ON does not authorize battery work")
        work.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now, batteryPercent: 80)
        work.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now + 1, batteryPercent: 80)
        XCTAssertFalse(model.manualSessionActive)
        XCTAssertFalse(model.workSessionHolding)
    }

    @MainActor
    func testBatteryRejectsUnlimitedAndOverTwoHoursButAllowsNewExplicitStart() throws {
        let model = DesignPreviewState(scenario: .battery).model
        let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
        model.endManualSession()
        for minutes in [nil, -1, 121] as [Int?] {
            model.startManualSession(minutes: minutes)
            XCTAssertFalse(model.manualSessionActive)
        }
        model.startManualSession(minutes: 120)
        XCTAssertTrue(model.manualSessionActive)
        XCTAssertTrue(model.workSessionHolding)
    }

    @MainActor
    func testThermalProtectionCannotBeBypassedAndUsesIsolatedModel() throws {
        let model = DesignPreviewState(scenario: .protection).model
        let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
        XCTAssertFalse(model.defaults === UserDefaults.standard)
        XCTAssertNotNil(model.workProtectionReason)
        model.setAutomaticEnabled(true); model.setEnabled(true); model.startUntimedSession()
        XCTAssertFalse(model.workSessionHolding)
        XCTAssertFalse(model.manualSessionActive)
        XCTAssertFalse(model.canResumeWork)
    }
}
