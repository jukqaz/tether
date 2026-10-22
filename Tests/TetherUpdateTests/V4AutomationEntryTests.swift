import XCTest
import TetherCore
@testable import Tether

private final class RetiredShortcutMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private(set) var removedKeys: [String] = []
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) {
        removedKeys.append(key)
        values.removeValue(forKey: key)
    }
}

final class V4AutomationEntryTests: XCTestCase {
    @MainActor
    func testRetiredGlobalShortcutPreferencesAreRemovedWithoutChangingOtherSettings() {
        let defaults = RetiredShortcutMemoryDefaults()
        let legacy = Data(#"{"version":1,"entries":[{"action":"pauseAll","chord":{"keyCode":17,"modifiers":6144}}]}"#.utf8)
        let savedPowerChoices = Data("saved-power-choices".utf8)
        let savedHistory = Data("saved-settings-history".utf8)
        defaults.set(legacy, forKey: "v4GlobalShortcuts")
        defaults.set(savedPowerChoices, forKey: UserSessionController.preferenceKey)
        defaults.set(savedHistory, forKey: "v4SettingsHistory")
        defaults.set(false, forKey: "SUEnableAutomaticChecks")

        AppDelegate.removeRetiredShortcutPreferences(from: defaults)

        XCTAssertNil(defaults.object(forKey: "v4GlobalShortcuts"))
        XCTAssertEqual(defaults.removedKeys, ["v4GlobalShortcuts"])
        XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), savedPowerChoices)
        XCTAssertEqual(defaults.data(forKey: "v4SettingsHistory"), savedHistory)
        XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
    }

    @MainActor
    func testRetiringShortcutPreferencesHandlesMissingAndMalformedValuesIdempotently() {
        let legacyValues: [Any?] = [nil, Data("invalid-legacy-json".utf8), "unsupported-legacy-value"]
        for legacy in legacyValues {
            let defaults = RetiredShortcutMemoryDefaults()
            defaults.set(legacy, forKey: "v4GlobalShortcuts")
            defaults.set("unchanged", forKey: "unrelated-setting")
            AppDelegate.removeRetiredShortcutPreferences(from: defaults)
            AppDelegate.removeRetiredShortcutPreferences(from: defaults)
            XCTAssertNil(defaults.object(forKey: "v4GlobalShortcuts"))
            XCTAssertEqual(defaults.object(forKey: "unrelated-setting") as? String, "unchanged")
            XCTAssertTrue(defaults.removedKeys.allSatisfy { $0 == "v4GlobalShortcuts" })
        }
    }

    @MainActor
    func testSharedAutomationActionIdentitySurvivesRetiringKeyboardShortcuts() {
        let previous = Localization.current; defer { Localization.current = previous }
        XCTAssertEqual(Set(V4AutomationAction.allCases.map(\.rawValue)),
            ["startManual", "endManual", "pauseAll", "automaticOn", "automaticOff", "status"])
        Localization.current = .english
        XCTAssertEqual(V4AutomationAction.pauseAll.title, "Stop all")
        Localization.current = .korean
        XCTAssertEqual(V4AutomationAction.pauseAll.title, "모두 중지")
    }

    @MainActor
    func testAutomationStatusIsReadOnlyAndPreviewEntryRequiresExplicitTestBoundary() async throws {
        let model = PreviewRenderer.sampleModel(arguments: ["--manual-ready"])
        let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
        let denied = await model.performV4Automation(.startManual)
        XCTAssertEqual(denied.outcome, .unconfirmed)
        XCTAssertFalse(work.status.manualActive)
        let before = work.manualRequestID
        let status = await model.performV4Automation(.status, allowPreview: true)
        XCTAssertTrue(status.succeeded)
        XCTAssertEqual(work.manualRequestID, before)
        XCTAssertFalse(work.status.automaticEnabled)
    }

    @MainActor
    func testAutomationScopesKeepManualAndSavedAutomaticIndependent() async throws {
        let model = PreviewRenderer.sampleModel(arguments: ["--manual-ready"])
        let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
        let start = await model.performV4Automation(.startManual, minutes: 15, useSavedDuration: false, allowPreview: true)
        XCTAssertEqual(start.outcome, .accepted)
        let id = try XCTUnwrap(work.manualRequestID)
        let duplicate = await model.performV4Automation(.startManual, minutes: 30, useSavedDuration: false, allowPreview: true)
        XCTAssertEqual(duplicate.outcome, .rejected)
        XCTAssertEqual(work.manualRequestID, id)
        _ = await model.performV4Automation(.automaticOn, allowPreview: true)
        _ = await model.performV4Automation(.automaticOff, allowPreview: true)
        XCTAssertEqual(work.manualRequestID, id)
        XCTAssertTrue(work.status.manualActive)
        _ = await model.performV4Automation(.automaticOn, allowPreview: true)
        let pause = await model.performV4Automation(.pauseAll, allowPreview: true)
        XCTAssertTrue(pause.succeeded)
        XCTAssertFalse(work.status.manualActive)
        XCTAssertTrue(work.status.automaticEnabled)
        _ = await model.performV4Automation(.automaticOn, allowPreview: true)
        XCTAssertTrue(model.workPaused)
        XCTAssertFalse(work.status.manualActive)
        XCTAssertFalse(work.status.holding)
    }

    @MainActor
    func testBatteryUnlimitedAutomationRejectsWithoutCreatingRequest() async throws {
        let model = PreviewRenderer.sampleModel(arguments: ["--manual-ready", "--battery"])
        let work = try XCTUnwrap(model.userSession); defer { _ = work.end() }
        work.endManual()
        let reply = await model.performV4Automation(.startManual, minutes: nil, useSavedDuration: false, allowPreview: true)
        XCTAssertEqual(reply.outcome, .rejected)
        XCTAssertFalse(work.status.manualActive)
        XCTAssertNil(work.manualRequestID)
    }
}
