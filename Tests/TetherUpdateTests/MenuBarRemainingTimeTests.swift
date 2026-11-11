import AppKit
import SwiftUI
import XCTest
import TetherCore
@testable import Tether

private final class MenuTimerDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func set(_ value: Float, forKey key: String) { values[key] = value }
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

private final class MenuTimerBackend: IdleAssertionBackend {
    var observedLevel: Int? = 255
    private(set) var creates = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (0, 91) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
    func level(id: UInt32) -> Int? { observedLevel }
    func release(id: UInt32) -> Int32 { 0 }
}

final class MenuBarRemainingTimeTests: XCTestCase {
    @MainActor
    private func fixture(defaults: MenuTimerDefaults = MenuTimerDefaults()) -> (AppModel, UserSessionController, MenuTimerBackend) {
        let backend = MenuTimerBackend()
        let work = UserSessionController(defaults: defaults, backend: backend, displayBackend: MenuTimerBackend(),
            guiProbe: nil, environmentProbe: nil, boot: "menu-timer")
        work.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: work, previewWorkService: { _ in throw ServiceFailure("renderOnly") }, previewDefaults: defaults)
        return (model, work, backend)
    }

    @MainActor
    func testNewDefaultIsIconOnlyAndExplicitStoredChoicesSurvive() {
        let (fresh, work, _) = fixture(); defer { _ = work.end() }
        XCTAssertFalse(fresh.menuBarDetails)
        for choice in [false, true] {
            let defaults = MenuTimerDefaults(); defaults.set(choice, forKey: "menuBarDetails")
            let (model, controller, _) = fixture(defaults: defaults); defer { _ = controller.end() }
            XCTAssertEqual(model.menuBarDetails, choice)
            model.menuBarDetails = !choice
            XCTAssertEqual(defaults.bool(forKey: "menuBarDetails"), !choice)
        }
    }

    @MainActor
    func testMinuteTextIsBoundedAndHandlesInvalidOrExpiredDurations() {
        let cases: [(Double, String?)] = [(0, nil), (-1, nil), (.nan, nil), (.infinity, nil),
            (1, "<1m"), (59, "<1m"), (60, "1m"), (1800, "30m"), (3600, "1h"),
            (4800, "1h20m"), (23 * 3600 + 59 * 60, "23h59m"), (25 * 3600, "1d1h"),
            (99 * 86400 + 23 * 3600, "99d23h"), (100 * 86400, "100d"), (1000 * 86400, "999d+")]
        for (seconds, expected) in cases {
            XCTAssertEqual(AppModel.menuBarRemainingText(seconds: seconds), expected)
            XCTAssertLessThanOrEqual(AppModel.menuBarRemainingText(seconds: seconds)?.count ?? 0, 6)
        }
    }

    @MainActor
    func testOnlyConfirmedFiniteManualWorkGetsTextAndDisplayChoiceCreatesNoWork() throws {
        let (model, work, backend) = fixture(); defer { _ = work.end() }
        model.menuBarDetails = true
        XCTAssertNil(model.menuBarItem(at: Date()).text); XCTAssertEqual(backend.creates, 0)
        work.setAutomatic(true)
        XCTAssertNil(model.menuBarItem(at: Date()).text)
        XCTAssertTrue(work.start(duration: 1800))
        let deadline = try XCTUnwrap(work.status.manualContinuousDeadline)
        XCTAssertEqual(model.menuBarItem(at: Date.distantFuture, continuousNow: deadline - 1799).text, "30m")
        XCTAssertEqual(model.menuBarItem(at: Date.distantPast, continuousNow: deadline - 60).text, "1m")
        let creates = backend.creates
        model.menuBarDetails = false
        XCTAssertNil(model.menuBarItem(at: Date()).text); XCTAssertEqual(backend.creates, creates)
        XCTAssertTrue(work.status.manualActive)
        work.endManual()
        XCTAssertTrue(work.start(duration: nil))
        model.menuBarDetails = true
        XCTAssertNil(model.menuBarItem(at: Date()).text)
    }

    @MainActor
    func testElapsedTimerNeverKeepsTheHeldIconOrTextWithoutAnIndependentAutomaticReason() throws {
        for automatic in [false, true] {
            let (model, work, _) = fixture(); defer { _ = work.end() }
            model.menuBarDetails = true; work.setAutomatic(automatic)
            XCTAssertTrue(work.start(duration: 1800))
            let deadline = try XCTUnwrap(work.status.manualContinuousDeadline)
            let item = model.menuBarItem(at: Date(), continuousNow: deadline)
            XCTAssertNil(item.text)
            XCTAssertEqual(item.icon, automatic ? .mark(.on) : .mark(.off))
        }
    }

    @MainActor
    func testUnknownFailurePauseAndProtectionDoNotShowAnActiveTimer() {
        for state in ["unknown", "failure", "pause", "protection"] {
            let (model, work, backend) = fixture(); defer { _ = work.end() }
            model.menuBarDetails = true; XCTAssertTrue(work.start(duration: 1800))
            switch state {
            case "unknown": work.update(power: .unknown, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            case "failure":
                backend.observedLevel = nil
                work.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
            case "pause": work.stopCurrent()
            default: work.update(power: .ac, thermal: 2, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            }
            let item = model.menuBarItem(at: Date())
            XCTAssertNil(item.text); XCTAssertNotEqual(item.icon, .mark(.held))
        }
    }

    @MainActor
    func testTimerTextWidthIsStableAndTheTemplateIconKeepsItsOriginalCanvas() {
        let (model, work, _) = fixture(); defer { _ = work.end() }
        XCTAssertTrue(work.start(duration: 1800)); model.menuBarDetails = true
        let label = NSHostingView(rootView: MenuBarLabel(model: model, clock: model.clock))
        XCTAssertEqual(label.fittingSize.width, 18 + 4 + MenuBarLabel.timerTextWidth, accuracy: 0.1)
        XCTAssertEqual(label.fittingSize.height, 20, accuracy: 0.1)
        XCTAssertEqual(MenuBarIcon.image(model.menuBarItem(at: Date())).size, NSSize(width: 18, height: 20))
        model.menuBarDetails = false
        let compact = NSHostingView(rootView: MenuBarLabel(model: model, clock: model.clock))
        XCTAssertEqual(compact.fittingSize.width, 18, accuracy: 0.1)
    }
}
