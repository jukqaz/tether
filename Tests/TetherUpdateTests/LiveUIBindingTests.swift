import AppKit
import Combine
import SwiftUI
import XCTest
import TetherCore
@testable import Tether

private final class LiveUIDefaults: UserDefaults {
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

private final class LiveUIAssertion: IdleAssertionBackend {
    var creates = 0
    var releases = 0
    var creationFails = false
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        creates += 1
        return creationFails ? (-1, nil) : (0, 31)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { releases += 1; return 0 }
}

/// Shipping views + AppModel + real policy/controller, with memory-only executors and defaults.
final class LiveUIBindingTests: XCTestCase {
    func testRenderSamplesKeepTitleSwitchesAndTimersInOneIsolatedSession() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .english
            for arguments in [["--sample"], ["--sample", "--hold"], ["--manual-ready"],
                              ["--manual"], ["--manual", "--timed", "--battery"]] {
                let model = PreviewRenderer.sampleModel(arguments: arguments)
                let work = try XCTUnwrap(model.userSession)
                defer { _ = work.end() }
                let manual = arguments.contains("--manual") || arguments.contains("--hold")
                let ready = arguments.contains("--manual-ready")
                XCTAssertFalse(model.defaults === UserDefaults.standard)
                XCTAssertNil(model.status, "A sample must not import the installed helper's state")
                XCTAssertEqual(model.batteryPercent, 80)
                XCTAssertEqual(model.automaticEnabled, !manual && !ready)
                XCTAssertEqual(model.v3Settings.automaticEnabled, model.automaticEnabled)
                XCTAssertEqual(model.manualSessionActive, manual)
                XCTAssertEqual(model.workSessionHolding, !ready)
                XCTAssertNil(model.errorText)
                XCTAssertEqual(model.presentation.title, ready ? "Keep-awake is off"
                    : manual ? "Manual session active" : "Keeping work running")
                if manual && arguments.contains("--timed") {
                    XCTAssertEqual(try XCTUnwrap(work.status.until).timeIntervalSinceNow, 1800, accuracy: 2)
                }
            }
        }
    }

    func testBatteryRenderNeverActivatesSavedAutomaticAndManualEndEndsItsOnlyReason() async throws {
        try await MainActor.run {
            let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual", "--battery", "--dual"])
            let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
            model.setAutomaticEnabled(true)
            XCTAssertFalse(model.automaticWorkReasonActive)
            XCTAssertTrue(model.manualSessionActive)
            let panel = NSHostingView(rootView: TetherPanel(model: model).environment(\.tetherReduceTransparencyOverride, true))
            XCTAssertLessThanOrEqual(panel.fittingSize.height, WorkSessionMetrics.panelMaximumHeight)
            try assertSnapshot(panel, size: panel.fittingSize)
            model.endManualSession()
            XCTAssertFalse(model.manualSessionActive)
            XCTAssertFalse(model.workSessionHolding)
            XCTAssertTrue(model.automaticEnabled)
        }
    }

    @MainActor
    func testSettingsInitialFocusClearsOnceAndPreservesLaterKeyboardTarget() async {
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        let watcher = SettingsWindowBridge.WindowWatcher(
            minimumSize: WorkSessionMetrics.settingsMinimum, allowsResizing: true)
        defer {
            watcher.removeFromSuperview()
            window.close()
            NSApp.setActivationPolicy(previousPolicy)
        }
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        window.contentView?.addSubview(watcher)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(window.firstResponder === window,
            "Initial host focus should not highlight a control before keyboard input")

        XCTAssertTrue(window.makeFirstResponder(field))
        let keyboardTarget = window.firstResponder
        // This is a responder-lifecycle test, not synthesized keyboard input.
        // The private native UI suite exercises actual click/Tab/command events.
        watcher.viewDidMoveToWindow()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(window.firstResponder === keyboardTarget,
            "Layout reattachment must preserve the user's later keyboard target")

        // Settings restores its empty toolbar and host style on a retained
        // window's next presentation. Recreate that observed reopening state.
        window.toolbar = NSToolbar(identifier: "settings-reopen-regression")
        window.toolbar?.isVisible = true
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove(.resizable)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(window.toolbar?.isVisible, false,
            "Reopening must not restore a second, empty navigation header")
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView),
            "The fixed page heading must remain below the native titlebar")
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, WorkSessionMetrics.settingsMinimum)
        XCTAssertTrue(window.firstResponder === keyboardTarget,
            "Reopening chrome must not discard existing keyboard focus")

        let frameBeforeNativeUpdate = window.frame
        window.styleMask.remove(.resizable)
        window.toolbar?.isVisible = true
        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(window.styleMask.contains(.resizable),
            "A late Settings host update must not disable resizing after initial presentation")
        XCTAssertEqual(window.toolbar?.isVisible, false)
        XCTAssertEqual(window.frame.size, frameBeforeNativeUpdate.size,
            "Restoring the resize affordance must not resize the user's window")
        XCTAssertTrue(window.firstResponder === keyboardTarget)
    }

    func testPreviewIndicatorKeepsLocalizedTextUnderIconOnlyHostStyle() async {
        await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for (language, title) in [(Language.english, "Preview"), (.korean, "미리보기")] {
                Localization.current = language
                // Window toolbars supply icon-only label styling. The warning's
                // own title-and-icon style must keep the identity readable there.
                let host = NSHostingView(rootView: PreviewIndicator().labelStyle(.iconOnly))
                let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
                XCTAssertGreaterThanOrEqual(host.fittingSize.width, textWidth + 12,
                    "The Preview identity must allocate room for its visible text and icon")
                XCTAssertGreaterThan(host.fittingSize.height, 10)
                XCTAssertTrue(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
            }
        }
    }

    func testSettingsNavigationKeepsCompactWorkNameAndFullPageTitle() async {
        await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .english
            XCTAssertEqual(SettingsPage.general.shortTitle, "Work",
                "The compact segmented tabs must use the short navigation name")
            XCTAssertEqual(SettingsPage.general.title, "Work sessions",
                "Shortening navigation must not shorten the page heading or accessibility name")
            XCTAssertEqual(SettingsPage.safety.shortTitle, "Protection")
            XCTAssertEqual(SettingsPage.system.shortTitle, "App settings")

            Localization.current = .korean
            for page in SettingsPage.allCases {
                XCTAssertEqual(page.shortTitle, page.title,
                    "Korean page names already fit and must remain unchanged")
            }
        }
    }

    func testActiveDiagnosticRecordingRemainsAvailableAcrossPageRecreationAndStopsWithoutPowerWork() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .english
            let (model, controller, backend) = fixture()
            defer { _ = controller.end() }
            let savedIntent = model.defaults.data(forKey: UserSessionController.preferenceKey)
            let initialRow = SystemPage(model: model).activeRecordingStatus
            let inactive = NSHostingView(rootView: initialRow.frame(width: 400))
            XCTAssertEqual(inactive.fittingSize.height, 0, accuracy: 0.5,
                "Inactive recording must not add a status row to compact App Settings")

            model.setDebugLogging(true, minutes: 15)
            XCTAssertTrue(model.diagnosticRecordingActive)
            let until = try XCTUnwrap(model.diagnosticRecordingUntil)
            XCTAssertEqual(until.timeIntervalSinceNow, 900, accuracy: 2)

            // Rebuilding the page resets its disclosure State. The active row
            // reads controller state, independently of that collapsed detail.
            for _ in 0..<2 {
                model.settingsPage = .general
                model.settingsPage = .system
                let row = SystemPage(model: model).activeRecordingStatus
                let active = NSHostingView(rootView: row.frame(width: 400))
                XCTAssertGreaterThan(active.fittingSize.height, 28,
                    "Reconstructed App Settings must still render status, deadline and Stop")
                XCTAssertEqual(row.recordingDetail, "Recording until \(Texts.time(until))")
                XCTAssertTrue(row.model.canRecordDiagnostics)
                XCTAssertEqual(model.diagnosticRecordingUntil, until,
                    "Page reconstruction must not restart the recording deadline")
            }

            // Exercise the same action used by the visible Stop button, without
            // synthesizing GUI input or changing installed application state.
            let recordingEndedBefore = model.commonActivity.filter { $0.kind == .recordingEnded }.count
            SystemPage(model: model).activeRecordingStatus.stopRecording()
            XCTAssertFalse(model.diagnosticRecordingActive)
            XCTAssertNil(model.diagnosticRecordingUntil)
            let stopped = NSHostingView(rootView: SystemPage(model: model).activeRecordingStatus.frame(width: 400))
            XCTAssertEqual(stopped.fittingSize.height, 0, accuracy: 0.5)
            // commonActivity is newest-first and can include unrelated decision
            // events. Verify the added end event without assuming its array index.
            XCTAssertEqual(model.commonActivity.filter { $0.kind == .recordingEnded }.count,
                           recordingEndedBefore + 1)
            XCTAssertEqual(model.commonActivity.last(where: { $0.kind == .recordingEnded })?.kind, .recordingEnded)
            XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), savedIntent)
            XCTAssertEqual(backend.creates, 0)
            XCTAssertEqual(backend.releases, 0)
        }
    }

    @MainActor
    private func fixture(portable: Bool = true, power: PowerSource = .ac)
        -> (AppModel, UserSessionController, LiveUIAssertion) {
        let defaults = LiveUIDefaults(), backend = LiveUIAssertion()
        let controller = UserSessionController(defaults: defaults, backend: backend,
            guiProbe: nil, environmentProbe: nil, boot: "ui-fixture")
        controller.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: portable ? 80 : nil)
        let model = AppModel(preview: true,
            capabilities: MacCapabilities(supportedPlatform: true, internalBattery: portable, lid: portable),
            previewSession: controller, previewDefaults: defaults)
        return (model, controller, backend)
    }

    func testSavedDefaultsNotifyViewsAndHistoryWithoutRedrawingUnchangedChoices() async {
        await MainActor.run {
            let (model, controller, backend) = fixture(); defer { _ = controller.end() }
            model.selectManualDuration(900)
            let originalStatus = controller.status
            let originalCreates = backend.creates
            let originalHistory = model.v4HistoryItems.count
            var changes = 0
            let observation = model.objectWillChange.sink { changes += 1 }; defer { observation.cancel() }
            model.selectManualDuration(2700)
            XCTAssertEqual(model.selectedManualMinutes, 45)
            XCTAssertEqual(model.manualDurationChoices, [5, 10, 15, 30, 45, 60, 120])
            XCTAssertEqual(controller.settings.lastManualDurationSeconds, 2700)
            XCTAssertEqual(controller.status, originalStatus)
            XCTAssertGreaterThan(changes, 0)
            XCTAssertEqual(model.v4HistoryItems.count, originalHistory + 1)
            let durationChanges = changes
            model.selectManualDuration(2700)
            for invalid in [0, -60, Double.infinity, Double.nan, Double.greatestFiniteMagnitude] {
                model.selectManualDuration(invalid)
            }
            XCTAssertEqual(model.selectedManualMinutes, 45)
            XCTAssertEqual(changes, durationChanges, "Unchanged or rejected choices must not redraw views")
            XCTAssertEqual(model.v4HistoryItems.count, originalHistory + 1)
            model.setAllowClosedLid(true)
            XCTAssertTrue(model.v3Settings.allowClosedLid)
            XCTAssertEqual(controller.status, originalStatus)
            XCTAssertGreaterThan(changes, durationChanges)
            XCTAssertEqual(model.v4HistoryItems.count, originalHistory + 2)
            let lidChanges = changes
            model.setAllowClosedLid(true)
            XCTAssertEqual(changes, lidChanges)
            model.setDisconnectAction(.followOS)
            XCTAssertEqual(model.v3Settings.disconnectAction, .followOS)
            XCTAssertEqual(controller.status, originalStatus)
            XCTAssertGreaterThan(changes, lidChanges)
            XCTAssertEqual(model.v4HistoryItems.count, originalHistory + 3)
            let unplugChanges = changes
            model.setDisconnectAction(.followOS)
            XCTAssertEqual(changes, unplugChanges)
            XCTAssertEqual(backend.creates, originalCreates)
            XCTAssertFalse(model.manualSessionActive)
        }
    }

    func testResumeAvailabilityMatchesBatteryRecoveryMarginAndWarning() async {
        await MainActor.run {
            let (model, controller, _) = fixture(power: .battery)
            defer { _ = controller.end() }
            model.setEnabled(false)
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 23)
            XCTAssertFalse(model.canResumeWork, "The button must wait for the same reserve margin as Resume")
            XCTAssertFalse(controller.setEnabled(true))

            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 25)
            XCTAssertTrue(model.canResumeWork)
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80, lowPowerWarning: true)
            XCTAssertFalse(model.canResumeWork, "An active battery warning must keep Resume unavailable")
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80, lowPowerWarning: nil)
            XCTAssertFalse(model.canResumeWork, "An unconfirmed warning must not be presented as recovered")
        }
    }

    func testUnobservedSleepPauseShowsExplicitResumeWithoutRestartingWork() async {
        await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .english
            let (model, controller, backend) = fixture()
            defer { _ = controller.end() }
            model.setAutomaticEnabled(true)
            let creates = backend.creates
            XCTAssertTrue(controller.pauseForUserSleep())
            model.errorText = "Sleep request failed."
            XCTAssertTrue(model.v3Settings.enabled, "The saved master choice survives the runtime pause")
            XCTAssertEqual(controller.runtimeMarkers.pauseReason, .userSleep)
            XCTAssertTrue(model.workPaused)
            XCTAssertEqual(model.presentation.title, "Paused")
            XCTAssertEqual(model.manualStartBlockedDetail, "Choose Resume work before starting a manual session.")
            XCTAssertFalse(model.canStartManualSession)
            XCTAssertFalse(model.workSessionHolding)
            XCTAssertEqual(backend.creates, creates, "Displaying Resume cannot restart work")

            model.setEnabled(true)
            XCTAssertNil(controller.runtimeMarkers.pauseReason)
            XCTAssertFalse(model.workPaused)
            XCTAssertTrue(model.workSessionHolding)
        }
    }

    func testPersistedSleepPauseShowsExplicitResumeAfterRestart() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .english
            let defaults = LiveUIDefaults(), backend = LiveUIAssertion()
            var settings = IdleSessionSettings()
            settings.automaticEnabled = true
            settings.runtimeMarkers = RuntimeMarkers(pauseReason: .userSleep)
            defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
            let controller = UserSessionController(defaults: defaults, backend: backend,
                guiProbe: nil, environmentProbe: nil, boot: "ui-fixture")
            defer { _ = controller.end() }
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            let model = AppModel(preview: true,
                capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: controller, previewDefaults: defaults)
            XCTAssertEqual(controller.runtimeMarkers.pauseReason, .userSleep)
            XCTAssertTrue(model.workPaused)
            XCTAssertEqual(model.presentation.title, "Paused")
            XCTAssertTrue(model.canResumeWork)
            XCTAssertFalse(model.canStartManualSession)
            XCTAssertFalse(model.workSessionHolding)
            XCTAssertEqual(backend.creates, 0)
        }
    }

    func testLegacyBatteryOnlyAutomaticNeverBecomesACOnDuringRendering() async throws {
        try await MainActor.run {
            for internalBattery in [false, nil] as [Bool?] {
                let defaults = LiveUIDefaults(), backend = LiveUIAssertion()
                var settings = IdleSessionSettings(); settings.powerCondition = .battery; settings.automaticEnabled = true
                defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
                let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "ui-fixture")
                defer { _ = controller.end() }
                controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now, batteryPercent: nil)
                let model = AppModel(preview: true, capabilities: MacCapabilities(supportedPlatform: true, internalBattery: internalBattery, lid: false),
                                     previewSession: controller, previewDefaults: defaults)
                try assertSnapshot(NSHostingView(rootView: GeneralPage(model: model)), size: CGSize(width: 560, height: 448))
                XCTAssertFalse(model.automaticEnabled, "Retired battery-only auto cannot silently enable AC")
                XCTAssertFalse(model.workSessionHolding)
                model.setPowerCondition(.ac); model.setAutomaticEnabled(true)
                XCTAssertTrue(model.automaticWorkReasonActive)
            }
        }
    }

    func testAutomaticOnBatteryStaysWaitingAcrossElapsedTimeAndExplicitResume() async throws {
        await MainActor.run {
            let (model, controller, backend) = fixture(power: .battery); defer { _ = controller.end() }
            model.setAutomaticEnabled(true)
            let creates = backend.creates
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                              now: ContinuousTime.now + 61, batteryPercent: 80)
            model.setEnabled(true)
            XCTAssertTrue(model.automaticEnabled)
            XCTAssertFalse(model.automaticWorkReasonActive)
            XCTAssertFalse(model.workSessionHolding)
            XCTAssertFalse(model.manualSessionActive)
            XCTAssertEqual(backend.creates, creates)
        }
    }

    func testACAutomaticReevaluatesOnReconnectButUnplugNeverCarriesWork() async {
        await MainActor.run {
            let (model, controller, _) = fixture(power: .battery); defer { _ = controller.end() }
            model.setAutomaticEnabled(true)
            let base = ContinuousTime.now
            XCTAssertFalse(model.workSessionHolding)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 1, batteryPercent: 80)
            XCTAssertTrue(model.automaticWorkReasonActive)
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 2, batteryPercent: 80)
            XCTAssertFalse(model.workSessionHolding)
            XCTAssertFalse(model.manualSessionActive)
            XCTAssertTrue(model.automaticEnabled)
        }
    }

    func testSavedACAutomaticDoesNotHideOrRetimeBatteryManual() async throws {
        try await MainActor.run {
            let (model, controller, _) = fixture(power: .battery); defer { _ = controller.end() }
            model.setAutomaticEnabled(true); model.startManualSession(minutes: 30)
            let deadline = try XCTUnwrap(controller.status.manualContinuousDeadline)
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                              now: ContinuousTime.now + 61, batteryPercent: 80)
            XCTAssertFalse(model.automaticWorkReasonActive)
            XCTAssertTrue(model.manualSessionActive); XCTAssertTrue(model.workSessionHolding)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            model.endManualSession()
            XCTAssertFalse(model.workSessionHolding)
            XCTAssertTrue(model.automaticEnabled)
        }
    }

    func testAutomaticAndManualBindingsHaveIndependentScopesWithoutHelper() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .english
            let (model, controller, backend) = fixture()
            defer { _ = controller.end() }
            XCTAssertFalse(model.helperInstalled)
            model.setAutomaticEnabled(true)
            XCTAssertTrue(model.automaticWorkReasonActive); XCTAssertTrue(model.workSessionHolding)
            model.selectManualDuration(900)
            XCTAssertFalse(model.manualSessionActive)
            model.startManualSession(minutes: model.selectedManualMinutes)
            let deadline = try XCTUnwrap(controller.status.manualContinuousDeadline)
            XCTAssertTrue(model.manualSessionActive)
            XCTAssertTrue(try XCTUnwrap(model.activeWorkReasonSummary(at: Date())).contains("Automatic"))
            XCTAssertTrue(try XCTUnwrap(model.activeWorkReasonSummary(at: Date())).contains("Manual"))
            model.setAutomaticEnabled(false)
            XCTAssertTrue(model.manualSessionActive); XCTAssertTrue(model.workSessionHolding)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertFalse(model.automaticWorkReasonActive)
            XCTAssertEqual(model.manualEndingDetail, "Ending this session turns keep-awake off.")
            model.endManualSession()
            XCTAssertFalse(model.workSessionHolding); XCTAssertEqual(backend.releases, 1)
        }
    }

    func testStopAllIsNotClearedByAutomaticToggleAndResumeDoesNotRestoreManual() async {
        await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .english
            let (model, controller, _) = fixture(portable: false)
            defer { _ = controller.end() }
            model.setAutomaticEnabled(true)
            model.startManualSession(minutes: 15)
            model.setEnabled(false)
            XCTAssertTrue(model.workPaused)
            XCTAssertEqual(model.manualStartBlockedDetail, "Choose Resume work before starting a manual session.")
            model.setAutomaticEnabled(false); model.setAutomaticEnabled(true)
            XCTAssertFalse(model.workSessionHolding); XCTAssertFalse(model.manualSessionActive)
            XCTAssertTrue(model.workPaused)
            model.setEnabled(true)
            XCTAssertTrue(model.workSessionHolding)
            XCTAssertFalse(model.manualSessionActive)
        }
    }

    func testMenuBarFollowsObservedWorkAndPreservesItsSizeAcrossTransitions() async {
        await MainActor.run {
            let (model, controller, _) = fixture()
            defer { _ = controller.end() }
            @MainActor func expect(_ icon: AppModel.Icon) {
                let item = model.menuBarItem(at: Date())
                XCTAssertEqual(item.icon, icon)
                XCTAssertNil(item.text); XCTAssertNil(item.ring); XCTAssertNil(item.countdown)
                let label = NSHostingView(rootView: MenuBarLabel(model: model, clock: model.clock))
                XCTAssertEqual(label.fittingSize.width, 18, accuracy: 0.01)
                XCTAssertEqual(label.fittingSize.height, 20, accuracy: 0.01)
            }
            model.setAutomaticEnabled(false); expect(.mark(.off))
            model.setAutomaticEnabled(true); expect(.mark(.on))
            model.startManualSession(minutes: 3); expect(.mark(.held))
            model.setAutomaticEnabled(false)
            XCTAssertTrue(model.workSessionHolding)
            expect(.mark(.held)) // Manual work stays active with the automatic switch off.
            model.endManualSession(); expect(.mark(.off))
            model.setAutomaticEnabled(true); expect(.mark(.on))
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            expect(.mark(.off)) // Enabled trigger does not mean an active request.
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            expect(.mark(.on))
            controller.update(power: .ac, thermal: 2, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            expect(.symbol("shield.lefthalf.filled"))
            XCTAssertFalse(model.workSessionHolding)
        }
    }

    func testMenuBarWarnsForUnconfirmedWorkAndRecoversAfterConfirmation() async {
        await MainActor.run {
            let (model, controller, backend) = fixture()
            defer { _ = controller.end() }
            model.setAutomaticEnabled(false)
            backend.creationFails = true
            model.setAutomaticEnabled(true)
            XCTAssertFalse(model.workSessionHolding)
            XCTAssertNotNil(model.userSessionStatus?.error)
            XCTAssertEqual(model.menuBarItem(at: Date()).icon, .symbol("exclamationmark.triangle"))
            backend.creationFails = false
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            XCTAssertTrue(model.workSessionHolding)
            XCTAssertEqual(model.menuBarItem(at: Date()).icon, .mark(.on))
        }
    }

    func testDesktopHidesLidAndBatteryChoicesWhileBatteryCapsDuration() async {
        await MainActor.run {
            let (desktop, dc, _) = fixture(portable: false)
            let (battery, bc, _) = fixture(power: .battery)
            defer { _ = dc.end(); _ = bc.end() }
            XCTAssertFalse(desktop.showsLidOptions); XCTAssertFalse(desktop.hasInternalBattery)
            XCTAssertEqual(desktop.availablePowerConditions, [.ac])
            desktop.selectManualDuration(nil)
            XCTAssertEqual(desktop.selectedManualMinutes, 0)
            desktop.startUntimedSession()
            XCTAssertTrue(desktop.manualSessionActive); XCTAssertNil(desktop.manualSessionUntil)
            XCTAssertFalse(battery.canStartUnlimitedManualSession)
            XCTAssertEqual(battery.manualDurationChoices, [5, 10, 15, 30, 60, 120])
            XCTAssertLessThanOrEqual(battery.manualMaximumMinutes, 120)
            XCTAssertFalse(bc.start(duration: 7260))
        }
    }

    func testPresetSelectionSavesWithoutStartingAndBatteryOmitsUnlimitedAfterUnplugging() async {
        await MainActor.run {
            let (model, controller, backend) = fixture()
            defer { _ = controller.end() }
            model.setAutomaticEnabled(false)
            XCTAssertEqual(model.manualDurationChoices, [5, 10, 15, 30, 60, 120])
            XCTAssertEqual(model.manualContinuationChoices, [5, 10, 15, 30, 60, 120])
            for minutes in [5, 10, 15, 30, 60, 120] {
                model.selectManualDuration(Double(minutes) * 60)
                model.setManualBatteryContinuationMinutes(minutes)
                XCTAssertEqual(controller.settings.lastManualDurationSeconds, Double(minutes) * 60)
                XCTAssertNil(controller.settings.manualBatteryContinuationMinutes, "Retired continuation never grants execution")
                XCTAssertFalse(model.manualSessionActive)
                XCTAssertFalse(model.workSessionHolding)
                XCTAssertEqual(backend.creates, 0, "Selecting either preset must not acquire a work assertion")
            }

            model.selectManualDuration(nil)
            XCTAssertEqual(model.selectedManualMinutes, 0)
            XCTAssertTrue(model.canStartUnlimitedManualSession)
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            XCTAssertNil(controller.settings.lastManualDurationSeconds, "Power changes must preserve the saved AC default")
            XCTAssertEqual(model.selectedManualMinutes, 120)
            XCTAssertEqual(model.manualDurationChoices, [5, 10, 15, 30, 60, 120])
            XCTAssertFalse(model.canStartUnlimitedManualSession)
            model.startUntimedSession()
            XCTAssertFalse(model.manualSessionActive, "An AC unlimited default cannot start untimed battery work")
            XCTAssertEqual(backend.creates, 0)
        }
    }

    func testLegacyManualDurationKeepsItsDeadlineWhenThePresetDefaultChanges() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            let (model, controller, _) = fixture()
            defer { _ = controller.end() }
            model.selectManualDuration(45 * 60)
            XCTAssertEqual(model.manualDurationChoices, [5, 10, 15, 30, 45, 60, 120])
            for language in [Language.english, .korean] {
                Localization.current = language
                XCTAssertEqual(model.durationChoiceTitle(45), language == .english
                    ? "45 min · Saved" : "45분 · 기존 설정")
                XCTAssertEqual(model.durationChoiceTitle(30), language == .english ? "30 min" : "30분")
            }
            model.startManualSession(minutes: model.selectedManualMinutes)
            let startedAt = try XCTUnwrap(controller.status.manualStartedAt)
            let deadline = try XCTUnwrap(controller.status.manualContinuousDeadline)
            XCTAssertEqual(deadline, startedAt + 45 * 60, accuracy: 0.01)

            model.selectManualDuration(15 * 60)
            XCTAssertEqual(controller.settings.lastManualDurationSeconds, 15 * 60)
            XCTAssertEqual(model.manualDurationChoices, [5, 10, 15, 30, 60, 120])
            XCTAssertTrue(model.manualSessionActive)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline,
                           "Changing the next preset must not retime an active legacy request")
        }
    }

    func testRetiredBatteryContinuationCannotAuthorizeCurrentOrNextManual() async {
        await MainActor.run {
            let (model, controller, _) = fixture(); defer { _ = controller.end() }
            model.setAutomaticEnabled(false); model.startUntimedSession()
            let request = controller.manualRequestID
            model.setManualBatteryContinuationMinutes(120)
            XCTAssertNil(controller.settings.manualBatteryContinuationMinutes)
            XCTAssertEqual(controller.manualRequestID, request)
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                              now: ContinuousTime.now + 1, batteryPercent: 80)
            XCTAssertFalse(model.manualSessionActive)
            XCTAssertFalse(model.workSessionHolding)
        }
    }

    func testRetiredUnplugDurationIsRejectedAndUnplugConsumesUnlimitedManual() async throws {
        await MainActor.run {
            let (model, controller, backend) = fixture(); defer { _ = controller.end() }
            model.setAutomaticEnabled(false)
            let creates = backend.creates
            model.setManualBatteryContinuationMinutes(3)
            XCTAssertNil(controller.settings.manualBatteryContinuationMinutes)
            XCTAssertEqual(backend.creates, creates)
            model.startUntimedSession()
            XCTAssertTrue(model.manualSessionActive)
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                              now: ContinuousTime.now + 1, batteryPercent: 80)
            XCTAssertFalse(model.manualSessionActive); XCTAssertNil(controller.status.manualContinuousDeadline)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                              now: ContinuousTime.now + 2, batteryPercent: 80)
            XCTAssertFalse(model.manualSessionActive)
        }
    }

    func testBatteryStartedRequestKeepsItsExplanationAfterConnectingPower() async {
        await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .english
            let (model, controller, _) = fixture(power: .battery)
            defer { _ = controller.end() }
            model.startManualSession(minutes: 30)
            let deadline = controller.status.manualContinuousDeadline
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertTrue(model.manualBatteryScopeDetail.contains("Unplugging ends existing sessions"))
            controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                              now: ContinuousTime.now + 1, batteryPercent: 80)
            XCTAssertFalse(model.manualSessionActive, "Battery-started work also ends on the next unplug")
        }
    }

    func testProtectionAndUnknownReadingsAreNotPresentedAsReady() async {
        await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .english
            let (model, controller, _) = fixture()
            defer { _ = controller.end() }
            model.setAutomaticEnabled(true)
            controller.update(power: .ac, thermal: 2, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            XCTAssertNotNil(model.workProtectionReason); XCTAssertFalse(model.canResumeWork)
            XCTAssertFalse(model.canStartManualSession); XCTAssertFalse(model.workSessionHolding)
            model.setAutomaticEnabled(false); model.setAutomaticEnabled(true)
            XCTAssertFalse(model.workSessionHolding)
            controller.update(power: .unknown, thermal: nil, fullWake: nil, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: nil)
            XCTAssertEqual(model.observedThermalSummary, "Not confirmed")
            XCTAssertFalse(model.canResumeWork)
        }
    }

    func testLockOffExplainsMacOSPolicyAndNeverClaimsUnlockedRemoteUse() async {
        await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .english
            let (model, controller, _) = fixture()
            defer { _ = controller.end() }
            XCTAssertFalse(model.v3Settings.lockOnClose)
            XCTAssertFalse(model.lockOnCloseDetail.contains("prevent"))
            XCTAssertFalse(model.lockOnCloseDetail.contains("unlocked"))
            XCTAssertTrue(model.lockOnCloseDetail.contains("macOS"))
            XCTAssertEqual(model.lidSupportSummary, "Off")
        }
    }

    func testShippingPanelAndAllPagesRenderAtContractSizesWithReducedTransparency() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            let (model, controller, _) = fixture()
            defer { _ = controller.end() }
            for language in [Language.english, .korean] {
                Localization.current = language
                for active in [false, true] {
                    if active { model.startManualSession(minutes: 30) } else { model.endManualSession() }
                    let panel = NSHostingView(rootView: TetherPanel(model: model)
                        .environment(\.colorScheme, .dark)
                        .environment(\.tetherReduceTransparencyOverride, true)
                        .environment(\.tetherContrastOverride, .increased))
                    XCTAssertEqual(panel.fittingSize.width, 280, accuracy: 0.5)
                    XCTAssertGreaterThan(panel.fittingSize.height, 140,
                        "Compact status, controls and persistent actions still need a readable surface")
                    XCTAssertLessThanOrEqual(panel.fittingSize.height, WorkSessionMetrics.panelMaximumHeight)
                    if !active {
                        // Everyday quick controls should fit without scrolling on a compact screen.
                        XCTAssertLessThanOrEqual(panel.fittingSize.height, 300)
                    }
                    try assertSnapshot(panel, size: panel.fittingSize)
                }
                for page in SettingsPage.allCases {
                    model.settingsPage = page
                    let settings = NSHostingView(rootView: SettingsView(model: model, screenshot: true)
                        .environment(\.colorScheme, .dark)
                        .environment(\.tetherReduceTransparencyOverride, true)
                        .environment(\.tetherContrastOverride, .increased)
                        .frame(width: 560, height: 448))
                    XCTAssertEqual(WorkSessionMetrics.settingsMinimum, CGSize(width: 560, height: 448))
                    XCTAssertEqual(settings.fittingSize.width, 560, accuracy: 0.5)
                    XCTAssertEqual(settings.fittingSize.height, 448, accuracy: 0.5)
                    try assertSnapshot(settings, size: CGSize(width: 560, height: 448))
                }
            }
        }
    }

    func testMenuBodyScrollsAtItsViewportButShortContentDoesNotStretch() async throws {
        try await MainActor.run {
            let short = NSHostingView(rootView: MenuPanelBody(maximumHeight: 180) {
                Text("Short status").frame(height: 40)
            }.frame(width: 280).fixedSize(horizontal: false, vertical: true))
            XCTAssertEqual(short.fittingSize.height, 40, accuracy: 0.5)
            let long = NSHostingView(rootView: MenuPanelBody(maximumHeight: 180) {
                Text(String(repeating: "A long diagnostic message that must remain scrollable. ", count: 40))
                    .fixedSize(horizontal: false, vertical: true).padding(16)
            }.frame(width: 280).fixedSize(horizontal: false, vertical: true))
            XCTAssertEqual(long.fittingSize.height, 180, accuracy: 0.5)
            try assertSnapshot(long, size: long.fittingSize)
        }
    }

    func testMenuRemainsWithinSmallScreenBoundsAcrossLongErrorsProtectionAndHardware() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                for portable in [false, true] {
                    for state in 0..<5 {
                        let (model, controller, _) = fixture(portable: portable)
                        defer { _ = controller.end() }
                        model.errorText = state == 1
                            ? String(repeating: L("Connection failed. Review the helper and recovery status. ",
                                "연결을 확인할 수 없습니다. 도우미 응답과 원복 상태를 확인해 주세요. "), count: 24) : nil
                        if state == 2 { model.startManualSession(minutes: 30) }
                        controller.update(power: state == 4 ? .unknown : .ac, thermal: state == 3 ? 2 : 0,
                            fullWake: true, controllingUser: true, now: ContinuousTime.now,
                            batteryPercent: portable ? 80 : nil)
                        for viewport in [CGFloat(202), CGFloat(360), CGFloat(560)] {
                            let panel = NSHostingView(rootView: TetherPanel(model: model, maximumHeight: viewport)
                                .environment(\.colorScheme, .dark)
                                .environment(\.tetherReduceTransparencyOverride, true))
                            XCTAssertEqual(panel.fittingSize.width, 280, accuracy: 0.5)
                            XCTAssertLessThanOrEqual(panel.fittingSize.height, viewport,
                                "Overflow: language=\(language), portable=\(portable), state=\(state)")
                            try assertSnapshot(panel, size: panel.fittingSize)
                        }
                    }
                }
            }
        }
    }

    func testDetailedActivitySheetRendersWithSimulatedEvidenceOnly() async throws {
        try await MainActor.run {
            let (model, controller, _) = fixture()
            defer { _ = controller.end() }
            let host = NSHostingView(rootView: ActivityReviewView(model: model, sample: true)
                .environment(\.colorScheme, .dark)
                .environment(\.tetherReduceTransparencyOverride, true))
            XCTAssertEqual(host.fittingSize.width, 744, accuracy: 0.5)
            XCTAssertEqual(host.fittingSize.height, 660, accuracy: 0.5)
            try assertSnapshot(host, size: CGSize(width: 744, height: 660))
        }
    }

    @MainActor
    private func assertSnapshot<V: View>(_ host: NSHostingView<V>, size: CGSize) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            // Match the titled AppKit hosting surface used by native Settings.
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        // Match the native preview's hosting-controller lifecycle.
        let controller = NSHostingController(rootView: host.rootView)
        window.contentViewController = controller
        let content = controller.view
        content.frame = CGRect(origin: .zero, size: size); content.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4e, 0x47])
        // PNG encoding smoke test only: it does not establish clipping,
        // readability, Liquid Glass quality, native input or physical power behavior.
    }
}
