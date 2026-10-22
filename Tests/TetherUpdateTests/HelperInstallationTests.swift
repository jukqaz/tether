import XCTest
@testable import Tether
@testable import TetherCore

private final class InstallationAssertion: IdleAssertionBackend {
    var creates = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (0, 39) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { 0 }
}

private final class InstallationFileManager: FileManager, @unchecked Sendable {
    var absent: Set<String> = []
    var directories: Set<String> = []
    var nonExecutable: Set<String> = []
    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        isDirectory?.pointee = ObjCBool(directories.contains(path))
        return !absent.contains(path)
    }
    override func isExecutableFile(atPath path: String) -> Bool { !nonExecutable.contains(path) }
}

@MainActor
private final class InstallationFixture {
    let name = "TetherInstallationTests." + UUID().uuidString
    let defaults: UserDefaults
    let backend = InstallationAssertion()
    let controller: UserSessionController
    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        var settings = IdleSessionSettings()
        settings.enabled = false; settings.automaticEnabled = false
        settings.runtimeMarkers = RuntimeMarkers()
        settings.runtimeMarkers?.pauseReason = .userStop
        settings.runtimeMarkers?.protectionReason = "thermal"
        defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
        defaults.set(true, forKey: "helperUpgradePending")
        controller = UserSessionController(defaults: defaults, backend: backend,
            guiProbe: nil, environmentProbe: nil, boot: "installation-fixture")
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
    }
    func close() { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
}

