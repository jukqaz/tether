import Foundation
import XCTest
import TetherCore
@testable import Tether

private final class MenuProductAssertion: IdleAssertionBackend {
    private var ids: Set<UInt32> = []
    private var nextID: UInt32 = 1
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        let id = nextID; nextID += 1; ids.insert(id); return (0, id)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { ids.contains(id) ? 0 : -1 }
    func level(id: UInt32) -> Int? { ids.contains(id) ? 255 : 0 }
    func release(id: UInt32) -> Int32 { ids.remove(id); return 0 }
}

@MainActor
private final class MenuProductClock {
    var now = ContinuousTime.now
    var wall = Date()
    func advance(_ seconds: TimeInterval) {
        now += seconds; wall = wall.addingTimeInterval(seconds)
    }
}

@MainActor
private final class MenuProductFixture {
    let clock = MenuProductClock()
    let controller: UserSessionController
    let model: AppModel

    init(automatic: Bool = true) throws {
        let defaults = TestMemoryDefaults(domain: "MenuProduct." + UUID().uuidString)
        var settings = IdleSessionSettings()
        settings.automaticEnabled = automatic
        settings.legacyRootConfigurationPending = false
        settings.v4.nextManualOptions = .init(display: false, closedLid: false)
        defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
        let clock = self.clock
        controller = UserSessionController(defaults: defaults, backend: MenuProductAssertion(),
            displayBackend: MenuProductAssertion(), guiProbe: nil, environmentProbe: nil,
            boot: "menu-product", wallClock: { clock.wall }, continuousClock: { clock.now })
        controller.idleSecondsProbe = { 0 }
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: clock.now, batteryPercent: 80)
        model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: false, lid: false),
            previewSession: controller,
            previewLegacyObservation: { .init(power: .ac, lidClosed: nil, sleepDisabled: nil, fullWake: true) },
            previewWorkService: { _ in throw ServiceFailure("menu-product-fixture-isolated") },
            previewDefaults: defaults, previewHelperFiles: { [] })
    }

    func observe(after seconds: TimeInterval, thermal: Int = 0, awake: Bool = true) {
        clock.advance(seconds)
        controller.update(power: .ac, thermal: thermal, fullWake: awake, controllingUser: true,
            now: clock.now, batteryPercent: 80)
    }

    func close() { _ = controller.end() }
}

/// Shipping UI copy and actions with memory preferences, controlled clocks and
/// fake assertions. No windows, OS Sleep, helper calls or physical input.
final class MenuProductPresentationTests: XCTestCase {
    @MainActor
    func testSleepCopyMatchesTimedAndUntimedConsumptionWithoutManualReplayAfterWake() throws {
        let previous = Localization.current; defer { Localization.current = previous }
        for language in [Language.english, .korean] {
            Localization.current = language
            XCTAssertEqual(ManualStartText.sleepDetail, language == .english
                ? "Entering sleep ends this manual session. Waking the Mac does not restart it."
                : "잠자기에 들어가면 수동 유지가 끝나며, 깨어나도 다시 시작하지 않습니다.")
            for automatic in [false, true] {
                for duration in [TimeInterval?.some(1800), nil] {
                    let fixture = try MenuProductFixture(automatic: automatic); defer { fixture.close() }
                    XCTAssertTrue(fixture.controller.start(duration: duration, now: fixture.clock.now))
                    XCTAssertTrue(fixture.model.manualSessionActive)
                    let request = try XCTUnwrap(fixture.controller.manualRequestID)
                    fixture.clock.advance(1)
                    fixture.controller.observeSystemSleep(observedAt: fixture.clock.now)
                    XCTAssertFalse(fixture.model.manualSessionActive)
                    XCTAssertNil(fixture.controller.manualRequestID)
                    XCTAssertNil(fixture.model.manualSessionUntil)
                    fixture.observe(after: 1, awake: false)
                    fixture.observe(after: 1)
                    XCTAssertFalse(fixture.model.manualSessionActive)
                    XCTAssertNotEqual(fixture.controller.manualRequestID, request)
                    XCTAssertEqual(fixture.model.automaticWorkReasonActive, automatic)
                }
            }
        }
    }

