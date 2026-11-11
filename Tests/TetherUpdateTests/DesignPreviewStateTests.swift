import AppKit
import SwiftUI
import XCTest
import TetherCore
@testable import Tether

/// Dedicated previews now use the shipping controller with isolated defaults and executors.
final class DesignPreviewStateTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { _ = NSApplication.shared }
    }

    @MainActor
    private func waitForPreparedPreview(_ state: DesignPreviewState,
                                        file: StaticString = #filePath, line: UInt = #line) async {
        guard state.scenario != .desktop else { return }
        for _ in 0..<1000 {
            if state.model.helperSetupConfirmed, !state.model.lidCommandPending,
               state.model.workPaused || state.model.lidSupportConfirmed { return }
            await Task.yield()
        }
        XCTFail("Isolated design helper did not settle", file: file, line: line)
    }

    @MainActor
    func testSettingsPreviewKeepsWindowBoundsAcrossLongPages() async throws {
        let previous = Localization.current
        defer { Localization.current = previous }
        for language in [Language.korean, .english] {
            Localization.current = language
            let state = DesignPreviewState(scenario: .automatic)
            defer { state.close() }
            await waitForPreparedPreview(state)
            for size in [WorkSessionMetrics.settingsMinimum, CGSize(width: 900, height: 640)] {
                let window = DesignPreview.makeWindow(title: "Settings layout regression",
                    size: size, dark: false,
                    view: DesignPreviewSettings(state: state, page: .app, snapshot: true))
                defer { window.close() }
                for _ in 0..<20 { await Task.yield() }
                settleLayout(window)
                let frame = window.frame
                for page in [SettingsPage.safety, .general, .protection, .system, .safety] {
                    state.model.settingsPage = page
                    for _ in 0..<20 { await Task.yield() }
                    settleLayout(window)
                    let host = try XCTUnwrap(window.contentView)
                    XCTAssertFalse(host.subviews.isEmpty, "The native split view must be mounted")
                    for child in host.subviews {
                        XCTAssertLessThanOrEqual(child.frame.height, host.bounds.height + 0.5,
                            "Long settings must scroll inside the viewport: \(language), \(page), \(size)")
                        XCTAssertEqual(child.frame.minY, 0, accuracy: 0.5,
                            "Page changes must not shift the sidebar and heading outside the viewport")
                    }
                    XCTAssertEqual(window.frame, frame, "Changing pages must preserve the user's window")
                }
                XCTAssertFalse(window.isVisible, "This geometry regression must not show a window")
            }
        }
    }

    @MainActor
    private func settleLayout(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        // Drain deferred native-control baseline and split-view measurements.
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor
    func testRetiredPreviewFlagsNeverFallThroughToNormalAppLaunch() {
        for flag in ["--render-history", "--render-rehearsal", "--render-update-wait"] {
            XCTAssertTrue(PreviewRenderer.handle([flag]), "A removed preview must be consumed without launching the live app")
        }
    }

    @MainActor
    func testAutomaticOffLeavesCurrentManualRequestUnchanged() async throws {
        let state = DesignPreviewState()
        defer { state.close() }
        await waitForPreparedPreview(state)
        let work = try XCTUnwrap(state.model.userSession)
        let request = try XCTUnwrap(work.manualRequestID)
        let deadline = work.status.manualContinuousDeadline
        state.model.setAutomaticEnabled(false)
        XCTAssertFalse(state.model.automaticWorkReasonActive)
        XCTAssertTrue(state.model.manualSessionActive)
        XCTAssertEqual(work.manualRequestID, request)
        XCTAssertEqual(work.status.manualContinuousDeadline, deadline)
    }

    @MainActor
    func testManualACUnlimitedStartsWithAutomaticOff() async throws {
        let state = DesignPreviewState(); defer { state.close() }
        await waitForPreparedPreview(state)
        let model = state.model
        model.endManualSession(); model.setAutomaticEnabled(false)
        model.startUntimedSession()
        XCTAssertTrue(model.manualSessionActive)
        XCTAssertTrue(model.workSessionHolding)
        XCTAssertNil(model.manualSessionUntil)
        XCTAssertFalse(model.automaticWorkReasonActive)
    }

    @MainActor
    func testAutomaticToggleDoesNotClearPauseAllOrRestoreManual() async throws {
        let state = DesignPreviewState(); defer { state.close() }
        await waitForPreparedPreview(state)
        let model = state.model
        model.setEnabled(false)
        model.setAutomaticEnabled(false); model.setAutomaticEnabled(true)
        XCTAssertTrue(model.workPaused)
        XCTAssertFalse(model.manualSessionActive)
        XCTAssertFalse(model.workSessionHolding)
        XCTAssertTrue(model.automaticEnabled)
    }

    @MainActor
    func testManualEndKeepsACAutomaticActive() async throws {
        let state = DesignPreviewState(); defer { state.close() }
        await waitForPreparedPreview(state)
        let model = state.model
        model.endManualSession()
        XCTAssertFalse(model.manualSessionActive)
        XCTAssertTrue(model.automaticEnabled)
        XCTAssertTrue(model.automaticWorkReasonActive)
        XCTAssertTrue(model.workSessionHolding)
    }

    @MainActor
    func testBatteryPreviewHasManualReasonOnlyAndUnplugConsumesIt() async throws {
        let state = DesignPreviewState(scenario: .battery); defer { state.close() }
        await waitForPreparedPreview(state)
        let model = state.model
        let work = try XCTUnwrap(model.userSession)
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
    func testBatteryRejectsUnlimitedAndOverTwoHoursButAllowsNewExplicitStart() async throws {
        let state = DesignPreviewState(scenario: .battery); defer { state.close() }
        await waitForPreparedPreview(state)
        let model = state.model
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
    func testThermalProtectionCannotBeBypassedAndUsesIsolatedModel() async throws {
        let state = DesignPreviewState(scenario: .protection); defer { state.close() }
        await waitForPreparedPreview(state)
        let model = state.model
        XCTAssertFalse(model.defaults === UserDefaults.standard)
        XCTAssertNotNil(model.workProtectionReason)
        model.setAutomaticEnabled(true); model.setEnabled(true); model.startUntimedSession()
        XCTAssertFalse(model.workSessionHolding)
        XCTAssertFalse(model.manualSessionActive)
        XCTAssertFalse(model.canResumeWork)
    }

    @MainActor
    func testExplicitScenarioSelectionRejectsRemovedUnknownMissingAndRepeatedValues() throws {
        XCTAssertEqual(try DesignPreview.selectedScenario(arguments: []), .ac)
        for scenario in DesignPreviewState.Scenario.allCases {
            XCTAssertEqual(try DesignPreview.selectedScenario(arguments: ["--scenario", scenario.rawValue]), scenario)
        }
        for removed in ["helper", "lock", "recovery", "unknown", ""] {
            XCTAssertNil(DesignPreviewState.Scenario(rawValue: removed))
            XCTAssertThrowsError(try DesignPreview.selectedScenario(arguments: ["--scenario", removed])) {
                XCTAssertEqual($0 as? DesignPreview.ScenarioArgumentError, .unsupported(removed))
            }
        }
        for arguments in [["--scenario"], ["--scenario", "--light"]] {
            XCTAssertThrowsError(try DesignPreview.selectedScenario(arguments: arguments)) {
                XCTAssertEqual($0 as? DesignPreview.ScenarioArgumentError, .missingValue)
            }
        }
        XCTAssertThrowsError(try DesignPreview.selectedScenario(arguments: ["--scenario", "ac", "--scenario", "lock"])) {
            XCTAssertEqual($0 as? DesignPreview.ScenarioArgumentError, .repeatedFlag)
        }
    }

    @MainActor
    func testFactoryScenariosSeparateSavedPermissionsFromActiveWorkInBothLanguages() async throws {
        let previous = Localization.current
        defer { Localization.current = previous }
        for language in [Language.english, .korean] {
            Localization.current = language
            for scenario in DesignPreviewState.Scenario.allCases {
                let state = DesignPreviewState(scenario: scenario); defer { state.close() }
                await waitForPreparedPreview(state)
                let model = state.model
                let work = try XCTUnwrap(model.userSession)
                let stopped = scenario == .paused || scenario == .protection
                let manual = scenario != .automatic && !stopped
                let automatic = [.ac, .automatic, .dual, .desktop].contains(scenario)
                let context = "\(language) / \(scenario)"
                XCTAssertFalse(model.defaults === UserDefaults.standard, context)
                XCTAssertTrue(model.userCommandsArePreview, context)
                XCTAssertEqual(model.v3Settings.allowClosedLid, scenario != .desktop, context)
                XCTAssertTrue(model.v3Settings.keepDisplayAwake, context)
                XCTAssertEqual(work.status.manualActive, manual, context)
                XCTAssertEqual(work.status.automaticActive, automatic, context)
                XCTAssertEqual(work.status.holding, !stopped, context)
                XCTAssertEqual(work.status.displayHolding, !stopped, context)
                XCTAssertEqual(work.status.power, scenario == .battery ? .battery : .ac, context)
                XCTAssertEqual(model.showsLidOptions, scenario != .desktop, context)
                XCTAssertEqual(work.manualRequestID != nil, manual, context)
                if scenario == .paused {
                    XCTAssertEqual(work.runtimeMarkers.pauseReason, .userStop, context)
                    XCTAssertNil(model.workProtectionReason, context)
                } else if scenario == .protection {
                    XCTAssertEqual(model.workProtectionReason, "thermal", context)
                    XCTAssertEqual(work.status.thermal, 2, context)
                }
            }
        }
    }

    @MainActor
    func testModelReplacementAndCloseEndOldWorkAndStopThePreviewPump() async throws {
        let state = DesignPreviewState(scenario: .dual); defer { state.close() }
        await waitForPreparedPreview(state)
        let original = try XCTUnwrap(state.model.userSession)
        let request = try XCTUnwrap(original.manualRequestID)
        XCTAssertFalse(state.isObserving, "Constructing a static preview must not start a timer")
        state.startObserving()
        XCTAssertTrue(state.isObserving)
        state.scenario = .manual
        let replacement = try XCTUnwrap(state.model.userSession)
        XCTAssertFalse(original === replacement)
        XCTAssertFalse(original.status.holding)
        XCTAssertFalse(original.status.manualActive)
        XCTAssertNil(original.manualRequestID)
        XCTAssertTrue(state.isObserving)
        XCTAssertNotEqual(replacement.manualRequestID, request)
        await waitForPreparedPreview(state)
        state.close()
        XCTAssertFalse(state.isObserving)
        XCTAssertFalse(replacement.status.holding)
        XCTAssertFalse(replacement.status.manualActive)
        let stopped = replacement.status
        state.refreshObservations()
        XCTAssertEqual(replacement.status, stopped, "A closed preview must not keep refreshing its old model")
    }

    @MainActor
    func testPreviewPumpKeepsProtectionAndUserStopInsteadOfReplacingThemWithHealthyWork() async throws {
        for scenario in [DesignPreviewState.Scenario.protection, .paused] {
            let state = DesignPreviewState(scenario: scenario); defer { state.close() }
            await waitForPreparedPreview(state)
            let work = try XCTUnwrap(state.model.userSession)
            state.startObserving()
            for _ in 0..<3 { state.refreshObservations() }
            XCTAssertTrue(state.isObserving)
            XCTAssertFalse(work.status.holding)
            XCTAssertFalse(work.status.manualActive)
            if scenario == .protection {
                XCTAssertEqual(work.status.thermal, 2)
                XCTAssertEqual(state.model.workProtectionReason, "thermal")
            } else {
                XCTAssertEqual(work.status.thermal, 0)
                XCTAssertEqual(work.runtimeMarkers.pauseReason, .userStop)
            }
            state.close()
            XCTAssertFalse(state.isObserving)
        }
    }
}
