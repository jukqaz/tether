import XCTest
@testable import Tether
import TetherCore

private final class ActivityAssertionFixture: IdleAssertionBackend {
    var creates = 0
    var releases = 0
    var releaseFailure = false
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (0, 17) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { releases += 1; return releaseFailure ? -1 : 0 }
}

final class UserSessionActivityControllerTests: XCTestCase {
    func testHelperlessDiagnosticsNeverWriteSettingsOrStartPowerWork() async throws {
        try await MainActor.run {
            let name = "tether-activity-\(UUID())", backend = ActivityAssertionFixture()
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
            let model = AppModel(preview: true,
                capabilities: MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false),
                previewSession: controller, previewDefaults: defaults)
            let before = defaults.data(forKey: UserSessionController.preferenceKey)
            XCTAssertTrue(model.usesUserSession); XCTAssertFalse(model.helperInstalled); XCTAssertTrue(model.canRecordDiagnostics)
            model.setDebugLogging(true, minutes: 15)
            XCTAssertTrue(model.diagnosticRecordingActive)
            XCTAssertEqual(model.diagnosticRecordingUntil!.timeIntervalSinceNow, 900, accuracy: 2)
            model.markDiagnostic()
            XCTAssertTrue(model.commonActivity.contains { $0.kind == .marker })
            XCTAssertNotNil(model.diagnosticNote); XCTAssertFalse(model.commandPending)
            model.setDebugLogging(false)
            XCTAssertFalse(model.diagnosticRecordingActive)
            XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), before)
            XCTAssertEqual(backend.creates, 0); XCTAssertEqual(backend.releases, 0)
            XCTAssertTrue(controller.end())
        }
    }
    func testObservedWorkAndReleaseAreRecordedAndDetailEndsWithCoordinator() async throws {
        try await MainActor.run {
            let name = "tether-activity-\(UUID())", backend = ActivityAssertionFixture()
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
            var updates = 0; controller.onActivityChange = { updates += 1 }
            controller.setActivityRecording(true)
            XCTAssertTrue(controller.start(duration: nil))
            XCTAssertTrue(controller.activity.entries.contains { $0.state?.holding == true && $0.state?.manualActive == true })
            controller.stopCurrent()
            XCTAssertTrue(controller.activity.entries.contains { $0.kind == .released })
            XCTAssertTrue(controller.end()); XCTAssertFalse(controller.activity.isRecording())
            XCTAssertEqual(controller.activity.entries.last(where: { $0.kind == .recordingEnded })?.kind, .recordingEnded)
            XCTAssertGreaterThan(updates, 2)
        }
    }
    func testDetailedRecordingCanBeStoppedAfterARejectedQuit() async throws {
        try await MainActor.run {
            let name = "tether-activity-\(UUID())", backend = ActivityAssertionFixture()
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
            XCTAssertTrue(controller.start(duration: nil))
            controller.setActivityRecording(true)
            backend.releaseFailure = true
            XCTAssertFalse(controller.end()); XCTAssertTrue(controller.activity.isRecording())
            let creates = backend.creates, releases = backend.releases
            controller.setActivityRecording(false)
            XCTAssertFalse(controller.activity.isRecording())
            XCTAssertEqual(backend.creates, creates); XCTAssertEqual(backend.releases, releases)
            XCTAssertEqual(controller.activity.entries.last?.kind, .recordingEnded)
            backend.releaseFailure = false; XCTAssertTrue(controller.end())
        }
    }
    func testRecordingAndMarkersRejectLostCoordinatorOwnership() async throws {
        try await MainActor.run {
            let name = "tether-activity-\(UUID())", backend = ActivityAssertionFixture()
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil)
            controller.ownershipProbe = { false }
            controller.setActivityRecording(true)
            XCTAssertFalse(controller.markActivity()); XCTAssertTrue(controller.activity.entries.isEmpty)
            XCTAssertFalse(controller.activity.isRecording())
            controller.ownershipProbe = { true }; XCTAssertTrue(controller.end())
        }
    }
}