    @MainActor
    func testCompactActionsKeepTheCurrentRequestAndUntimedSessionHasNoExtension() throws {
        let previous = Localization.current; defer { Localization.current = previous }
        for language in [Language.english, .korean] {
            Localization.current = language
            for duration in [TimeInterval?.some(1800), nil] {
                let fixture = try MenuProductFixture(); defer { fixture.close() }
                XCTAssertTrue(fixture.controller.start(duration: duration, now: fixture.clock.now))
                let before = fixture.controller.status
                let controls = ManualSessionControls(model: fixture.model, clock: fixture.model.clock, compact: true)
                XCTAssertEqual(controls.endButtonTitle, L("End manual", "수동 종료"))
                XCTAssertEqual(controls.extensionButtonTitle(30), L("+30 min", "+30분"))
                XCTAssertEqual(controls.showsTimedExtension, duration != nil)
                if duration == nil { XCTAssertEqual(controls.remainingDescription, L("Until ended", "종료할 때까지")) }
                XCTAssertEqual(fixture.controller.status, before, "Reading labels must not recreate or extend work")
                fixture.model.endManualSession()
                XCTAssertFalse(fixture.model.manualSessionActive)
                XCTAssertTrue(fixture.model.automaticWorkReasonActive)
            }
        }
    }

    @MainActor
    func testStopAllAndResumeKeepTheIndependentAutomaticPauseWithoutRestoringManual() throws {
        for pauseAutomatic in [false, true] {
            let fixture = try MenuProductFixture(); defer { fixture.close() }
            // Start and the model's automatic-pause command must share this
            // injected monotonic clock. The API's default is the real clock.
            XCTAssertTrue(fixture.controller.start(duration: 1800, now: fixture.clock.now))
            XCTAssertTrue(fixture.model.automaticEnabled)
            let request = try XCTUnwrap(fixture.controller.manualRequestID)
            let deadline = try XCTUnwrap(fixture.controller.status.manualContinuousDeadline)
            if pauseAutomatic {
                XCTAssertTrue(fixture.model.pauseAutomatic(for: 1800))
                XCTAssertTrue(fixture.model.automaticPauseActive)
                XCTAssertEqual(fixture.controller.manualRequestID, request)
                XCTAssertEqual(fixture.controller.status.manualContinuousDeadline, deadline)
            }
            let panel = TetherPanel(model: fixture.model)
            XCTAssertTrue(panel.canChangeStopState)
            panel.changeStopState()
            XCTAssertTrue(fixture.model.workPaused)
            XCTAssertTrue(panel.showsResumeControl)
            XCTAssertFalse(fixture.model.manualSessionActive)
            panel.changeStopState()
            XCTAssertFalse(fixture.model.workPaused)
            XCTAssertFalse(fixture.model.manualSessionActive)
            XCTAssertEqual(fixture.model.automaticPauseActive, pauseAutomatic)
            XCTAssertEqual(fixture.model.automaticWorkReasonActive, !pauseAutomatic)
        }
    }

    @MainActor
    func testProtectionResumeStaysVisibleButDisabledUntilTheExistingSafeWindowCompletes() throws {
        let fixture = try MenuProductFixture(); defer { fixture.close() }
        XCTAssertTrue(fixture.controller.start(duration: 1800, now: fixture.clock.now))
        fixture.observe(after: 1, thermal: 2)
        let panel = TetherPanel(model: fixture.model)
        XCTAssertEqual(fixture.model.workProtectionReason, "thermal")
        XCTAssertTrue(panel.showsResumeControl)
        XCTAssertFalse(panel.canChangeStopState)
        let blocked = fixture.controller.status
        panel.changeStopState()
        XCTAssertEqual(fixture.controller.status, blocked)
        fixture.observe(after: 1)
        for _ in 0..<5 { fixture.observe(after: 10) }
        XCTAssertFalse(panel.canChangeStopState, "Fifty safe seconds cannot unlock resume")
        fixture.observe(after: 10)
        XCTAssertTrue(panel.canChangeStopState)
        panel.changeStopState()
        XCTAssertNil(fixture.model.workProtectionReason)
        XCTAssertTrue(fixture.model.automaticWorkReasonActive)
        XCTAssertFalse(fixture.model.manualSessionActive)
    }
}
