import XCTest
import TetherCore
@testable import Tether

/// Shipping summary methods with the real model/controller and render-only
/// executors. Native sheet navigation and layout remain a separate UI check.
final class ManualDefaultsPresentationTests: XCTestCase {
    func testDisplaySummaryDistinguishesNoRequestPermissionOffAndPermissionOn() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual-ready"])
                let controller = try XCTUnwrap(model.userSession)
                defer { _ = controller.end() }
                model.setKeepDisplayAwake(false)
                let view = ManualDefaultsOptionsView(model: model)
                let noRequest = view.displayApplicationDetail(for: .init(display: false))
                let permissionOff = view.displayApplicationDetail(for: .init(display: true))
                XCTAssertNotEqual(noRequest, permissionOff)
                XCTAssertTrue(permissionOff.contains(L("Power & Lid", "전원·덮개")))

                model.setKeepDisplayAwake(true)
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                let settings = model.v4Settings
                let status = controller.status
                let permissionOn = view.displayApplicationDetail(for: .init(display: true))
                XCTAssertNotEqual(permissionOn, permissionOff)
                XCTAssertNotEqual(permissionOn, noRequest)
                XCTAssertTrue(permissionOn.contains(L("checked again at start", "시작할 때 다시 확인")),
                    "Permission alone cannot promise that a future request is already executing")
                XCTAssertEqual(view.displayApplicationDetail(for: .init(display: false)), noRequest,
                    "A global permission does not turn an unrequested feature into a request")
                XCTAssertEqual(controller.status, status)
                XCTAssertEqual(model.v4Settings, settings)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
                XCTAssertFalse(model.manualSessionActive)
            }
        }
    }

    func testLidSummaryDirectsToTheMissingPermissionOrHelperWithoutChangingCurrentWork() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual-ready"])
                let controller = try XCTUnwrap(model.userSession)
                defer { _ = controller.end() }
                XCTAssertFalse(model.helperSetupConfirmed)
                let view = ManualDefaultsOptionsView(model: model)
                let noRequest = view.lidApplicationDetail(for: .init(closedLid: false))
                let permissionOff = view.lidApplicationDetail(for: .init(closedLid: true))
                XCTAssertNotEqual(noRequest, permissionOff)
                XCTAssertTrue(permissionOff.contains(L("Power & Lid", "전원·덮개")))

                // This request omits lid keeping; a future draft may request it.
                var next = controller.v4Settings
                next.nextManualOptions.closedLid = false
                XCTAssertTrue(controller.setV4Settings(next))
                model.startManualSession(minutes: 30)
                XCTAssertTrue(model.manualSessionActive)
                let request = try XCTUnwrap(controller.manualRequestID)
                let deadline = controller.status.manualContinuousDeadline
                let capturedOptions = controller.v4ManualSnapshot?.options
                model.setAllowClosedLid(true)
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                let missingHelper = view.lidApplicationDetail(for: .init(closedLid: true))
                XCTAssertNotEqual(missingHelper, permissionOff)
                XCTAssertTrue(missingHelper.contains(L("Power & Lid", "전원·덮개")))
                XCTAssertEqual(view.lidApplicationDetail(for: .init(closedLid: false)), noRequest)
                XCTAssertEqual(controller.manualRequestID, request)
                XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
                XCTAssertEqual(controller.v4ManualSnapshot?.options, capturedOptions)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
            }
        }
    }

    func testDesktopSummaryDoesNotOfferAHelperOrRewriteSavedLidChoices() async throws {
        try await MainActor.run {
            let previous = Localization.current; defer { Localization.current = previous }
            for language in [Language.english, .korean] {
                Localization.current = language
                let model = PreviewRenderer.sampleModel(arguments: ["--sample", "--manual-ready", "--desktop"])
                let controller = try XCTUnwrap(model.userSession)
                defer { _ = controller.end() }
                XCTAssertFalse(model.capabilities.lidControlAvailable)
                let before = model.v4Settings
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                let view = ManualDefaultsOptionsView(model: model)
                let unavailable = view.lidApplicationDetail(for: .init(closedLid: true))
                XCTAssertTrue(unavailable.contains(L("unavailable", "지원하지 않습니다")))
                XCTAssertEqual(view.lidApplicationDetail(for: .init(closedLid: false)), unavailable)
                XCTAssertFalse(unavailable.contains(L("Power & Lid", "전원·덮개")),
                    "A desktop must not be directed to install an inapplicable helper")
                XCTAssertEqual(model.v4Settings, before)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
                XCTAssertFalse(model.manualSessionActive)
            }
        }
    }
}
