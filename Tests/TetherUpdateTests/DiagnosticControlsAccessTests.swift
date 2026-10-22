import XCTest
@testable import Tether

final class DiagnosticControlsAccessTests: XCTestCase {
    func testRecordingFixtureExceptionNeverEnablesAncillaryOrDevelopmentActions() {
        let unique = NativeUIAutomation.bundleID + "." + String(repeating: "b", count: 32)
        let fixture = NativeUIAutomation.allowsInMemoryRecording(bundleID: unique, fixture: true,
            environment: ["TETHER_UI_TESTING": "1"], hasFixtureSession: true)
        XCTAssertTrue(fixture)
        let allowed = DiagnosticControlsAccess(canRecord: true, preview: true,
            development: false, nativeRecordingFixture: fixture)
        XCTAssertTrue(allowed.recording, "Only memory recording Start/Stop receives the native exception")
        XCTAssertFalse(allowed.ancillary, "Report, preference, marker and file actions remain blocked")
        for canRecord in [true, false] {
            let development = DiagnosticControlsAccess(canRecord: canRecord, preview: true,
                development: true, nativeRecordingFixture: fixture)
            XCTAssertFalse(development.recording)
            XCTAssertFalse(development.ancillary)
        }
        let unavailable = DiagnosticControlsAccess(canRecord: false, preview: true,
            development: false, nativeRecordingFixture: fixture)
        XCTAssertFalse(unavailable.recording)
        XCTAssertFalse(unavailable.ancillary)
        let production = DiagnosticControlsAccess(canRecord: true, preview: false,
            development: false, nativeRecordingFixture: false)
        XCTAssertTrue(production.recording)
        XCTAssertTrue(production.ancillary)
    }

    func testOrdinaryRenderModelKeepsRecordingAndReportControlsBlockedWhileShowingActiveState() async throws {
        try await MainActor.run {
            let model = PreviewRenderer.sampleModel(arguments: ["--manual-ready"])
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            XCTAssertTrue(model.userCommandsArePreview)
            XCTAssertTrue(model.canRecordDiagnostics, "The render controller itself supports memory-only diagnostics")
            XCTAssertFalse(NativeUIAutomation.isInMemoryRecordingSession(controller),
                "An ordinary render controller must not impersonate the marked native fixture")
            XCTAssertFalse(model.diagnosticControlsAccess.recording)
            XCTAssertFalse(model.diagnosticControlsAccess.ancillary)
            let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
            let holding = model.workSessionHolding
            // Populate a visual sample directly, without UI input or native power requests.
            controller.setActivityRecording(true, minutes: 15)
            XCTAssertTrue(model.diagnosticRecordingActive)
            XCTAssertNotNil(model.diagnosticRecordingUntil)
            XCTAssertFalse(model.diagnosticControlsAccess.recording, "An active render sample's Stop stays disabled")
            XCTAssertFalse(model.diagnosticControlsAccess.ancillary)
            controller.setActivityRecording(false)
            XCTAssertFalse(model.diagnosticRecordingActive)
            XCTAssertEqual(model.workSessionHolding, holding)
            XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved)
        }
    }
}
