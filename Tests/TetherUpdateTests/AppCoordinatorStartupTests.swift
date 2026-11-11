import XCTest
@testable import Tether
import TetherCore

private final class StartupAssertionFixture: IdleAssertionBackend {
    var creates = 0, renews = 0, releases = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (0, 71) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { renews += 1; return 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { releases += 1; return 0 }
}

final class AppCoordinatorStartupTests: XCTestCase {
    @MainActor
    private func fixture(_ body: (URL, UserDefaults, StartupAssertionFixture, String) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("tether-app-lease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let name = "TetherStartupTests." + UUID().uuidString
        let defaults = TestMemoryDefaults(domain: name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        try await body(directory, defaults, StartupAssertionFixture(), name)
    }
    @MainActor
    private func controller(_ defaults: UserDefaults, _ backend: StartupAssertionFixture) -> UserSessionController {
        let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil)
        subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
        return subject
    }
    @MainActor
    func testOnlyTheLeaseOwnerCanConstructAWriterAndStoppingTheSocketDoesNotTransferOwnership() async throws {
        try await fixture { directory, defaults, backend, domain in
            let path = directory.appendingPathComponent("instance.lock").path
            let owned = controller(defaults, backend)
            let first = AppModel(preview: true, capabilities: .init(supportedPlatform: true, internalBattery: false, lid: false),
                previewSession: owned, previewDefaults: defaults, previewCoordinatorPath: path,
                previewCommandPath: directory.appendingPathComponent("commands.sock").path)
            XCTAssertTrue(first.hasCoordinatorAuthority); XCTAssertTrue(first.usesUserSession)
            XCTAssertNotNil(first.userCommandService)
            first.startManualSession(minutes: nil); XCTAssertEqual(backend.creates, 1)
            let saved = defaults.persistentDomain(forName: domain) ?? [:]
            let second = AppModel(preview: true, capabilities: .init(supportedPlatform: true, internalBattery: false, lid: false),
                previewSession: controller(defaults, StartupAssertionFixture()), previewDefaults: defaults, previewCoordinatorPath: path)
            XCTAssertFalse(second.hasCoordinatorAuthority); XCTAssertNotNil(second.coordinatorStartFailure)
            XCTAssertFalse(second.usesUserSession); XCTAssertFalse(second.sessionAvailable)
            second.setEnabled(true); second.setTriggerEnabled(true); second.startManualSession(minutes: nil)
            second.startBatteryHold(minutes: 30); second.notifyHeat.toggle(); second.finishOnboarding()
            XCTAssertEqual((defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary, saved as NSDictionary)
            first.userCommandService?.stop()
            XCTAssertThrowsError(try AppCoordinatorLease.acquire(at: path))
            let quit = await first.prepareToQuit(); XCTAssertTrue(quit); XCTAssertEqual(backend.releases, 1)
            // Even a successful quit acknowledgement is before actual process exit.
            XCTAssertThrowsError(try AppCoordinatorLease.acquire(at: path))
        }
    }
    @MainActor
    func testAnOccupiedCommandEndpointFailsBeforeBindingOrWritingSessionSettings() async throws {
        try await fixture { directory, defaults, backend, domain in
            let path = directory.appendingPathComponent("commands.sock").path
            let server = UserSessionService(path: path)
            try server.start { request, _ in UserSessionReply(id: request.id, epoch: UUID(), revision: 0, ok: false) }
            defer { server.stop() }
            let subject = controller(defaults, backend)
            let before = defaults.persistentDomain(forName: domain) ?? [:]
            let model = AppModel(preview: true, capabilities: .init(supportedPlatform: true, internalBattery: false, lid: false),
                previewSession: subject, previewDefaults: defaults,
                previewCoordinatorPath: directory.appendingPathComponent("instance.lock").path, previewCommandPath: path)
            XCTAssertNotNil(model.coordinatorStartFailure); XCTAssertFalse(model.hasCoordinatorAuthority)
            XCTAssertFalse(model.usesUserSession); XCTAssertNil(model.userCommandService)
            model.setUserAutomatic(true); model.startManualSession(minutes: 30); model.startBatteryHold(minutes: 30)
            model.panelCompact.toggle(); model.notifyHeat.toggle(); model.language = .korean
            XCTAssertEqual((defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary, before as NSDictionary)
            XCTAssertEqual(backend.creates, 0)
            let quit = await model.prepareToQuit(); XCTAssertTrue(quit)
        }
    }
    @MainActor
    func testPreferenceBackupFailureStopsBeforeBindingOrAcceptingAnySettingsOrSessionCommand() async throws {
        try await fixture { directory, defaults, backend, domain in
            let legacyDomain = domain + ".legacy"
            defer { defaults.removePersistentDomain(forName: legacyDomain) }
            var settings = IdleSessionSettings()
            settings.enabled = false; settings.legacyRootConfigurationPending = false
            defaults.setPersistentDomain([
                UserSessionController.preferenceKey: try JSONEncoder().encode(settings),
                "updateChannel": "beta", "checkUpdates": false, "menuBarDetails": false,
                "panelCompact": false, "notifyHeat": false
            ], forName: domain)
            defaults.setPersistentDomain(["updateChannel": "stable", "checkUpdates": true,
                "notifyHeat": true, "savedBuiltInBrightness": 0.7], forName: legacyDomain)
            let subject = controller(defaults, backend)
            let currentBefore = defaults.persistentDomain(forName: domain) ?? [:]
            let legacyBefore = defaults.persistentDomain(forName: legacyDomain) ?? [:]
            let blockedBackup = directory.appendingPathComponent("occupied-backup")
            try Data("occupied".utf8).write(to: blockedBackup)
            var migrationAttempts = 0
            let model = AppModel(preview: true,
                capabilities: .init(supportedPlatform: true, internalBattery: false, lid: false),
                previewSession: subject, previewDefaults: defaults,
                previewCoordinatorPath: directory.appendingPathComponent("instance.lock").path,
                previewCommandPath: directory.appendingPathComponent("commands.sock").path,
                previewPreferencesMigration: {
                    migrationAttempts += 1
                    try PreferenceMigration.apply(defaults: defaults, domain: domain, legacyDomain: legacyDomain,
                        backupDirectory: blockedBackup, hadExistingInstall: true)
                })
            defer { model.userCommandService?.stop(); _ = subject.end() }
            XCTAssertEqual(migrationAttempts, 1)
            XCTAssertNotNil(model.coordinatorStartFailure); XCTAssertNotNil(model.errorText)
            XCTAssertFalse(model.hasCoordinatorAuthority); XCTAssertFalse(model.acceptingUserCommands)
            XCTAssertFalse(model.usesUserSession); XCTAssertFalse(model.sessionAvailable)
            XCTAssertNil(model.userCommandService)
            model.startManualSession(minutes: 30); model.setEnabled(true); model.setUserAutomatic(true)
            model.setTriggerEnabled(true); model.setPowerCondition(.ac); model.finishOnboarding()
            model.panelCompact.toggle(); model.notifyHeat.toggle(); model.menuBarDetails.toggle()
            model.checkUpdates.toggle(); model.setUpdateChannel(.stable)
            model.handle(url: try XCTUnwrap(URL(string: "tether://manual/30m")))
            model.handle(url: try XCTUnwrap(URL(string: "tether://on")))
            XCTAssertEqual((defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary, currentBefore as NSDictionary)
            XCTAssertEqual((defaults.persistentDomain(forName: legacyDomain) ?? [:]) as NSDictionary, legacyBefore as NSDictionary)
            XCTAssertFalse(subject.status.holding); XCTAssertFalse(subject.status.manualActive)
            XCTAssertEqual(backend.creates, 0); XCTAssertEqual(backend.renews, 0); XCTAssertEqual(backend.releases, 0)
            XCTAssertEqual(try Data(contentsOf: blockedBackup), Data("occupied".utf8))
            let quit = await model.prepareToQuit(); XCTAssertTrue(quit)
        }
    }
    @MainActor
    func testLostLockIdentityReleasesOnlyItsOwnRequestAndStopsFurtherSettingsOrLeaseWrites() async throws {
        try await fixture { directory, defaults, backend, domain in
            let path = directory.appendingPathComponent("instance.lock").path
            let subject = controller(defaults, backend)
            let model = AppModel(preview: true, capabilities: .init(supportedPlatform: true, internalBattery: false, lid: false),
                previewSession: subject, previewDefaults: defaults, previewCoordinatorPath: path)
            model.startManualSession(minutes: nil)
            XCTAssertEqual(backend.creates, 1); XCTAssertTrue(subject.status.holding)
            let before = defaults.persistentDomain(forName: domain) ?? [:]
            try FileManager.default.moveItem(atPath: path, toPath: directory.appendingPathComponent("previous.lock").path)
            let replacement = try AppCoordinatorLease.acquire(at: path)
            XCTAssertTrue(replacement.isValid); XCTAssertFalse(model.hasCoordinatorAuthority)
            subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
            XCTAssertFalse(subject.status.holding); XCTAssertFalse(subject.status.canStart)
            XCTAssertNil(subject.workLease()); XCTAssertEqual(backend.releases, 1)
            XCTAssertFalse(subject.start(duration: 60)); subject.setAutomatic(true); subject.setPowerCondition(.any)
            model.startManualSession(minutes: 30); model.notifyHeat.toggle(); model.handle(url: URL(string: "tether://on")!)
            XCTAssertEqual((defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary, before as NSDictionary)
            XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.renews, 0)
            let quit = await model.prepareToQuit(); XCTAssertTrue(quit)
        }
    }
}
