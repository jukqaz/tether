import AppKit
import XCTest
import TetherCore
@testable import Tether

/// The shipping editor's value draft, using isolated defaults and executors.
final class PowerSettingsProductUITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { _ = NSApplication.shared }
    }

    func testOpeningAndCancellingConditionsKeepsCurrentWorkAndSavedChoices() async throws {
        try await MainActor.run {
            let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual", "--timed"])
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
            let settings = model.v4Settings
            let globals = model.v3Settings
            let request = controller.manualRequestID
            let snapshot = controller.v4ManualSnapshot
            let deadline = controller.status.manualContinuousDeadline

            _ = V4AutomaticRulesView(model: model)
            _ = V4AutomaticRulesView(model: model, initialTemplate: .workHours)
            var draft = AutomaticRulesDraft(settings: settings, powerCondition: globals.condition)
            draft.settings = V4RuleStarter.workHours.adding(to: draft.settings, nextManualMinutes: 60)
            draft.powerCondition = .battery
            draft.settings.experimentalProvidersEnabled = true
            draft.settings.nextManualOptions.display.toggle()
            XCTAssertNotEqual(draft.settings, settings)
            XCTAssertNotEqual(draft.powerCondition, globals.condition)
            // Dismissing the sheet drops this value instead of calling confirm.
            XCTAssertEqual(model.v4Settings, settings)
            XCTAssertEqual(model.v3Settings, globals)
            XCTAssertEqual(controller.manualRequestID, request)
            XCTAssertEqual(controller.v4ManualSnapshot, snapshot)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
        }
    }

    func testConfirmCommitsTheEditorsModeScopeAndPresetsWithoutStartingWork() async throws {
        try await MainActor.run {
            for scope in PowerCondition.allCases {
                let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual-ready"])
                let controller = try XCTUnwrap(model.userSession)
                defer { _ = controller.end() }
                let permissions = (model.v3Settings.keepDisplayAwake, model.v3Settings.allowClosedLid)
                var draft = AutomaticRulesDraft(settings: model.v4Settings, powerCondition: model.v3Settings.condition)
                draft.settings = V4RuleStarter.workHours.adding(to: draft.settings, nextManualMinutes: 30)
                draft.settings.experimentalProvidersEnabled = true
                draft.powerCondition = scope
                let preset = try XCTUnwrap(draft.settings.presets.first)
                XCTAssertTrue(draft.confirm(in: model))
                XCTAssertEqual(model.v4Settings.automaticMode, .advanced)
                XCTAssertEqual(model.v3Settings.condition, scope)
                XCTAssertEqual(model.v4Settings.activePresetID, preset.id)
                XCTAssertEqual(model.v4Settings.presets, draft.settings.presets)
                XCTAssertTrue(model.v4Settings.experimentalProvidersEnabled)
                XCTAssertFalse(model.automaticEnabled)
                XCTAssertFalse(model.workSessionHolding)
                XCTAssertEqual(model.v3Settings.keepDisplayAwake, permissions.0)
                XCTAssertEqual(model.v3Settings.allowClosedLid, permissions.1)
            }
        }
    }

    func testFailedConfirmationRetainsTheDraftAndDoesNotPartiallySaveItsScope() async throws {
        try await MainActor.run {
            let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual-ready"])
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            var draft = AutomaticRulesDraft(settings: model.v4Settings, powerCondition: model.v3Settings.condition)
            draft.settings = V4RuleStarter.workHours.adding(to: draft.settings, nextManualMinutes: 30)
            draft.powerCondition = .battery
            var newer = model.v4Settings
            newer.expiryNoticeEnabled.toggle()
            XCTAssertTrue(model.saveV4AutomaticRules(newer))
            let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
            let settings = model.v4Settings
            let globals = model.v3Settings
            XCTAssertFalse(draft.confirm(in: model), "A stale editor must stay open for review")
            XCTAssertEqual(draft.settings.automaticMode, .advanced)
            XCTAssertEqual(draft.powerCondition, .battery)
            XCTAssertEqual(model.v4Settings, settings)
            XCTAssertEqual(model.v3Settings, globals)
            XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
            XCTAssertFalse(model.workSessionHolding)
        }
    }

    func testConfirmRejectsAnExternalPowerScopeChangeWithoutOverwritingIt() async throws {
        try await MainActor.run {
            let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual-ready"])
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            model.setPowerCondition(.ac)
            var draft = AutomaticRulesDraft(settings: model.v4Settings, powerCondition: .ac)
            draft.settings.automaticMode = .advanced
            draft.powerCondition = .battery

            model.setPowerCondition(.any)
            XCTAssertEqual(model.v4Settings.generation, draft.settings.generation,
                           "A scope change outside the editor is not a transferred rule change")
            let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
            XCTAssertFalse(draft.confirm(in: model))
            XCTAssertEqual(model.v3Settings.condition, .any)
            XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
            XCTAssertEqual(draft.powerCondition, .battery)
        }
    }

    func testAutomaticPermissionDescriptionStaysSeparateFromExecutionState() async throws {
        try await MainActor.run {
            let previous = Localization.current
            defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual", "--timed"])
                let controller = try XCTUnwrap(model.userSession)
                defer { _ = controller.end() }
                let page = SafetyPage(model: model)
                let configured = page.automaticConditionSummary
                let request = controller.manualRequestID
                let deadline = controller.status.manualContinuousDeadline
                let offStatus = model.automaticStartStateDetail
                model.setAutomaticEnabled(true)
                XCTAssertEqual(page.automaticConditionSummary, configured)
                XCTAssertNotEqual(model.automaticStartStateDetail, offStatus)
                XCTAssertEqual(controller.manualRequestID, request)
                XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
                controller.stopCurrent()
                XCTAssertEqual(page.automaticConditionSummary, configured)
                XCTAssertTrue(model.automaticEnabled, "Stop all keeps the saved automatic permission")
                XCTAssertTrue(model.workPaused)
                XCTAssertFalse(model.workSessionHolding)
            }
        }
    }
}
