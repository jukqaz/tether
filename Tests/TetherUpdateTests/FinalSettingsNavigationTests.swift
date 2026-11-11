import AppKit
import XCTest
import SwiftUI
import TetherCore
@testable import Tether

/// Verifies settings routes and live-model contracts. Rendering/scrolling belongs
/// to the separate native UI suite; these checks do not claim physical coverage.
final class FinalSettingsNavigationTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        // These model/view paths read AppKit state even in a filtered test run.
        await MainActor.run { _ = NSApplication.shared }
    }

    func testSidebarOrderPreservesSavedPageIdentitiesAndLocalizedDestinations() async {
        await MainActor.run {
            let previous = Localization.current
            defer { Localization.current = previous }
            XCTAssertEqual(SettingsPage.allCases, [.safety, .general, .protection, .system])
            XCTAssertEqual(SettingsPage(rawValue: "safety"), .safety)
            XCTAssertEqual(SettingsPage(rawValue: "general"), .general)
            XCTAssertEqual(SettingsPage(rawValue: "system"), .system)
            for language in [Language.english, .korean] {
                Localization.current = language
                XCTAssertEqual(SettingsPage.safety.title, L("Power & Lid", "전원·덮개"))
                XCTAssertEqual(SettingsPage.general.title, L("Manual", "수동 유지"))
                XCTAssertEqual(SettingsPage.protection.title, L("Protection & Diagnostics", "보호·진단"))
                XCTAssertEqual(SettingsPage.protection.shortTitle, L("Protection", "보호·진단"))
                XCTAssertEqual(SettingsPage.system.title, L("General", "일반"))
            }
        }
    }

    func testOpeningEveryPaneAndInlineDraftDoesNotSaveOrMutateCurrentWork() async throws {
        try await MainActor.run {
            let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual", "--timed"])
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            let settings = model.v4Settings
            let globals = model.v3Settings
            let snapshot = controller.v4ManualSnapshot
            let deadline = controller.status.manualContinuousDeadline
            let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
            for page in SettingsPage.allCases {
                model.settingsPage = page
                _ = page.page(model: model, disclosures: .constant(SettingsDisclosureState(expanded: true)))
            }
            _ = ManualDefaultsOptionsView(model: model, embedded: true)
            _ = ManualDefaultsOptionsView(model: model)
            XCTAssertEqual(model.v4Settings, settings)
            XCTAssertEqual(model.v3Settings, globals)
            XCTAssertEqual(controller.v4ManualSnapshot, snapshot)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
        }
    }

    func testSeparateNextStartSaveScopesNeverRewriteCapturedManualRequest() async throws {
        try await MainActor.run {
            let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual", "--timed"])
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            XCTAssertTrue(model.manualSessionActive)
            let request = try XCTUnwrap(controller.manualRequestID)
            let snapshot = try XCTUnwrap(controller.v4ManualSnapshot)
            let deadline = controller.status.manualContinuousDeadline
            let displayPermission = model.v3Settings.keepDisplayAwake
            let lidPermission = model.v3Settings.allowClosedLid
            let power: PowerCondition = model.v3Settings.manualPowerCondition == .any ? .ac : .any
            model.setManualPowerCondition(power)
            model.setBatteryTimeLimit(.fourHours)
            var next = model.v4Settings.nextManualOptions
            next.display.toggle()
            next.releaseDisplayAfterIdle = next.display ? 600 : nil
            XCTAssertTrue(model.saveManualDefaultsOptions(next, expectedGeneration: model.v4Settings.generation))
            XCTAssertEqual(model.v3Settings.manualPowerCondition, power)
            XCTAssertEqual(model.v3Settings.batteryTimeLimit, .fourHours)
            XCTAssertEqual(model.v4Settings.nextManualOptions, next)
            XCTAssertEqual(controller.manualRequestID, request)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertEqual(controller.v4ManualSnapshot?.options, snapshot.options)
            XCTAssertEqual(controller.v4ManualSnapshot?.batteryTimeLimit, snapshot.batteryTimeLimit)
            XCTAssertEqual(model.v3Settings.keepDisplayAwake, displayPermission)
            XCTAssertEqual(model.v3Settings.allowClosedLid, lidPermission)
            XCTAssertTrue(model.manualSessionActive)
        }
    }

    func testRequestedOtherAppDetailsActuallyPresentsReviewAndPreservesCurrentWork() async throws {
        try await MainActor.run {
            let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual", "--timed"])
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            let request = controller.manualRequestID
            let deadline = controller.status.manualContinuousDeadline
            model.showOtherAppKeepAwakeDetails()
            XCTAssertEqual(model.settingsPage, .protection)
            XCTAssertTrue(model.otherAppDetailsRequested)
            ProtectionPage(model: model).revealRequestedOtherAppDetails()
            XCTAssertFalse(model.otherAppDetailsRequested)
            XCTAssertTrue(model.showActivityReview)
            XCTAssertEqual(controller.manualRequestID, request)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertTrue(model.manualSessionActive)
        }
    }

}