/// Real installation decisions with injected files/transport/authorization only.
/// No privileged files, host helper or power settings are read or changed.
final class HelperInstallationTests: XCTestCase {
    @MainActor
    private func ready() -> ServiceReply {
        var status = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
            enabled: true, power: .ac, lidClosed: false, sleepDisabled: false,
            lastEvent: nil, lastEventAt: nil, thermal: 0)
        status.build = TetherPaths.build
        status.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
        status.systemPowerObservationAvailable = true
        var control = Control(); control.schemaVersion = Control.currentSchema
        var reply = ServiceReply(id: UUID(), ok: true, epoch: "installation-fixture", revision: 1,
            control: control, protection: .init(reason: nil, error: nil, dryRun: true))
        reply.status = status
        return reply
    }

    @MainActor
    private func model(_ fixture: InstallationFixture, missing: (() -> [HelperInstallationFile])? = nil,
                       installer: (() async throws -> Void)? = nil,
                       readiness: (() async throws -> ServiceReply)? = nil) -> AppModel {
        let reply = ready()
        return AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: fixture.controller,
            previewLegacyObservation: { .init(power: .ac, lidClosed: false, sleepDisabled: false) },
            previewWorkService: { _ in reply }, previewHelperReply: reply, previewDefaults: fixture.defaults,
            previewHelperInstaller: installer, previewHelperReadiness: readiness, previewHelperFiles: missing)
    }

    @MainActor
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        XCTFail("Injected installation did not settle", file: file, line: line)
    }

    @MainActor
    func testCurrentLiveHelperWithEachMissingComponentRequiresRepairWithoutChangingContractOrIntent() throws {
        for file in HelperInstallationFile.allCases {
            let fixture = try InstallationFixture(); defer { fixture.close() }
            let saved = fixture.defaults.data(forKey: UserSessionController.preferenceKey)
            let subject = model(fixture, missing: { [file] })
            XCTAssertTrue(subject.helperInstalled); XCTAssertTrue(subject.helperResponding)
            XCTAssertFalse(subject.helperOutdated, "A missing file does not mean an old wire contract")
            XCTAssertTrue(subject.helperNeedsRepair); XCTAssertEqual(subject.missingHelperFiles, [file])
            XCTAssertFalse(subject.helperSetupVerified); XCTAssertFalse(subject.helperSetupConfirmed)
            XCTAssertTrue(subject.canFinishOnboarding, "General work can finish setup without repairing an unused lid helper")
            XCTAssertFalse(subject.canFinishOnboarding(allowClosedLid: true))
            XCTAssertNotNil(subject.helperInstallationIssue)
            XCTAssertFalse(subject.helperInstallationIssue?.contains("/Library/") == true)
            XCTAssertFalse(subject.enabled); XCTAssertEqual(fixture.controller.runtimeMarkers.protectionReason, "thermal")
            XCTAssertEqual(fixture.defaults.data(forKey: UserSessionController.preferenceKey), saved)
            XCTAssertEqual(fixture.backend.creates, 0)
        }
    }

    @MainActor
    func testSameVersionLiveReplyCannotSkipRepairOfTheMissingDaemonRegistration() async throws {
        let fixture = try InstallationFixture(); defer { fixture.close() }
        let saved = fixture.defaults.data(forKey: UserSessionController.preferenceKey)
        var missing: [HelperInstallationFile] = [.helperRegistration]
        var installations = 0, queries = 0
        let subject = model(fixture, missing: { missing }, installer: {
            installations += 1; missing = []
        }, readiness: { queries += 1; return self.ready() })
        subject.installHelper(automatically: true)
        await wait { !subject.helperInstallInFlight }
        XCTAssertEqual(installations, 1); XCTAssertEqual(queries, 2)
        XCTAssertFalse(subject.helperNeedsRepair); XCTAssertTrue(subject.helperSetupConfirmed)
        XCTAssertNil(subject.errorText); XCTAssertNil(fixture.defaults.object(forKey: "helperUpgradePending"))
        XCTAssertEqual(fixture.defaults.data(forKey: UserSessionController.preferenceKey), saved)
        XCTAssertFalse(subject.enabled); XCTAssertEqual(fixture.controller.runtimeMarkers.protectionReason, "thermal")
        XCTAssertEqual(fixture.backend.creates, 0)
    }

    @MainActor
    func testCompleteCurrentInstallationSkipsAuthorizationAndPreservesStoppedProtectedIntent() async throws {
        let fixture = try InstallationFixture(); defer { fixture.close() }
        let saved = fixture.defaults.data(forKey: UserSessionController.preferenceKey)
        var installations = 0, queries = 0
        let subject = model(fixture, missing: { [] }, installer: { installations += 1 },
                            readiness: { queries += 1; return self.ready() })
        subject.installHelper(automatically: true)
        await wait { !subject.helperInstallInFlight }
        XCTAssertEqual(installations, 0); XCTAssertEqual(queries, 1)
        XCTAssertTrue(subject.helperSetupConfirmed); XCTAssertFalse(subject.helperNeedsRepair)
        XCTAssertNil(fixture.defaults.object(forKey: "helperUpgradePending"))
        XCTAssertEqual(fixture.defaults.data(forKey: UserSessionController.preferenceKey), saved)
        XCTAssertFalse(subject.enabled); XCTAssertEqual(fixture.controller.runtimeMarkers.protectionReason, "thermal")
        XCTAssertEqual(fixture.backend.creates, 0)
    }

    @MainActor
    func testCancelledOrFailedRepairRetainsMissingFilesPendingUpdateAndStoppedProtectedIntent() async throws {
        for cancelled in [true, false] {
            let fixture = try InstallationFixture(); defer { fixture.close() }
            let saved = fixture.defaults.data(forKey: UserSessionController.preferenceKey)
            var installations = 0
            let subject = model(fixture, missing: { [.helperRegistration] }, installer: {
                installations += 1
                if cancelled { throw SystemIntegration.Failure.cancelled }
                throw SystemIntegration.Failure.message("Injected repair failure")
            }, readiness: { self.ready() })
            subject.installHelper(automatically: true)
            await wait { !subject.helperInstallInFlight }
            XCTAssertEqual(installations, 1)
            XCTAssertTrue(subject.helperNeedsRepair); XCTAssertFalse(subject.helperSetupConfirmed)
            XCTAssertTrue(fixture.defaults.bool(forKey: "helperUpgradePending"))
            XCTAssertEqual(fixture.defaults.data(forKey: UserSessionController.preferenceKey), saved)
            XCTAssertFalse(subject.enabled); XCTAssertEqual(fixture.controller.runtimeMarkers.protectionReason, "thermal")
            XCTAssertEqual(subject.errorText, cancelled ? nil : "Injected repair failure")
            XCTAssertEqual(fixture.backend.creates, 0)
        }
    }

    @MainActor
    func testSuccessfulInstallerExitAndCurrentWireReplyCannotConfirmFilesStillMissing() async throws {
        let fixture = try InstallationFixture(); defer { fixture.close() }
        var installations = 0, queries = 0
        let subject = model(fixture, missing: { [.recoveryExecutor] }, installer: { installations += 1 },
                            readiness: { queries += 1; return self.ready() })
        subject.installHelper(automatically: true)
        await wait { !subject.helperInstallInFlight }
        XCTAssertEqual(installations, 1); XCTAssertEqual(queries, 2)
        XCTAssertTrue(subject.helperNeedsRepair); XCTAssertFalse(subject.helperSetupConfirmed)
        XCTAssertTrue(fixture.defaults.bool(forKey: "helperUpgradePending"))
        XCTAssertEqual(subject.errorText, subject.helperInstallationIssue)
    }

    @MainActor
    func testPendingRepairRejectsDuplicateAuthorizationAndRefreshDoesNotEndGeneralIntent() async throws {
        let fixture = try InstallationFixture(); defer { fixture.close() }
        var waiting: CheckedContinuation<Void, Error>?
        defer { waiting?.resume(throwing: SystemIntegration.Failure.cancelled) }
        var missing: [HelperInstallationFile] = [.helperRegistration]
        var installations = 0
        let subject = model(fixture, missing: { missing }, installer: {
            installations += 1
            try await withCheckedThrowingContinuation { waiting = $0 }
        }, readiness: { self.ready() })
        subject.installHelper(automatically: true); subject.installHelper(); subject.installHelper(automatically: true)
        await wait { waiting != nil }
        subject.refresh()
        await Task.yield()
        XCTAssertEqual(installations, 1); XCTAssertTrue(subject.helperInstallInFlight)
        XCTAssertTrue(subject.helperNeedsRepair)
        XCTAssertNil(fixture.defaults.object(forKey: HelperUpgradeAttempt.preferenceKey), "Preview refresh cannot claim a production authorization attempt")
        missing = []
        let continuation = waiting; waiting = nil; continuation?.resume()
        await wait { !subject.helperInstallInFlight }
        XCTAssertTrue(subject.helperSetupConfirmed); XCTAssertFalse(subject.enabled)
        XCTAssertEqual(fixture.controller.runtimeMarkers.protectionReason, "thermal")
    }

    @MainActor
    func testPreviewWithoutExplicitFileObservationNeverRunsAnInstallerOrAssumesHostFiles() throws {
        let fixture = try InstallationFixture(); defer { fixture.close() }
        var installations = 0, queries = 0
        let subject = model(fixture, installer: { installations += 1 },
                            readiness: { queries += 1; return self.ready() })
        subject.installHelper(); subject.installHelper(automatically: true)
        XCTAssertEqual(installations, 0); XCTAssertEqual(queries, 0)
        XCTAssertFalse(subject.helperFilesChecked); XCTAssertFalse(subject.helperSetupConfirmed)
        XCTAssertFalse(subject.helperInstallInFlight)
    }

    @MainActor
    func testDevelopmentServiceAndPreviewRefreshNeverAutomaticallyInstallOrClaimAuthorization() async throws {
        let previous = ProcessInfo.processInfo.environment["TETHER_SERVICE_SOCKET"]
        setenv("TETHER_SERVICE_SOCKET", "/tmp/tether-installation-fixture-" + UUID().uuidString, 1)
        defer {
            if let previous { setenv("TETHER_SERVICE_SOCKET", previous, 1) }
            else { unsetenv("TETHER_SERVICE_SOCKET") }
        }
        let fixture = try InstallationFixture(); defer { fixture.close() }
        var installations = 0
        let subject = model(fixture, missing: { [.helperRegistration] }, installer: { installations += 1 },
                            readiness: { self.ready() })
        XCTAssertTrue(subject.developmentService)
        subject.refresh()
        await Task.yield()
        XCTAssertEqual(installations, 0)
        XCTAssertNil(fixture.defaults.object(forKey: HelperUpgradeAttempt.preferenceKey))
        XCTAssertTrue(subject.helperNeedsRepair); XCTAssertFalse(subject.helperSetupConfirmed)
    }

    @MainActor
    func testDurableFileProbeCoversEachRequiredRoleAndRejectsDirectoriesOrNonExecutableTools() {
        let files = InstallationFileManager()
        XCTAssertEqual(SystemIntegration.missingHelperFiles(fileManager: files), [])
        for file in HelperInstallationFile.allCases {
            files.absent = [file.path]
            XCTAssertEqual(SystemIntegration.missingHelperFiles(fileManager: files), [file])
        }
        files.absent = []
        files.directories = [HelperInstallationFile.helperRegistration.path]
        XCTAssertEqual(SystemIntegration.missingHelperFiles(fileManager: files), [.helperRegistration])
        files.directories = []
        for file in HelperInstallationFile.allCases.filter(\.requiresExecutable) {
            files.nonExecutable = [file.path]
            XCTAssertEqual(SystemIntegration.missingHelperFiles(fileManager: files), [file])
        }
    }

    @MainActor
    func testDoctorReportsMissingRolesSeparatelyFromTheCurrentLiveHelperWithoutRawPaths() {
        for file in HelperInstallationFile.allCases {
            var evidence = HealthChecks.Evidence()
            evidence.reply = ready(); evidence.missingHelperFiles = [file]
            let checks = HealthChecks.evaluate(evidence, now: Date(), language: .korean)
            let installation = checks.first { $0.name == "도우미 설치" }
            XCTAssertEqual(installation?.result, .failed)
            XCTAssertTrue(installation?.detail.contains(file.title(language: .korean)) == true)
            XCTAssertFalse(installation?.detail.contains("/Library/") == true)
            XCTAssertEqual(checks.first { $0.name == "도우미 연결" }?.result, .ok)
            XCTAssertEqual(checks.first { $0.name == "도우미 버전" }?.result, .ok)
        }
    }
}
