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
    var observedLevel: Int? = 255
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        creates += 1
        return creationFails ? (-1, nil) : (0, 31)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
    func level(id: UInt32) -> Int? { observedLevel }
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

    func testRenderLanguagePickerUsesTheSimulatedLanguage() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                let model = PreviewRenderer.sampleModel(arguments: ["--sample"])
                defer { _ = model.userSession?.end() }
                XCTAssertEqual(model.language, language == .english ? .english : .korean)
                XCTAssertEqual(model.defaults.string(forKey: Localization.defaultsKey), model.language.rawValue)
                XCTAssertFalse(model.defaults === UserDefaults.standard)
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

        // SwiftUI owns native tab/toolbar glass and titlebar layout. Reopening
        // must preserve that host chrome while restoring resize affordances.
        let nativeToolbar = NSToolbar(identifier: "settings-reopen-regression")
        window.toolbar = nativeToolbar
        window.toolbar?.isVisible = true
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove(.resizable)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(window.toolbar === nativeToolbar)
        XCTAssertEqual(window.toolbar?.isVisible, true,
            "Reopening must preserve the native toolbar's Liquid Glass")
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView),
            "The bridge must leave SwiftUI's native titlebar layout intact")
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
        XCTAssertTrue(window.toolbar === nativeToolbar)
        XCTAssertEqual(window.toolbar?.isVisible, true)
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

    func testSettingsNavigationPreservesPageIdentitiesAndSeparatesFourResponsibilities() async {
        await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            XCTAssertEqual(SettingsPage.allCases.map(\.rawValue), ["safety", "general", "protection", "system"],
                "Saved page identities must remain compatible while sidebar order follows the task flow")
            Localization.current = .english
            XCTAssertEqual(SettingsPage.allCases.map(\.title),
                ["Power & Lid", "Manual", "Protection & Diagnostics", "General"])
            XCTAssertEqual(SettingsPage.allCases.map(\.shortTitle), ["Power & Lid", "Manual", "Protection", "General"],
                "A compact visible label must retain a distinct complete accessible title")
            Localization.current = .korean
            XCTAssertEqual(SettingsPage.allCases.map(\.title), ["전원·덮개", "직접 유지", "보호·진단", "일반"])
            XCTAssertEqual(SettingsPage.allCases.map(\.shortTitle), ["전원·덮개", "직접 유지", "보호·진단", "일반"])
            XCTAssertEqual(Set(SettingsPage.allCases.map(\.title)).count, 4)
        }
    }

    func testActiveDiagnosticRecordingRemainsAvailableAcrossPageRecreationAndStopsWithoutPowerWork() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            Localization.current = .english
            let (model, controller, backend) = fixture()
            defer { _ = controller.end() }
            let savedIntent = model.defaults.data(forKey: UserSessionController.preferenceKey)
            let initialRow = ProtectionPage(model: model).activeRecordingStatus
            let inactive = NSHostingView(rootView: initialRow.frame(width: 400))
            XCTAssertEqual(inactive.fittingSize.height, 0, accuracy: 0.5,
                "Inactive recording must not add a status row to compact Protection & Diagnostics")

            model.setDebugLogging(true, minutes: 15)
            XCTAssertTrue(model.diagnosticRecordingActive)
            let until = try XCTUnwrap(model.diagnosticRecordingUntil)
            XCTAssertEqual(until.timeIntervalSinceNow, 900, accuracy: 2)

            // Rebuilding the page resets its disclosure State. The active row
            // reads controller state, independently of that collapsed detail.
            for _ in 0..<2 {
                model.settingsPage = .general
                model.settingsPage = .protection
                let row = ProtectionPage(model: model).activeRecordingStatus
                let active = NSHostingView(rootView: row.frame(width: 400))
                XCTAssertGreaterThan(active.fittingSize.height, 28,
                    "Reconstructed Protection & Diagnostics must still render status, deadline and Stop")
                XCTAssertEqual(row.recordingDetail, "Recording until \(Texts.time(until))")
                XCTAssertTrue(row.model.canRecordDiagnostics)
                XCTAssertEqual(model.diagnosticRecordingUntil, until,
                    "Page reconstruction must not restart the recording deadline")
            }

            // Exercise the same action used by the visible Stop button, without
            // synthesizing GUI input or changing installed application state.
            let recordingEndedBefore = model.commonActivity.filter { $0.kind == .recordingEnded }.count
            ProtectionPage(model: model).activeRecordingStatus.stopRecording()
            XCTAssertFalse(model.diagnosticRecordingActive)
            XCTAssertNil(model.diagnosticRecordingUntil)
            let stopped = NSHostingView(rootView: ProtectionPage(model: model).activeRecordingStatus.frame(width: 400))
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
    private func fixture(portable: Bool = true, power: PowerSource = .ac, displayBackend: LiveUIAssertion? = nil)
        -> (AppModel, UserSessionController, LiveUIAssertion) {
        let defaults = LiveUIDefaults(), backend = LiveUIAssertion()
        let controller = UserSessionController(defaults: defaults, backend: backend,
            displayBackend: displayBackend ?? LiveUIAssertion(),
            guiProbe: nil, environmentProbe: nil, boot: "ui-fixture")
        controller.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: portable ? 80 : nil)
        let model = AppModel(preview: true,
            capabilities: MacCapabilities(supportedPlatform: true, internalBattery: portable, lid: portable),
            previewSession: controller, previewDefaults: defaults)
        return (model, controller, backend)
    }

    @MainActor
    func testLidWarningFollowsCapturedManualOptionInsteadOfNextRequestDefaults() throws {
        for requested in [false, true] {
            let (model, controller, _) = fixture()
            defer { _ = controller.end() }
            controller.setAllowClosedLid(true)
            var options = controller.settings.v4
            options.nextManualOptions.closedLid = requested
            XCTAssertTrue(controller.setV4Settings(options))
            XCTAssertTrue(controller.start(duration: 1800))
            let requestID = controller.manualRequestID
            let deadline = controller.status.manualContinuousDeadline
            XCTAssertTrue(model.workSessionHolding)
            XCTAssertFalse(model.helperSetupConfirmed)
            XCTAssertEqual(controller.v4LidRequested, requested)
            XCTAssertEqual(TetherPanel(model: model).needsLidReview, requested)
            options.nextManualOptions.closedLid = !requested
            XCTAssertTrue(controller.setV4Settings(options))
            XCTAssertEqual(TetherPanel(model: model).needsLidReview, requested,
                "Editing the next request cannot change the current timer's lid demand")
            XCTAssertEqual(controller.manualRequestID, requestID)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
        }
    }

    @MainActor
    func testSpentAutomaticBatteryBudgetUsesEndedTitleAndExplanationInBothLanguages() throws {
        let previous = Localization.current
        defer { Localization.current = previous }
        for language in [Language.english, .korean] {
            Localization.current = language
            for advanced in [false, true] {
                let defaults = LiveUIDefaults()
                var settings = IdleSessionSettings()
                settings.legacyRootConfigurationPending = false
                settings.automaticEnabled = true
                settings.automaticPowerCondition = .battery
                if advanced { settings.v4 = advancedFixtureRules(from: settings.v4) }
                settings.runtimeMarkers = .init(automaticActivation:
                    .init(condition: .battery, batteryConsumed: true, batteryExpired: true, batteryLimit: .thirtyMinutes))
                defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
                let controller = UserSessionController(defaults: defaults, backend: LiveUIAssertion(),
                    displayBackend: LiveUIAssertion(), guiProbe: nil, environmentProbe: nil, boot: "ui-fixture")
                defer { _ = controller.end() }
                controller.v4ConditionSource.queryOverride = { _, _ in (.notSatisfied, nil) }
                controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
                let model = AppModel(preview: true, capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
                    previewSession: controller, previewDefaults: defaults)
                let panel = TetherPanel(model: model)
                let saved = defaults.data(forKey: UserSessionController.preferenceKey)
                XCTAssertEqual(model.v3Settings.condition, .battery, "Legacy saved range is preserved in either mode")
                XCTAssertEqual(model.automaticBatteryEnded, advanced,
                    "A legacy battery marker is relevant to explicit advanced scope, not the AC-only basic mode")
                XCTAssertEqual(panel.statusTitle, advanced
                    ? L("Automatic battery session ended", "자동 배터리 유지 종료")
                    : L("Waiting to start automatically", "자동 시작 대기 중"))
                XCTAssertEqual(panel.statusDetail, advanced ? model.presentation.subtitle : nil)
                XCTAssertFalse(model.workSessionHolding)
                XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), saved)
                XCTAssertTrue(controller.start(duration: 1800))
                XCTAssertFalse(model.automaticBatteryEnded)
                XCTAssertEqual(panel.statusTitle, L("Timer active", "타이머 실행 중"),
                    "A new manual timer must take precedence over the spent automatic marker")
            }
        }
    }

    @MainActor
    func testCurrentAutomaticSummaryKeepsCapturedPowerWhenNextConditionChanges() throws {
        let previous = Localization.current
        defer { Localization.current = previous }
        for language in [Language.english, .korean] {
            Localization.current = language
            for captured in [PowerCondition.ac, .battery, .any] {
                for advanced in [false, true] {
                    let power: PowerSource = advanced && captured == .battery ? .battery : .ac
                    let (model, controller, backend) = fixture(power: power)
                    defer { _ = controller.end() }
                    model.setPowerCondition(captured)
                    if advanced {
                        controller.v4ConditionSource.queryOverride = { _, _ in (.satisfied, nil) }
                        XCTAssertTrue(controller.setV4Settings(advancedFixtureRules(from: controller.v4Settings)))
                    }
                    model.setAutomaticEnabled(true)
                    if advanced {
                        // Provider observations use their own real timestamp;
                        // advance this nonobserving fixture beyond that sample
                        // before expecting the advanced gate to be satisfied.
                        controller.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                            now: ContinuousTime.now, batteryPercent: 80)
                    }
                    XCTAssertTrue(model.automaticWorkReasonActive, "captured=\(captured) advanced=\(advanced)")
                    let effectiveCaptured: PowerCondition = advanced ? captured : .ac
                    let activation = try XCTUnwrap(controller.runtimeMarkers.automaticActivation).id
                    XCTAssertEqual(controller.runtimeMarkers.automaticActivation?.condition, effectiveCaptured)
                    let next: PowerCondition = captured == .battery ? .ac : .battery
                    model.setPowerCondition(next)
                    XCTAssertEqual(model.v3Settings.condition, next)
                    XCTAssertTrue(model.automaticWorkReasonActive)
                    let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                    let creates = backend.creates
                    let panel = TetherPanel(model: model)
                    XCTAssertEqual(panel.currentAutomaticSummary, advanced
                        ? effectiveCaptured.title + " · " + model.v4RuleSummary : effectiveCaptured.title)
                    if advanced {
                        XCTAssertNotEqual(panel.currentAutomaticSummary, model.v4RuleSummary,
                            "The advanced summary must retain the current activation's captured power prefix")
                    } else {
                        XCTAssertEqual(model.v4RuleSummary, PowerCondition.ac.title,
                            "Basic mode always reports effective AC, while retaining the saved advanced range")
                    }
                    XCTAssertEqual(controller.runtimeMarkers.automaticActivation?.id, activation)
                    XCTAssertEqual(controller.runtimeMarkers.automaticActivation?.condition, effectiveCaptured)
                    if advanced {
                        XCTAssertTrue(model.activeWorkReasonSummary(at: Date())?.contains(effectiveCaptured.title) == true,
                            "An advanced battery activation must not be described as adapter-connected work")
                    }
                    XCTAssertEqual(backend.creates, creates)
                    XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
                }
            }
        }
    }

    /// Advanced scope is explicit; a stored battery/any value alone is not a
    /// request to leave the AC-only basic mode. Providers remain memory fixtures.
    @MainActor
    private func advancedFixtureRules(from existing: V4Settings) -> V4Settings {
        var settings = existing
        let preset = V4Preset(id: UUID(), name: "Selected conditions",
            groups: [V4RuleGroup(id: UUID(), conditions: [
                V4Condition(id: UUID(), kind: .appRunning, target: "fixture.editor")
            ])])
        settings.automaticMode = .advanced
        settings.presets = [preset]; settings.activePresetID = preset.id
        return settings
    }

    @MainActor
    func testPreparedLidPreviewTogglePreservesRequestDisplayAndStopStateUsingOnlyRenderHelper() async throws {
        let scenarios = [
            ["--sample", "--prepared-lid", "--display-on"],
            ["--sample", "--manual", "--timed", "--prepared-lid", "--display-on"],
            ["--sample", "--manual", "--timed", "--prepared-lid", "--display-on", "--paused"],
            ["--sample", "--manual", "--timed", "--prepared-lid", "--display-on", "--protection"]
        ]
        for arguments in scenarios {
            let model = PreviewRenderer.sampleModel(arguments: arguments)
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            let paused = arguments.contains("--paused") || arguments.contains("--protection")
            for _ in 0..<1000 {
                if model.helperSetupConfirmed, !model.lidCommandPending,
                   paused || model.lidSupportConfirmed { break }
                await Task.yield()
            }
            XCTAssertFalse(model.defaults === UserDefaults.standard)
            XCTAssertTrue(model.userCommandsArePreview)
            XCTAssertTrue(model.helperSetupConfirmed, arguments.joined(separator: " "))
            XCTAssertFalse(model.lidCommandPending)
            let helper = try await model.performWorkService(ServiceRequest(.snapshot))
            XCTAssertEqual(helper.epoch, "render-only-helper")
            XCTAssertEqual(helper.protection?.dryRun, true)

            let requestID = controller.manualRequestID
            let deadline = controller.status.manualContinuousDeadline
            let automatic = model.automaticWorkReasonActive
            let automaticChoice = model.automaticEnabled
            let displayHolding = controller.status.displayHolding
            let markers = controller.runtimeMarkers
            if arguments.contains("--manual"), !paused {
                XCTAssertNotNil(requestID)
                XCTAssertNotNil(deadline)
            }
            if paused {
                XCTAssertFalse(TetherPanel(model: model).needsLidReview,
                    "A stopped or protected session is not a helper setup failure")
                XCTAssertTrue(model.workPaused)
                XCTAssertFalse(model.workSessionHolding)
                XCTAssertNil(requestID)
                XCTAssertNil(deadline)
            }
            let controls = MenuKeepAwakeControls(model: model, openHelperSetup: {})
            XCTAssertFalse(controls.lidControlDisabled)
            for allowed in [false, true] {
                controls.lidBinding.wrappedValue = allowed
                for _ in 0..<1000 {
                    if !model.lidCommandPending,
                       model.v3Settings.allowClosedLid == allowed,
                       !allowed || paused || model.lidSupportConfirmed { break }
                    await Task.yield()
                }
                XCTAssertFalse(model.lidCommandPending)
                XCTAssertEqual(controls.lidBinding.wrappedValue, allowed)
                if allowed && !paused { XCTAssertTrue(model.lidSupportConfirmed) }
                XCTAssertEqual(controller.manualRequestID, requestID)
                XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
                XCTAssertEqual(controller.runtimeMarkers, markers)
                XCTAssertTrue(model.v3Settings.keepDisplayAwake)
                XCTAssertEqual(controller.status.displayHolding, displayHolding)
                XCTAssertEqual(model.automaticWorkReasonActive, automatic)
                XCTAssertEqual(model.automaticEnabled, automaticChoice)
                XCTAssertEqual(model.workPaused, paused)
                if paused {
                    XCTAssertFalse(model.workSessionHolding, "A prepared lid permission cannot resume stopped work")
                    XCTAssertFalse(model.manualSessionActive)
                    XCTAssertFalse(model.automaticWorkReasonActive)
                    XCTAssertEqual(model.status?.ownsOverride, false)
                }
            }
        }
    }

    func testMenuDisplayBindingAppliesToCurrentAndNextWorkWithoutReplacingManualOrAutomaticIntent() async throws {
        try await MainActor.run {
            let display = LiveUIAssertion()
            let (model, controller, backend) = fixture(displayBackend: display)
            defer { _ = controller.end() }
            model.setAutomaticEnabled(true)
            model.startManualSession(minutes: 30)
            let requestID = try XCTUnwrap(controller.manualRequestID)
            let deadline = try XCTUnwrap(controller.status.manualContinuousDeadline)
            let markers = controller.runtimeMarkers
            let controls = MenuKeepAwakeControls(model: model, openHelperSetup: {})
            XCTAssertFalse(controls.controlsDisabled)
            XCTAssertFalse(controls.displayBinding.wrappedValue)

            controls.displayBinding.wrappedValue = true
            XCTAssertTrue(model.v3Settings.keepDisplayAwake)
            XCTAssertEqual(controller.status.keepDisplayAwake, true)
            XCTAssertEqual(controller.status.displayHolding, true)
            XCTAssertEqual(display.creates, 1)
            controls.displayBinding.wrappedValue = false
            XCTAssertFalse(model.v3Settings.keepDisplayAwake)
            XCTAssertEqual(controller.status.displayHolding, false)
            XCTAssertEqual(display.releases, 1)
            controls.displayBinding.wrappedValue = true
            XCTAssertEqual(controller.status.displayHolding, true)
            XCTAssertEqual(display.creates, 2)

            XCTAssertEqual(controller.manualRequestID, requestID)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertEqual(controller.runtimeMarkers, markers)
            XCTAssertTrue(model.automaticWorkReasonActive)
            XCTAssertTrue(model.manualSessionActive)
            XCTAssertEqual(backend.creates, 1)
            XCTAssertEqual(backend.releases, 0)
            let saved = try XCTUnwrap(model.defaults.data(forKey: UserSessionController.preferenceKey))
            XCTAssertTrue(try JSONDecoder().decode(IdleSessionSettings.self, from: saved).keepDisplayAwake)

            model.endManualSession()
            XCTAssertTrue(model.automaticWorkReasonActive)
            XCTAssertEqual(controller.status.displayHolding, true)
            model.startManualSession(minutes: 15)
            XCTAssertNotEqual(controller.manualRequestID, requestID)
            XCTAssertTrue(model.manualSessionActive)
            XCTAssertEqual(controller.status.displayHolding, true)
            XCTAssertEqual(display.creates, 2, "The next work uses the existing selected display request")
            XCTAssertEqual(backend.creates, 1)
        }
    }

    func testMenuDisplayBindingEditsDuringStopOrProtectionNeverResumeWorkOrRestoreATimer() async throws {
        try await MainActor.run {
            for protection in [false, true] {
                let display = LiveUIAssertion()
                let (model, controller, backend) = fixture(displayBackend: display)
                defer { _ = controller.end() }
                model.setAutomaticEnabled(true)
                model.startManualSession(minutes: 30)
                XCTAssertNotNil(controller.manualRequestID)
                if protection {
                    controller.update(power: .ac, thermal: 2, fullWake: true, controllingUser: true,
                        now: ContinuousTime.now, batteryPercent: 80)
                } else {
                    model.setEnabled(false)
                }
                XCTAssertTrue(model.workPaused)
                let markers = controller.runtimeMarkers
                let creates = backend.creates, releases = backend.releases
                let controls = MenuKeepAwakeControls(model: model, openHelperSetup: {})
                XCTAssertFalse(controls.controlsDisabled, "Stopped work can edit a future display choice")
                for selected in [true, false, true] {
                    controls.displayBinding.wrappedValue = selected
                    XCTAssertEqual(model.v3Settings.keepDisplayAwake, selected)
                    XCTAssertEqual(controller.runtimeMarkers, markers)
                    XCTAssertTrue(model.workPaused)
                    XCTAssertTrue(model.automaticEnabled)
                    XCTAssertFalse(model.workSessionHolding)
                    XCTAssertFalse(model.manualSessionActive)
                    XCTAssertNil(controller.manualRequestID)
                    XCTAssertNil(controller.status.manualContinuousDeadline)
                    XCTAssertEqual(controller.status.displayHolding, false)
                }
                XCTAssertEqual(backend.creates, creates)
                XCTAssertEqual(backend.releases, releases)
                XCTAssertEqual(display.creates, 0, "Saving a display choice is not approval to resume stopped work")
                XCTAssertEqual(display.releases, 0)
            }
        }
    }

    func testMenuLidBindingCannotEnableUnpreparedNotebookOrDesktopAndDoesNotBlockDisplayChoices() async {
        await MainActor.run {
            for portable in [true, false] {
                let display = LiveUIAssertion()
                let (model, controller, backend) = fixture(portable: portable, displayBackend: display)
                defer { _ = controller.end() }
                var setupRequests = 0
                let controls = MenuKeepAwakeControls(model: model, openHelperSetup: { setupRequests += 1 })
                XCTAssertEqual(model.showsLidOptions, portable)
                XCTAssertFalse(model.helperSetupConfirmed)
                XCTAssertTrue(controls.lidControlDisabled)
                XCTAssertFalse(controls.controlsDisabled)
                let before = controller.status
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                controls.lidBinding.wrappedValue = true
                XCTAssertFalse(model.v3Settings.allowClosedLid)
                XCTAssertFalse(controls.lidBinding.wrappedValue)
                XCTAssertEqual(controller.status, before)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
                XCTAssertEqual(setupRequests, 0, "A disabled binding must not start helper setup")

                controls.displayBinding.wrappedValue = true
                XCTAssertTrue(model.v3Settings.keepDisplayAwake)
                XCTAssertFalse(model.v3Settings.allowClosedLid)
                XCTAssertFalse(model.workSessionHolding)
                XCTAssertEqual(display.creates, 0, "Display selection alone does not start work")
                XCTAssertEqual(backend.creates, 0)
            }
        }
    }

    func testMenuDisplayStatusSeparatesSavedChoiceActiveRequestPauseAndUnconfirmedExecution() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                let display = LiveUIAssertion()
                let (model, controller, backend) = fixture(displayBackend: display)
                defer { _ = controller.end() }
                let controls = MenuKeepAwakeControls(model: model, openHelperSetup: {})
                XCTAssertEqual(controls.displayStatusDetail, L("Display sleep follows macOS", "화면 절전은 macOS에 맡김"))
                controls.displayBinding.wrappedValue = true
                XCTAssertEqual(controls.displayStatusDetail, L("Applies when work starts", "작업이 시작되면 적용"))

                var next = controller.v4Settings
                next.nextManualOptions.display = false
                XCTAssertTrue(controller.setV4Settings(next))
                model.startManualSession(minutes: 30)
                XCTAssertTrue(model.workSessionHolding)
                XCTAssertEqual(controller.status.displayHolding, false)
                XCTAssertEqual(controls.displayStatusDetail,
                    L("Enabled · not currently applied", "선택 켬 · 현재 화면 유지는 미적용"),
                    "A saved global choice is not proof that this request's options include display keeping")

                model.setEnabled(false)
                XCTAssertEqual(controls.displayStatusDetail,
                    L("Choice saved · work is stopped", "선택 저장됨 · 작업은 중지 중"))
                model.setEnabled(true)
                next = controller.v4Settings; next.nextManualOptions.display = true
                XCTAssertTrue(controller.setV4Settings(next))
                model.startManualSession(minutes: 30)
                XCTAssertEqual(controller.status.displayHolding, true)
                XCTAssertEqual(controls.displayStatusDetail,
                    L("Display kept awake · macOS lock policy applies", "화면 유지 중 · 잠금은 macOS 설정"))

                display.observedLevel = nil
                controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
                XCTAssertTrue(model.v3Settings.keepDisplayAwake)
                XCTAssertEqual(controller.status.displayHolding, false)
                XCTAssertNotNil(controller.status.displayError)
                let before = controller.status
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                let creates = backend.creates, releases = backend.releases
                let displayCreates = display.creates, displayReleases = display.releases
                for _ in 0..<3 {
                    XCTAssertEqual(controls.displayStatusDetail,
                        L("Display keep-awake needs review", "화면 유지 확인 필요"))
                }
                XCTAssertEqual(controller.status, before)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
                XCTAssertEqual(backend.creates, creates); XCTAssertEqual(backend.releases, releases)
                XCTAssertEqual(display.creates, displayCreates); XCTAssertEqual(display.releases, displayReleases)
            }
        }
    }

    func testSavedDefaultsNotifyViewsAndAdvanceRevisionWithoutRedrawingUnchangedChoices() async {
        await MainActor.run {
            let (model, controller, backend) = fixture(); defer { _ = controller.end() }
            model.selectManualDuration(900)
            let originalStatus = controller.status
            let originalCreates = backend.creates
            let originalGeneration = model.v4ConfigurationGeneration
            var changes = 0
            let observation = model.objectWillChange.sink { changes += 1 }; defer { observation.cancel() }
            model.selectManualDuration(2700)
            XCTAssertEqual(model.selectedManualMinutes, 45)
            XCTAssertEqual(model.manualDurationChoices, [5, 10, 15, 30, 45, 60, 120])
            XCTAssertEqual(controller.settings.lastManualDurationSeconds, 2700)
            XCTAssertEqual(controller.status, originalStatus)
            XCTAssertGreaterThan(changes, 0)
            XCTAssertEqual(model.v4ConfigurationGeneration, originalGeneration + 1)
            let durationChanges = changes
            model.selectManualDuration(2700)
            for invalid in [0, -60, Double.infinity, Double.nan, Double.greatestFiniteMagnitude] {
                model.selectManualDuration(invalid)
            }
            XCTAssertEqual(model.selectedManualMinutes, 45)
            XCTAssertEqual(changes, durationChanges, "Unchanged or rejected choices must not redraw views")
            XCTAssertEqual(model.v4ConfigurationGeneration, originalGeneration + 1)
            model.setAllowClosedLid(true)
            XCTAssertTrue(model.v3Settings.allowClosedLid)
            XCTAssertEqual(controller.status, originalStatus)
            XCTAssertGreaterThan(changes, durationChanges)
            XCTAssertEqual(model.v4ConfigurationGeneration, originalGeneration + 2)
            let lidChanges = changes
            model.setAllowClosedLid(true)
            XCTAssertEqual(changes, lidChanges)
            model.setDisconnectAction(.followOS)
            XCTAssertEqual(model.v3Settings.disconnectAction, .followOS)
            XCTAssertEqual(controller.status, originalStatus)
            XCTAssertGreaterThan(changes, lidChanges)
            XCTAssertEqual(model.v4ConfigurationGeneration, originalGeneration + 3)
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
            XCTAssertEqual(model.presentation.title, "Waiting after Sleep request")
            XCTAssertEqual(model.manualStartBlockedDetail, "Choose Resume before starting a manual session.")
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
            XCTAssertEqual(model.presentation.title, "Waiting after Sleep request")
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
                try assertSnapshot(NSHostingView(rootView: GeneralPage(model: model)), size: CGSize(width: 640, height: 480))
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

    func testAutomaticWaitingCopyRequiresAdvancedConditionsAndDoesNotChangeWork() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                let (model, controller, backend) = fixture(power: .battery)
                defer { _ = controller.end() }
                let panel = TetherPanel(model: model)
                model.setAutomaticEnabled(false)
                XCTAssertNil(panel.automaticStartWaitingDetail)

                model.setAutomaticEnabled(true)
                XCTAssertEqual(panel.automaticStartWaitingDetail,
                    L("Starts when power is connected", "전원을 연결하면 시작합니다"))

                var settings = controller.v4Settings
                let preset = V4Preset(id: UUID(), name: "Editing work",
                    groups: [V4RuleGroup(id: UUID(), conditions: [
                        V4Condition(id: UUID(), kind: .appRunning, target: "fixture.editor")
                    ])])
                settings.automaticMode = .advanced
                settings.presets = [preset]; settings.activePresetID = preset.id
                controller.v4ConditionSource.queryOverride = { _, _ in (.notSatisfied, nil) }
                XCTAssertTrue(controller.setV4Settings(settings))
                let status = controller.status
                let creates = backend.creates
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                XCTAssertEqual(panel.automaticStartWaitingDetail,
                    L("Requires AC power and matching advanced conditions", "전원 연결과 선택한 고급 조건을 모두 만족해야 시작합니다"))
                XCTAssertTrue(model.v4RuleSummary.contains("Editing work"))
                XCTAssertEqual(controller.status, status, "Reading the waiting copy must not start or end work")
                XCTAssertEqual(backend.creates, creates)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)

                let now = ContinuousTime.now
                controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                                  now: now + 1, batteryPercent: 80)
                XCTAssertEqual(panel.automaticStartWaitingDetail,
                    L("Waiting for the selected conditions", "선택한 조건을 기다리는 중"),
                    "Matching power must describe the unmet advanced conditions, not ask for reconnection")
                XCTAssertFalse(model.automaticWorkReasonActive, "AC alone cannot satisfy an unmet advanced condition")

                controller.update(power: .unknown, thermal: 0, fullWake: true, controllingUser: true,
                                  now: now + 2, batteryPercent: 80)
                XCTAssertFalse(model.workPaused, "Unknown alone is not a confirmed unsafe value or an unplug event")
                XCTAssertEqual(panel.automaticStartWaitingDetail,
                    L("Checking power before evaluating automatic starts", "전원 상태를 확인한 뒤 자동 시작 조건을 확인합니다"))
                XCTAssertEqual(backend.creates, creates, "Unconfirmed power never starts an unconditional automatic request")
                XCTAssertFalse(model.workSessionHolding)
            }
        }
    }

    func testAutomaticWaitingCopyReflectsAllPowerChoicesWithoutMutatingWork() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            let powerCases: [(condition: PowerCondition, power: PowerSource, matches: Bool)] = [
                (.ac, .ac, true), (.ac, .battery, false),
                (.battery, .ac, false), (.battery, .battery, true),
                (.any, .ac, true), (.any, .battery, true)
            ]
            for language in [Language.english, .korean] {
                Localization.current = language
                for sample in powerCases {
                    for advanced in [false, true] {
                        let (model, controller, backend) = fixture(power: sample.power)
                        defer { _ = controller.end() }
                        model.setPowerCondition(sample.condition)
                        if advanced {
                            var settings = controller.v4Settings
                            let preset = V4Preset(id: UUID(), name: "Selected conditions",
                                groups: [V4RuleGroup(id: UUID(), conditions: [
                                    V4Condition(id: UUID(), kind: .appRunning, target: "fixture.editor")
                                ])])
                            settings.automaticMode = .advanced
                            settings.presets = [preset]; settings.activePresetID = preset.id
                            controller.v4ConditionSource.queryOverride = { _, _ in (.notSatisfied, nil) }
                            XCTAssertTrue(controller.setV4Settings(settings))
                        }
                        model.setAutomaticEnabled(true)
                        let effectiveCondition: PowerCondition = advanced ? sample.condition : .ac
                        let powerMatches = advanced ? sample.matches : sample.power == .ac
                        XCTAssertEqual(model.v3Settings.condition, sample.condition,
                            "Displaying effective basic AC must not rewrite the saved advanced range")
                        XCTAssertEqual(model.automaticWorkReasonActive, powerMatches && !advanced,
                            "Only an eligible AC-only basic rule may already be active")
                        let panel = TetherPanel(model: model)
                        let before = controller.status
                        let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                        let creates = backend.creates, releases = backend.releases
                        let expected: String?
                        if powerMatches {
                            expected = advanced ? L("Waiting for the selected conditions", "선택한 조건을 기다리는 중") : nil
                        } else if effectiveCondition == .battery {
                            expected = advanced
                                ? L("Requires battery power and matching conditions", "배터리 사용과 선택한 조건을 모두 만족해야 시작합니다")
                                : L("Starts when using battery power", "배터리 사용 시 시작합니다")
                        } else {
                            expected = advanced
                                ? L("Requires AC power and matching advanced conditions", "전원 연결과 선택한 고급 조건을 모두 만족해야 시작합니다")
                                : L("Starts when power is connected", "전원을 연결하면 시작합니다")
                        }
                        for _ in 0..<3 {
                            XCTAssertEqual(panel.automaticStartWaitingDetail, expected,
                                "\(sample.condition) / \(sample.power) / advanced=\(advanced)")
                        }
                        XCTAssertEqual(controller.status, before)
                        XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
                        XCTAssertEqual(backend.creates, creates)
                        XCTAssertEqual(backend.releases, releases)
                    }
                }
            }
        }
    }

    func testDisconnectSummaryReflectsEveryPolicyWithoutRetimingActiveManualWork() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                let (model, controller, backend) = fixture()
                defer { _ = controller.end() }
                model.startManualSession(minutes: 30)
                let requestID = try XCTUnwrap(controller.manualRequestID)
                let deadline = try XCTUnwrap(controller.status.manualContinuousDeadline)
                let summaries: [(WorkSessionDisconnectPolicy, String)] = [
                    (.endAll, L("Unplug: end all sessions", "전원 분리 시 모두 종료")),
                    (.endAutomatic, L("Unplug: end automatic sessions", "전원 분리 시 자동 유지 종료")),
                    (.continueEligible, L("Unplug: continue eligible sessions", "전원 분리 시 허용된 유지 계속"))
                ]
                let panel = TetherPanel(model: model)
                for (policy, expected) in summaries {
                    model.setDisconnectPolicy(policy)
                    XCTAssertEqual(model.v3Settings.disconnectPolicy, policy)
                    let before = controller.status
                    let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                    let creates = backend.creates, releases = backend.releases
                    for _ in 0..<3 { XCTAssertEqual(panel.disconnectPolicySummary, expected) }
                    XCTAssertEqual(controller.status, before)
                    XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
                    XCTAssertEqual(controller.manualRequestID, requestID)
                    XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
                    XCTAssertTrue(model.manualSessionActive)
                    XCTAssertEqual(backend.creates, creates)
                    XCTAssertEqual(backend.releases, releases)
                }
            }
        }
    }

    func testBatteryUnlimitedCopyUsesCapturedLimitAndUnknownPowerNeverPromisesUnlimited() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                let (model, controller, backend) = fixture(power: .battery)
                defer { _ = controller.end() }
                model.setBatteryTimeLimit(.unlimited)
                XCTAssertTrue(controller.start(duration: nil))
                let requestID = try XCTUnwrap(controller.manualRequestID)
                let controls = ManualSessionControls(model: model, clock: model.clock)
                XCTAssertNil(model.manualSessionUntil)
                XCTAssertTrue(try XCTUnwrap(controller.v4ManualSnapshot).confirmed)
                XCTAssertEqual(controller.v4ManualSnapshot?.batteryTimeLimit, .unlimited)
                XCTAssertTrue(controls.hasConfirmedUnlimitedDuration)
                XCTAssertEqual(controls.remainingDescription, L("Until turned off", "끄기 전까지"))

                model.setBatteryTimeLimit(.thirtyMinutes)
                XCTAssertEqual(model.v3Settings.batteryTimeLimit, .thirtyMinutes)
                XCTAssertEqual(controller.v4ManualSnapshot?.batteryTimeLimit, .unlimited,
                    "Changing the next default cannot turn the current explicit unlimited request into a timer")
                XCTAssertEqual(controller.manualRequestID, requestID)
                XCTAssertNil(controller.status.manualContinuousDeadline)
                let before = controller.status
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                let creates = backend.creates, releases = backend.releases
                for _ in 0..<3 {
                    XCTAssertTrue(controls.hasConfirmedUnlimitedDuration)
                    XCTAssertEqual(controls.remainingDescription, L("Until turned off", "끄기 전까지"))
                }
                XCTAssertEqual(controller.status, before)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
                XCTAssertEqual(backend.creates, creates); XCTAssertEqual(backend.releases, releases)

                controller.update(power: .unknown, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
                XCTAssertTrue(model.manualSessionActive, "Unknown input does not erase the already-issued request")
                let unknown = controller.status
                let unknownSaved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                for _ in 0..<3 {
                    XCTAssertFalse(controls.hasConfirmedUnlimitedDuration)
                    XCTAssertEqual(controls.remainingDescription, L("Checking deadline", "마감 확인 중"))
                }
                XCTAssertEqual(controller.status, unknown)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), unknownSaved)
                XCTAssertEqual(controller.manualRequestID, requestID)
                XCTAssertEqual(backend.creates, creates); XCTAssertEqual(backend.releases, releases)
            }
        }
    }

    func testUnconfirmedBatteryRequestCannotAdvertiseUnlimitedEvenWithCapturedUnlimitedLimit() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                let (model, controller, backend) = fixture(power: .battery)
                defer { _ = controller.end() }
                model.setBatteryTimeLimit(.unlimited)
                XCTAssertTrue(controller.start(duration: nil))
                let requestID = try XCTUnwrap(controller.manualRequestID)
                let controls = ManualSessionControls(model: model, clock: model.clock)
                XCTAssertTrue(controls.hasConfirmedUnlimitedDuration)

                backend.observedLevel = nil
                controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
                model.setBatteryTimeLimit(.twoHours)
                XCTAssertTrue(model.manualSessionActive)
                XCTAssertNil(model.manualSessionUntil)
                XCTAssertEqual(controller.v4ManualSnapshot?.batteryTimeLimit, .unlimited)
                XCTAssertEqual(controller.v4ManualSnapshot?.confirmed, false)
                let before = controller.status
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                let creates = backend.creates, releases = backend.releases
                for _ in 0..<3 {
                    XCTAssertFalse(controls.hasConfirmedUnlimitedDuration)
                    XCTAssertEqual(controls.remainingDescription, L("Checking deadline", "마감 확인 중"))
                }
                XCTAssertEqual(controller.status, before)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
                XCTAssertEqual(controller.manualRequestID, requestID)
                XCTAssertEqual(backend.creates, creates); XCTAssertEqual(backend.releases, releases)
            }
        }
    }

    func testAutomaticWaitingCopyDoesNotPromiseRestartDuringPauseOrProtection() async {
        await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                for mode in [V4AutomaticMode.acConnected, .advanced] {
                    for thermalProtection in [false, true] {
                        let (model, controller, _) = fixture(power: .battery)
                        defer { _ = controller.end() }
                        var settings = controller.v4Settings
                        settings.automaticMode = mode
                        XCTAssertTrue(controller.setV4Settings(settings))
                        model.setAutomaticEnabled(true)
                        let panel = TetherPanel(model: model)
                        XCTAssertNotNil(panel.automaticStartWaitingDetail)

                        let now = ContinuousTime.now
                        if thermalProtection {
                            controller.update(power: .battery, thermal: 2, fullWake: true, controllingUser: true,
                                              now: now, batteryPercent: 80)
                            XCTAssertNotNil(model.workProtectionReason)
                        } else {
                            model.setEnabled(false)
                        }
                        XCTAssertTrue(model.automaticEnabled, "A stop keeps the saved automatic choice")
                        XCTAssertTrue(model.workPaused)
                        XCTAssertNil(panel.automaticStartWaitingDetail,
                            "Paused work needs explicit resume, not only an AC connection")

                        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                                          now: now + 1, batteryPercent: 80)
                        XCTAssertTrue(model.workPaused, "Reconnecting AC must not silently clear a pause or protection")
                        XCTAssertFalse(model.automaticWorkReasonActive)
                        XCTAssertFalse(model.workSessionHolding)
                        XCTAssertNil(panel.automaticStartWaitingDetail)
                    }
                }
            }
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
            XCTAssertEqual(model.manualStartBlockedDetail, "Choose Resume before starting a manual session.")
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
            XCTAssertTrue(model.manualBatteryScopeDetail.contains("Unplugging ends all existing Tether work"))
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
                    XCTAssertEqual(panel.fittingSize.width, 304, accuracy: 0.5)
                    XCTAssertGreaterThan(panel.fittingSize.height, 140,
                        "Compact status, controls and persistent actions still need a readable surface")
                    XCTAssertLessThanOrEqual(panel.fittingSize.height, WorkSessionMetrics.panelMaximumHeight)
                    if !active {
                        // Includes the two newly approved lid/display quick controls
                        // and the inline helper setup link, without scrolling.
                        XCTAssertLessThanOrEqual(panel.fittingSize.height, 320)
                    }
                    try assertSnapshot(panel, size: panel.fittingSize)
                }
                for page in SettingsPage.allCases {
                    model.settingsPage = page
                    let settings = NSHostingView(rootView: SettingsView(model: model, screenshot: true)
                        .environment(\.colorScheme, .dark)
                        .environment(\.tetherReduceTransparencyOverride, true)
                        .environment(\.tetherContrastOverride, .increased)
                        .frame(width: 640, height: 480))
                    XCTAssertEqual(WorkSessionMetrics.settingsMinimum, CGSize(width: 600, height: 440))
                    XCTAssertEqual(settings.fittingSize.width, 640, accuracy: 0.5)
                    XCTAssertEqual(settings.fittingSize.height, 480, accuracy: 0.5)
                    try assertSnapshot(settings, size: CGSize(width: 640, height: 480))
                }
            }
        }
    }

    func testMenuBodyScrollsAtItsViewportButShortContentDoesNotStretch() async throws {
        try await MainActor.run {
            let short = NSHostingView(rootView: MenuPanelBody(maximumHeight: 180) {
                Text("Short status").frame(height: 40)
            }.frame(width: 304).fixedSize(horizontal: false, vertical: true))
            XCTAssertEqual(short.fittingSize.height, 40, accuracy: 0.5)
            let long = NSHostingView(rootView: MenuPanelBody(maximumHeight: 180) {
                Text(String(repeating: "A long diagnostic message that must remain scrollable. ", count: 40))
                    .fixedSize(horizontal: false, vertical: true).padding(16)
            }.frame(width: 304).fixedSize(horizontal: false, vertical: true))
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
                            XCTAssertEqual(panel.fittingSize.width, 304, accuracy: 0.5)
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
        window.setContentSize(size)
        content.frame = CGRect(origin: .zero, size: size)
        window.contentView?.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds),
            "Snapshot failed for \(V.self): bounds=\(content.bounds), expected=\(size)")
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4e, 0x47])
        // PNG encoding smoke test only: it does not establish clipping,
        // readability, Liquid Glass quality, native input or physical power behavior.
    }
}
