import AppKit
import SwiftUI
import XCTest
@testable import Tether
@testable import TetherCore

/// Shipping views and their bound model, with PreviewRenderer's memory-only executors.
final class AutomaticPauseUITests: XCTestCase {
    @MainActor
    func testAutomaticRestDoesNotAdvertiseWaitingForConditionsOrEndManualWork() throws {
        let previous = Localization.current
        defer { Localization.current = previous }
        for language in [Language.english, .korean] {
            Localization.current = language
            let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual", "--timed", "--dual", "--automatic-rest"])
            defer { _ = model.userSession?.end() }
            let requestID = try XCTUnwrap(model.userSessionStatus?.manualRequestID)
            let deadline = try XCTUnwrap(model.manualSessionUntil)
            XCTAssertTrue(model.automaticEnabled, "Temporary rest must not edit the saved automatic choice")
            XCTAssertTrue(model.automaticPauseActive)
            XCTAssertFalse(model.workPaused, "Automatic-only rest must not masquerade as Stop all")
            XCTAssertTrue(model.manualSessionActive)
            XCTAssertTrue(model.workSessionHolding)
            XCTAssertFalse(model.automaticWorkReasonActive)
            XCTAssertNil(TetherPanel(model: model).automaticStartWaitingDetail)
            XCTAssertEqual(model.manualEndingDetail, language == .english
                ? "Ending manual work keeps automatic starts resting." : "수동 종료는 자동 쉬기를 해제하지 않습니다.")
            let summary = AutomaticPauseControls(model: model).pauseSummary
            XCTAssertTrue(summary.contains(Texts.time(try XCTUnwrap(model.automaticPauseUntil))))
            XCTAssertTrue(model.resumeAutomatic())
            XCTAssertEqual(model.userSessionStatus?.manualRequestID, requestID)
            XCTAssertEqual(model.manualSessionUntil, deadline)
        }
    }

    @MainActor
    func testAutomaticOnlyRestAndProtectionHaveDifferentMainStates() {
        let previous = Localization.current
        defer { Localization.current = previous }
        Localization.current = .english
        let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--automatic-rest-until-resume"])
        defer { _ = model.userSession?.end() }
        XCTAssertTrue(model.automaticPauseActive)
        XCTAssertNil(model.automaticPauseUntil)
        XCTAssertEqual(model.presentation.title, "Automatic starts resting")
        XCTAssertTrue(AutomaticPauseControls(model: model).pauseSummary.contains("until you resume"))
        model.setEnabled(false)
        XCTAssertTrue(model.workPaused)
        XCTAssertNotEqual(model.presentation.title, "Automatic starts resting")
        _ = model.resumeAutomatic()
        XCTAssertTrue(model.workPaused, "Resume automatic must never clear Stop all")
        XCTAssertFalse(model.workSessionHolding)
    }

    @MainActor
    func testRestingMenuAndAutomaticSettingsStayWithinTheirViewports() throws {
        let previous = Localization.current
        defer { Localization.current = previous }
        for language in [Language.english, .korean] {
            Localization.current = language
            for arguments in [["--sample", "--automatic-rest"],
                              ["--sample", "--automatic-rest-until-resume"],
                              ["--sample", "--manual", "--timed", "--dual", "--automatic-rest"],
                              ["--sample", "--automatic-rest", "--protection"]] {
                let model = PreviewRenderer.sampleModel(arguments: arguments)
                defer { _ = model.userSession?.end() }
                for dark in [false, true] {
                    let panel = NSHostingView(rootView: TetherPanel(model: model, maximumHeight: 360)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.tetherReduceTransparencyOverride, true))
                    XCTAssertEqual(panel.fittingSize.width, 304, accuracy: 0.5)
                    XCTAssertLessThanOrEqual(panel.fittingSize.height, 360.5)
                    model.settingsPage = .safety
                    let settings = NSHostingView(rootView: SettingsView(model: model, screenshot: true)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.tetherReduceTransparencyOverride, true)
                        .frame(width: 640, height: 480))
                    XCTAssertEqual(settings.fittingSize, CGSize(width: 640, height: 480))
                    XCTAssertFalse(panel.fittingSize.height.isNaN)
                }
            }
        }
    }
}
