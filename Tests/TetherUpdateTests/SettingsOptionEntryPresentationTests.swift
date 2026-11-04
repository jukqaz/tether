import XCTest
import AppKit
import SwiftUI
import TetherCore
@testable import Tether

/// Construction checks only. Native sheet presentation, AX layout and scrolling
/// require the separate UI suite; these tests never claim screenshot coverage.
final class SettingsOptionEntryPresentationTests: XCTestCase {
    func testEmbeddedMenuFitsItsSheetBudgetWithoutChangingAnActiveTimer() async throws {
        try await MainActor.run {
            let original = Localization.current; defer { Localization.current = original }
            let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual", "--timed"])
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            let request = controller.manualRequestID
            let deadline = controller.status.manualContinuousDeadline
            for language in [Language.korean, .english] {
                Localization.current = language
                for appearance in [ColorScheme.light, .dark] {
                    let view = NSHostingView(rootView: CurrentWorkOptionsView(model: model) { _ in
                        XCTFail("Layout must not execute navigation")
                    }.preferredColorScheme(appearance))
                    let size = view.fittingSize
                    XCTAssertEqual(size.width, WorkSessionMetrics.panelWidth, accuracy: 0.5)
                    XCTAssertGreaterThan(size.height, 200)
                    XCTAssertLessThanOrEqual(size.height, 420,
                        "The menu must reserve its own scroll budget inside the compact sheet")
                }
            }
            XCTAssertEqual(controller.manualRequestID, request)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertTrue(model.manualSessionActive)
        }
    }

    func testConstructingAdvancedDetailsPreservesSavedBasicModeAndTheActiveTimer() async throws {
        try await MainActor.run {
            let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual", "--timed"])
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            model.setPowerCondition(.any)
            XCTAssertEqual(model.v4Settings.automaticMode, .acConnected)
            XCTAssertTrue(model.manualSessionActive)
            let settings = model.v4Settings
            let savedScope = model.v3Settings.condition
            let request = controller.manualRequestID
            let deadline = controller.status.manualContinuousDeadline
            let startedAt = controller.status.manualStartedAt
            let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
            let page = model.settingsPage

            // The advanced editor may initialize its local draft to Advanced,
            // but opening a settings detail must never act as Confirm and apply.
            _ = V4AutomaticRulesView(model: model, startInAdvancedMode: true)
            _ = SettingsTransferView(model: model)
            _ = OptionCatalogView(model: model)
            _ = CurrentWorkOptionsView(model: model) { _ in
                XCTFail("Constructing menu controls must not navigate or execute an action")
            }
            _ = SettingsView(model: model, screenshot: true, expandedDetails: true)

            XCTAssertEqual(model.v4Settings, settings)
            XCTAssertEqual(model.v3Settings.condition, savedScope,
                "Legacy advanced power choices must survive basic-mode presentation")
            XCTAssertEqual(model.settingsPage, page)
            XCTAssertEqual(controller.manualRequestID, request)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertEqual(controller.status.manualStartedAt, startedAt)
            XCTAssertTrue(model.manualSessionActive)
            XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
        }
    }
}
