import XCTest
@testable import Tether
import TetherCore

private final class CommandAssertionFixture: IdleAssertionBackend {
    var creates = 0, renews = 0, releases = 0
    var createCode: Int32 = 0, releaseCode: Int32 = 0
    var levelValue: Int? = 255
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (createCode, createCode == 0 ? 37 : nil) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { renews += 1; return 0 }
    func level(id: UInt32) -> Int? { levelValue }
    func release(id: UInt32) -> Int32 { releases += 1; return releaseCode }
}

private final class QueuedSleepObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var requests = 0
    private var current: GUISessionObservation
    init(_ current: GUISessionObservation) { self.current = current }
    var queueHeld: Bool { lock.withLock { entered } }
    var sleepRequests: Int { lock.withLock { requests } }
    func markQueueHeld() { lock.withLock { entered = true } }
    func recordSleep() { lock.withLock { requests += 1 } }
    func setObservation(_ observation: GUISessionObservation) { lock.withLock { current = observation } }
    func observation() -> GUISessionObservation { lock.withLock { current } }
}

@MainActor
private final class CommandFixture {
    let name = "TetherUserCommandTests." + UUID().uuidString
    let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("tether-cmd-" + UUID().uuidString)
    let backend = CommandAssertionFixture()
    let owner = GUISessionObservation(login: .init(uid: getuid(), sessionID: 100001), consoleUID: getuid())
    let defaults: UserDefaults
    let controller: UserSessionController
    let model: AppModel
    let peer: UserSessionPeer
    var socket: String { folder.appendingPathComponent("commands.sock").path }

    init(power: PowerSource = .ac, capabilities: MacCapabilities? = nil,
         capabilityProbe: (() -> MacCapabilities)? = nil, settings: IdleSessionSettings? = nil,
         sleepExecutor: (() async -> Bool)? = nil, sleepSettled: (() -> Bool)? = nil,
         sleepAuthority: (() -> GUISessionObservation)? = nil) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        if let settings { defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey) }
        controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil)
        controller.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: power == .battery ? 80 : nil)
        model = AppModel(preview: true,
            capabilities: capabilities ?? MacCapabilities(supportedPlatform: true,
                internalBattery: power == .battery, lid: power == .battery), previewSession: controller,
            previewCapabilitiesProbe: capabilityProbe,
            previewSleepExecutor: sleepExecutor, previewSleepSettled: sleepSettled,
            previewSleepAuthority: sleepAuthority)
        let process = try XCTUnwrap(ProcessIdentity.capture(pid: getpid()))
        peer = UserSessionPeer(uid: getuid(), process: process, login: nil)
        model.userCommandCompanion = process.executable
        model.userCommandOwnerProbe = { [owner] in owner }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func request(_ command: TetherCommand) -> UserSessionRequest {
        let state = model.userCommandReply(UserSessionRequest())
        return UserSessionRequest(command, epoch: state.epoch, revision: state.revision)
    }
    func perform(_ command: TetherCommand) async -> UserSessionReply {
        await model.handleUserCommand(request(command), peer: peer)
    }
    func close() {
        model.userCommandService?.stop(); backend.releaseCode = 0
        _ = controller.end(); defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }
}

final class UserSessionCommandTests: XCTestCase {
    @MainActor
    func testHelperProtocolReadinessIsIndependentOfCommonProtectionPresentation() throws {
        let f = try CommandFixture(); defer { f.close() }
        for (protocolVersion, coordinator, outdated) in [
            (Optional(2), Optional(WorkSessionLease.coordinatorVersion), false),
            (Optional(1), Optional(WorkSessionLease.coordinatorVersion), true),
            (nil, Optional(WorkSessionLease.coordinatorVersion), true),
            (Optional(2), Optional(WorkSessionLease.coordinatorVersion - 1), true),
            (Optional(2), nil, true)
        ] {
            var reply = helperInstallationReply()
            if let protocolVersion { reply.protection?.protocolVersion = protocolVersion }
            else { reply.protection = nil }
            reply.status?.workSessionCoordinatorVersion = coordinator
            let model = AppModel(preview: true,
                capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: f.controller, previewWorkService: { _ in reply },
                previewHelperReply: reply, previewDefaults: f.defaults, previewHelperFiles: { [] })
            XCTAssertNil(model.protection, "An unblocked common session has no protection banner")
            XCTAssertEqual(model.helperOutdated, outdated, "Wire protocol must not come from that banner")
        }
    }

    @MainActor
    private func helperInstallationReply() -> ServiceReply {
        var status = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
            enabled: true, power: .ac, lidClosed: false, sleepDisabled: false,
            lastEvent: nil, lastEventAt: nil, thermal: 0)
        status.build = TetherPaths.build
        status.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
        var control = Control(); control.schemaVersion = Control.currentSchema
        var reply = ServiceReply(id: UUID(), ok: true, epoch: "installation-fixture", revision: 1,
            control: control, protection: .init(reason: nil, error: nil, dryRun: true))
        reply.status = status
        return reply
    }

    @MainActor
    func testNotebookSetupCannotFinishWithoutVerifiedHelperOrBySavedFlagAlone() throws {
        let f = try CommandFixture(); defer { f.close() }
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: f.controller, previewDefaults: f.defaults)
        XCTAssertTrue(model.requiresHelperSetup); XCTAssertTrue(model.helperSetupChecked)
        XCTAssertFalse(model.helperSetupConfirmed); XCTAssertFalse(model.canFinishOnboarding)
        model.finishOnboarding()
        XCTAssertFalse(f.defaults.bool(forKey: "onboarded")); XCTAssertTrue(model.needsOnboarding)
        f.defaults.set(true, forKey: "onboarded")
        XCTAssertTrue(model.needsOnboarding, "A stored flag does not approve a missing helper")
        XCTAssertEqual(f.backend.creates, 0)
    }

    @MainActor
    func testCurrentNotebookHelperFinishesSetupWithoutStartingTriggersOrLidHold() throws {
        let f = try CommandFixture(); defer { f.close() }
        f.controller.setAutomatic(false)
        var reply = helperInstallationReply()
        reply.protection?.blockReason = "thermal"
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: f.controller, previewWorkService: { _ in reply },
            previewHelperReply: reply, previewDefaults: f.defaults, previewHelperFiles: { [] })
        XCTAssertTrue(model.helperSetupConfirmed); XCTAssertTrue(model.canFinishOnboarding)
        XCTAssertFalse(model.clamshellActive); XCTAssertFalse(model.automaticWorkReasonActive)
        model.finishOnboarding()
        XCTAssertTrue(f.defaults.bool(forKey: "onboarded")); XCTAssertFalse(model.needsOnboarding)
        XCTAssertEqual(f.backend.creates, 0, "Readiness is independent of starting work")
    }

    @MainActor
    func testNotebookSetupRejectsOldStaleAndIncompatibleHelperObservations() throws {
        let changes: [(String, (inout ServiceReply) -> Void)] = [
            ("old build", { $0.status?.build = TetherPaths.build - 1 }),
            ("old protocol", { $0.version = 1 }),
            ("missing protection", { $0.protection = nil }),
            ("old protection protocol", { $0.protection?.protocolVersion = 1 }),
            ("old schema", { $0.control.schemaVersion = Control.currentSchema - 1 }),
            ("old coordinator", { $0.status?.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion - 1 }),
            ("stale", { $0.status?.updatedAt = Date().addingTimeInterval(-31).timeIntervalSince1970 }),
            ("future", { $0.status?.updatedAt = Date().addingTimeInterval(60).timeIntervalSince1970 }),
            ("invalid timestamp", { $0.status?.updatedAt = .nan }),
            ("power observation missing", { $0.status?.systemPowerObservationAvailable = false }),
            ("migration failed", { $0.protection?.blockReason = "migrationFailed" }),
            ("rejected reply", { $0.ok = false })
        ]
        let f = try CommandFixture(); defer { f.close() }
        for (name, change) in changes {
            var reply = helperInstallationReply(); change(&reply)
            f.defaults.removeObject(forKey: "onboarded")
            let model = AppModel(preview: true,
                capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: f.controller, previewWorkService: { _ in reply },
                previewHelperReply: reply, previewDefaults: f.defaults, previewHelperFiles: { [] })
            XCTAssertTrue(model.helperSetupChecked, name)
            XCTAssertFalse(model.helperSetupConfirmed, name); XCTAssertFalse(model.canFinishOnboarding, name)
            model.finishOnboarding()
            XCTAssertFalse(f.defaults.bool(forKey: "onboarded"), name)
        }
    }

    @MainActor
    func testExistingNotebookSetupWaitsForInitialReadAndDoesNotReopenWhenReady() async throws {
        for unavailable in [false, true] {
            let f = try CommandFixture(); defer { f.close() }
            f.defaults.set(true, forKey: "onboarded")
            let reply = helperInstallationReply()
            let model = AppModel(preview: true,
                capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: f.controller, previewWorkService: { _ in
                    if unavailable { throw ServiceFailure("unavailable") }
                    return reply
                }, previewDefaults: f.defaults, previewHelperFiles: { [] })
            XCTAssertFalse(model.helperSetupChecked)
            XCTAssertFalse(model.needsOnboarding, "Do not treat an unfinished startup query as missing installation")
            model.refresh()
            await waitForHelperInstallation { model.helperSetupChecked }
            XCTAssertEqual(model.helperSetupConfirmed, !unavailable)
            XCTAssertEqual(model.needsOnboarding, unavailable)
        }
    }

    @MainActor
    func testIncompleteNotebookObservationDoesNotWaitForASkippedHelperQuery() throws {
        let f = try CommandFixture(); defer { f.close() }
        f.defaults.set(true, forKey: "onboarded")
        var queries = 0
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: nil),
            previewSession: f.controller, previewWorkService: { _ in
                queries += 1; return self.helperInstallationReply()
            }, previewDefaults: f.defaults)
        XCTAssertTrue(model.requiresHelperSetup); XCTAssertFalse(model.helperSetupChecked)
        XCTAssertFalse(model.needsOnboarding)
        model.refresh()
        XCTAssertEqual(queries, 0, "Unconfirmed lid capability cannot use the root route")
        XCTAssertTrue(model.helperSetupChecked); XCTAssertTrue(model.needsOnboarding)
        XCTAssertFalse(model.canFinishOnboarding); XCTAssertFalse(model.helperSetupConfirmed)
    }

    @MainActor
    func testDesktopSetupFinishesWithoutHelperAndNeverRunsInstaller() async throws {
        let f = try CommandFixture(); defer { f.close() }
        var installations = 0, queries = 0
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: false, lid: false),
            previewSession: f.controller, previewLegacyObservation: { .init(power: .ac, lidClosed: false, sleepDisabled: false) },
            previewDefaults: f.defaults, previewHelperInstaller: { installations += 1 },
            previewHelperReadiness: { queries += 1; return self.helperInstallationReply() }, previewHelperFiles: { [] })
        XCTAssertFalse(model.requiresHelperSetup); XCTAssertFalse(model.showsLidOptions)
        XCTAssertFalse(model.helperInstalled); XCTAssertTrue(model.canFinishOnboarding)
        model.finishOnboarding()
        XCTAssertFalse(model.needsOnboarding); XCTAssertTrue(f.defaults.bool(forKey: "onboarded"))
        model.installHelper()
        await waitForHelperInstallation { !model.helperInstallInFlight }
        XCTAssertEqual(installations, 0); XCTAssertEqual(queries, 0)
        XCTAssertFalse(model.helperInstalled)
        model.startManualSession(minutes: nil)
        XCTAssertTrue(model.workSessionHolding); XCTAssertEqual(f.backend.creates, 1)
    }

    @MainActor
    func testUnconfirmedHardwareCannotSkipRequiredSetupAsDesktop() async throws {
        let f = try CommandFixture(); defer { f.close() }
        var installations = 0
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: nil, lid: nil),
            previewSession: f.controller, previewDefaults: f.defaults,
            previewHelperInstaller: { installations += 1 },
            previewHelperReadiness: { self.helperInstallationReply() }, previewHelperFiles: { [] })
        XCTAssertFalse(model.canFinishOnboarding); XCTAssertTrue(model.needsOnboarding)
        model.finishOnboarding(); XCTAssertFalse(f.defaults.bool(forKey: "onboarded"))
        model.installHelper()
        await waitForHelperInstallation { !model.helperInstallInFlight }
        XCTAssertEqual(installations, 0); XCTAssertFalse(model.helperSetupConfirmed)
    }

    @MainActor
    func testHelperInstallationWaitKeepsIPCAndRefreshResponsiveAndRejectsDuplicate() async throws {
        let f = try CommandFixture(); defer { f.close() }
        let controller = UserSessionController(defaults: f.defaults, backend: f.backend,
            guiProbe: { f.owner }, environmentProbe: { .init(power: .ac, thermal: 0, fullWake: true, batteryPercent: 80) })
        defer { _ = controller.end() }
        var waiting: CheckedContinuation<Void, Error>?
        var installations = 0, readinessQueries = 0
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller, previewLegacyObservation: { .init(power: .ac, lidClosed: false, sleepDisabled: false) },
            previewDefaults: f.defaults, previewHelperInstaller: {
                installations += 1
                try await withCheckedThrowingContinuation { waiting = $0 }
            }, previewHelperReadiness: { readinessQueries += 1; return self.helperInstallationReply() }, previewHelperFiles: { [] })
        defer { model.userCommandService?.stop(); waiting?.resume(throwing: SystemIntegration.Failure.cancelled) }
        let executable = f.peer.process.executable
        XCTAssertTrue(model.startUserCommandService(path: f.socket, expectedCompanion: executable, ownerProbe: { f.owner }))
        model.startManualSession(minutes: 10)
        XCTAssertTrue(controller.status.holding)
        model.installHelper()
        XCTAssertTrue(model.helperInstallInFlight, "The slot must be reserved before the first await")
        model.installHelper(); model.installHelper(automatically: true)
        await waitForHelperInstallation { waiting != nil }
        XCTAssertEqual(installations, 1); XCTAssertEqual(readinessQueries, 0)

        // The real private socket still routes through its MainActor handler while
        // an injected authorization awaits completion. No OS power/auth call occurs.
        let socket = f.socket
        let reply = try await Task.detached {
            try UserSessionClient(path: socket, expectedServer: executable).snapshot()
        }.value
        XCTAssertTrue(reply.ok); XCTAssertTrue(reply.status?.holding == true)
        XCTAssertTrue(model.helperInstallInFlight)
        let renews = f.backend.renews
        let refresh = Task { @MainActor in controller.refresh() }
        await refresh.value
        XCTAssertGreaterThan(f.backend.renews, renews, "The native finite assertion can renew during authorization")
        XCTAssertEqual(installations, 1)
        waiting?.resume(); waiting = nil
        await waitForHelperInstallation { !model.helperInstallInFlight }
        XCTAssertEqual(readinessQueries, 1); XCTAssertNil(model.errorText)
        XCTAssertFalse(model.helperOutdated)
    }

    @MainActor
    func testAutomaticHelperInstallationRechecksExternalCompletionBeforeAuthorization() async throws {
        let f = try CommandFixture(); defer { f.close() }
        var old = helperInstallationReply(); old.status?.build = TetherPaths.build - 1
        var installations = 0, readinessQueries = 0
        f.defaults.set(true, forKey: "helperUpgradePending")
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: f.controller, previewLegacyObservation: { .init(power: .ac, lidClosed: true, sleepDisabled: false) },
            previewWorkService: { _ in old }, previewHelperReply: old, previewDefaults: f.defaults,
            previewHelperInstaller: { installations += 1 },
            previewHelperReadiness: { readinessQueries += 1; return self.helperInstallationReply() }, previewHelperFiles: { [] })
        XCTAssertTrue(model.helperOutdated)
        model.installHelper(automatically: true)
        await waitForHelperInstallation { !model.helperInstallInFlight }
        XCTAssertEqual(readinessQueries, 1); XCTAssertEqual(installations, 0)
        XCTAssertFalse(model.helperOutdated); XCTAssertNil(model.errorText)
        XCTAssertNil(f.defaults.object(forKey: "helperUpgradePending"))
        XCTAssertTrue(f.controller.status.enabled, "A verified external install does not change the saved Use choice")
    }

    @MainActor
    func testAutomaticHelperInstallationQueriesAgainAfterAStaleOrUnavailablePreflight() async throws {
        for unavailable in [false, true] {
            let f = try CommandFixture(); defer { f.close() }
            var installations = 0, queries = 0
            let model = AppModel(preview: true,
                capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: f.controller, previewLegacyObservation: { .init(power: .ac, lidClosed: false, sleepDisabled: false) },
                previewDefaults: f.defaults, previewHelperInstaller: { installations += 1 },
                previewHelperReadiness: {
                    queries += 1
                    if queries == 1 {
                        if unavailable { throw ServiceFailure("unavailable") }
                        var old = self.helperInstallationReply(); old.status?.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion - 1
                        return old
                    }
                    return self.helperInstallationReply()
                }, previewHelperFiles: { [] })
            model.installHelper(automatically: true)
            await waitForHelperInstallation { !model.helperInstallInFlight }
            XCTAssertEqual(installations, 1); XCTAssertEqual(queries, 2)
            XCTAssertFalse(model.helperOutdated); XCTAssertNil(model.errorText)
        }
    }

    @MainActor
    func testHelperInstallationCancellationOrFailurePreservesPendingAndReleasesTheSlot() async throws {
        for cancelled in [true, false] {
            let f = try CommandFixture(); defer { f.close() }
            var installations = 0, queries = 0
            f.defaults.set(true, forKey: "helperUpgradePending")
            let model = AppModel(preview: true,
                capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: f.controller, previewLegacyObservation: { .init(power: .ac, lidClosed: false, sleepDisabled: false) },
                previewDefaults: f.defaults, previewHelperInstaller: {
                    installations += 1
                    if installations == 1 {
                        if cancelled { throw SystemIntegration.Failure.cancelled }
                        throw SystemIntegration.Failure.message("Injected installer failure")
                    }
                }, previewHelperReadiness: { queries += 1; return self.helperInstallationReply() }, previewHelperFiles: { [] })
            model.installHelper()
            await waitForHelperInstallation { !model.helperInstallInFlight }
            XCTAssertEqual(installations, 1); XCTAssertEqual(queries, 0)
            XCTAssertEqual(model.errorText, cancelled ? nil : "Injected installer failure")
            XCTAssertTrue(f.defaults.bool(forKey: "helperUpgradePending"))
            XCTAssertFalse(model.helperSetupConfirmed); XCTAssertFalse(model.canFinishOnboarding)
            model.finishOnboarding(); XCTAssertFalse(f.defaults.bool(forKey: "onboarded"))
            model.installHelper()
            await waitForHelperInstallation { !model.helperInstallInFlight }
            XCTAssertEqual(installations, 2); XCTAssertEqual(queries, 1)
            XCTAssertNil(model.errorText); XCTAssertNil(f.defaults.object(forKey: "helperUpgradePending"))
            XCTAssertTrue(model.helperSetupConfirmed); XCTAssertTrue(model.canFinishOnboarding)
        }
    }

    @MainActor
    func testHelperInstallationCannotReportSuccessFromAnUnverifiedPostcondition() async throws {
        let f = try CommandFixture(); defer { f.close() }
        var installations = 0
        f.defaults.set(true, forKey: "helperUpgradePending")
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: f.controller, previewLegacyObservation: { .init(power: .ac, lidClosed: false, sleepDisabled: false) },
            previewDefaults: f.defaults, previewHelperInstaller: { installations += 1 },
            previewHelperReadiness: {
                var reply = self.helperInstallationReply(); reply.status?.updatedAt = Date().addingTimeInterval(60).timeIntervalSince1970
                return reply
            }, previewHelperFiles: { [] })
        model.installHelper()
        await waitForHelperInstallation { !model.helperInstallInFlight }
        XCTAssertEqual(installations, 1); XCTAssertNotNil(model.errorText)
        XCTAssertTrue(f.defaults.bool(forKey: "helperUpgradePending"))
        XCTAssertFalse(model.helperInstalled, "A successful process exit is not a verified installation")
    }

    @MainActor
    func testPreviewHelperInstallationNeedsExplicitEffectsAndRetainsLidSafety() async throws {
        let f = try CommandFixture(); defer { f.close() }
        f.model.installHelper(); f.model.installHelper(automatically: true)
        XCTAssertFalse(f.model.helperInstallInFlight)
        for lid in [Optional(true), nil] {
            var installations = 0
            let model = AppModel(preview: true,
                capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: f.controller, previewLegacyObservation: { .init(power: .ac, lidClosed: lid, sleepDisabled: false) },
                previewDefaults: f.defaults, previewHelperInstaller: { installations += 1 },
                previewHelperReadiness: { self.helperInstallationReply() }, previewHelperFiles: { [] })
            model.installHelper()
            await waitForHelperInstallation { !model.helperInstallInFlight }
            XCTAssertEqual(installations, 0); XCTAssertNotNil(model.errorText)
        }
    }

    @MainActor
    func testHelperAuthorizationExitPreservesCancellationAndScriptFailureSemantics() {
        XCTAssertNil(SystemIntegration.helperInstallationFailure(exitStatus: 0, stderr: "nonfatal output"))
        if case .cancelled? = SystemIntegration.helperInstallationFailure(exitStatus: 1, stderr: "execution error: User canceled. (-128)\n") {} else {
            XCTFail("A canceled macOS prompt is not installation failure")
        }
        if case .message(let text)? = SystemIntegration.helperInstallationFailure(exitStatus: 1, stderr: "installer refused the request (1)\n") {
            XCTAssertEqual(text, "installer refused the request (1)")
        } else { XCTFail("An installer error must be presented") }
        if case .message(let text)? = SystemIntegration.helperInstallationFailure(exitStatus: 9, stderr: "") {
            XCTAssertFalse(text.isEmpty)
        } else { XCTFail("A nonzero empty result must not be success") }
        let arguments = SystemIntegration.helperInstallationArguments(path: "/Applications/Tether's App.app/Contents/Resources/install-helper.sh")
        XCTAssertEqual(arguments.count, 2); XCTAssertEqual(arguments.first, "-e")
        XCTAssertTrue(arguments[1].hasSuffix(" with administrator privileges"))
        XCTAssertTrue(arguments[1].contains("Tether'\\\\''s App.app"), "Shell quoting is retained inside the AppleScript argument")
    }

    @MainActor
    func testHelperInstallationWaitRejectsRemovalBeforeQuitOrAnyRemovalEffect() async throws {
        let f = try CommandFixture(); defer { f.close() }
        var waiting: CheckedContinuation<Void, Error>?
        var removalEvents: [String] = []
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: f.controller, previewLegacyObservation: { .init(power: .ac, lidClosed: false, sleepDisabled: false) },
            previewDefaults: f.defaults,
            previewHelperInstaller: { try await withCheckedThrowingContinuation { waiting = $0 } },
            previewHelperReadiness: { self.helperInstallationReply() }, previewHelperFiles: { [] })
        defer { waiting?.resume(throwing: SystemIntegration.Failure.cancelled) }
        model.startManualSession(minutes: 10)
        XCTAssertTrue(f.controller.status.holding)
        let before = f.defaults.data(forKey: UserSessionController.preferenceKey)
        let effects = AppModel.RemovalEffects(
            removeHelper: { removalEvents.append("helper") }, removeLoginItem: { removalEvents.append("login") },
            removeUserCLI: { removalEvents.append("CLI") }, recycleApp: { removalEvents.append("recycle") },
            removePreferences: { removalEvents.append("preferences") }, terminate: { removalEvents.append("terminate") })
        model.installHelper()
        await waitForHelperInstallation { waiting != nil }
        let removed = await model.uninstallEverything(using: effects)
        XCTAssertFalse(removed); XCTAssertTrue(removalEvents.isEmpty)
        XCTAssertTrue(model.acceptingUserCommands, "Removal must not even start the quit preparation")
        XCTAssertTrue(f.controller.status.holding); XCTAssertEqual(f.backend.releases, 0)
        XCTAssertEqual(f.defaults.data(forKey: UserSessionController.preferenceKey), before)
        waiting?.resume(throwing: SystemIntegration.Failure.cancelled); waiting = nil
        await waitForHelperInstallation { !model.helperInstallInFlight }
        let retried = await model.uninstallEverything(using: effects)
        XCTAssertTrue(retried)
        XCTAssertEqual(removalEvents, ["helper", "login", "CLI", "recycle", "preferences", "terminate"])
        XCTAssertFalse(f.controller.status.holding)
    }

    func testHelperAuthorizationProcessDrainsFloodedPipesWithBoundedErrorStorage() async throws {
        // Fixed nonprivileged shell fixture only: no authorization, script file,
        // helper installation, power setting, or installed app is touched.
        let waiter = HelperAuthorizationProcess(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let result = try await waiter.run(arguments: ["-c",
            "/usr/bin/yes tether-stdout | /usr/bin/head -c 131072; /usr/bin/yes tether-stderr | /usr/bin/head -c 131072 >&2"])
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(result.stderr.hasPrefix("tether-stderr"))
        XCTAssertEqual(result.stderr.utf8.count, 16_384)
    }

    func testHelperAuthorizationProcessWaitsForBothExitAndStderrEOFInEitherOrder() async throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        let eofFirst = try await HelperAuthorizationProcess(executableURL: shell)
            .run(arguments: ["-c", "printf early >&2; exec 2>&-; /bin/sleep 0.05; exit 7"])
        XCTAssertEqual(eofFirst.exitStatus, 7); XCTAssertEqual(eofFirst.stderr, "early")
        let exitFirst = try await HelperAuthorizationProcess(executableURL: shell)
            .run(arguments: ["-c", "(/bin/sleep 0.05; printf late >&2) & exit 0"])
        XCTAssertEqual(exitFirst.exitStatus, 0); XCTAssertEqual(exitFirst.stderr, "late")
    }

    @MainActor
    func testHelperAuthorizationProcessReturnsCanceledErrorAndLaunchFailureWithoutPrompting() async throws {
        // AppleScript raises the same error number without displaying a dialog.
        let canceled = try await HelperAuthorizationProcess().run(arguments: ["-e", "error number -128"])
        XCTAssertNotEqual(canceled.exitStatus, 0)
        if case .cancelled? = SystemIntegration.helperInstallationFailure(exitStatus: canceled.exitStatus, stderr: canceled.stderr) {} else {
            XCTFail("The real osascript cancellation error must preserve cancellation semantics")
        }
        let missing = URL(fileURLWithPath: "/tmp/tether-missing-authorization-executable-" + UUID().uuidString)
        do {
            _ = try await HelperAuthorizationProcess(executableURL: missing).run(arguments: [])
            XCTFail("An executable that cannot launch is not successful authorization")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    @MainActor
    private func waitForHelperInstallation(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        XCTFail("Injected helper installation did not reach its expected state", file: file, line: line)
    }

    @MainActor
    func testResumeWhileProtectionRemainsActiveReportsFailureAndPreservesUserIntent() async throws {
        let cases: [(String, PowerSource, Int?, Int?)] = [
            ("thermal", .ac, 2, nil), ("sensor", .ac, nil, nil),
            ("battery", .battery, 0, 20), ("battery", .battery, 0, 24)
        ]
        for (reason, power, thermal, battery) in cases {
            let f = try CommandFixture(power: power); defer { f.close() }
            if power == .battery {
                // Battery automation is retired. A current explicit manual
                // request must exist before battery protection can consume it.
                let manual = await f.perform(.manual(minutes: 30)); XCTAssertTrue(manual.ok)
            }
            let automatic = await f.perform(.automatic(true)); XCTAssertTrue(automatic.ok)
            // A near-floor reading alone would not latch protection. First cross
            // the floor, then demonstrate that the resume margin still applies.
            f.controller.update(power: power, thermal: thermal, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: power == .battery ? 20 : nil)
            if battery == 24 {
                f.controller.update(power: power, thermal: thermal, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: battery)
            }
            XCTAssertEqual(f.controller.status.blockReason, reason)
            XCTAssertTrue(f.model.tetherEnabled, "Protection must not rewrite the saved Use choice")
            let creates = f.backend.creates
            let before = f.defaults.data(forKey: UserSessionController.preferenceKey)
            let refused = await f.perform(.on)
            XCTAssertFalse(refused.ok)
            XCTAssertEqual(refused.error, "safetyBlocked")
            XCTAssertEqual(refused.status?.blockReason, reason)
            XCTAssertTrue(refused.status?.enabled == true)
            XCTAssertFalse(refused.status?.holding == true)
            XCTAssertEqual(f.backend.creates, creates)
            XCTAssertEqual(f.defaults.data(forKey: UserSessionController.preferenceKey), before)

            let off = await f.perform(.off)
            XCTAssertTrue(off.ok); XCTAssertFalse(off.status?.enabled == true)
            XCTAssertFalse(f.model.tetherEnabled)
            f.controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now)
            XCTAssertFalse(f.controller.status.enabled)
            XCTAssertFalse(f.controller.status.holding)
            let resumed = await f.perform(.on)
            XCTAssertTrue(resumed.ok); XCTAssertNil(resumed.status?.blockReason)
            XCTAssertTrue(resumed.status?.enabled == true)
            XCTAssertTrue(resumed.status?.holding == true)
        }
    }

    @MainActor
    func testGUIProtectionResumeShowsFailureWithoutChangingUseAndOffPersists() async throws {
        let f = try CommandFixture(); defer { f.close() }
        f.model.setTriggerEnabled(true)
        XCTAssertTrue(f.controller.status.holding)
        f.controller.update(power: .ac, thermal: 2, fullWake: true, controllingUser: true,
            now: ContinuousTime.now)
        XCTAssertTrue(f.model.tetherEnabled)
        XCTAssertEqual(f.model.protection?.blockReason, "thermal")
        XCTAssertFalse(f.controller.status.holding)
        let creates = f.backend.creates
        f.model.setEnabled(true)
        XCTAssertEqual(f.model.errorText, UserSessionFailure("safetyBlocked").localizedDescription)
        XCTAssertTrue(f.model.tetherEnabled); XCTAssertEqual(f.backend.creates, creates)

        f.model.setEnabled(false)
        XCTAssertFalse(f.model.tetherEnabled)
        XCTAssertNil(f.model.errorText)
        let saved = try JSONDecoder().decode(IdleSessionSettings.self,
            from: XCTUnwrap(f.defaults.data(forKey: UserSessionController.preferenceKey)))
        XCTAssertFalse(saved.enabled)
        f.controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now)
        XCTAssertFalse(f.model.tetherEnabled); XCTAssertFalse(f.controller.status.holding)
        f.model.setEnabled(true)
        XCTAssertTrue(f.model.tetherEnabled); XCTAssertNil(f.model.protection?.blockReason)
        XCTAssertTrue(f.controller.status.holding); XCTAssertNil(f.model.errorText)
    }

    @MainActor
    func testDesktopRejectsBatteryCommandsWithoutInterruptingGeneralWork() async throws {
        let f = try CommandFixture(); defer { f.close() }
        let automatic = await f.perform(.automatic(true)); XCTAssertTrue(automatic.ok)
        let manual = await f.perform(.manual(minutes: nil)); XCTAssertTrue(manual.ok)
        let before = f.defaults.data(forKey: UserSessionController.preferenceKey)
        XCTAssertFalse(f.model.canStartHold)
        XCTAssertEqual(f.model.availablePowerConditions, [.ac])
        XCTAssertFalse(f.model.userCommandReply(UserSessionRequest()).status?.canStartBatteryHold == true)
        let rejectedCommands: [(TetherCommand, String)] = [
            (.hold(minutes: 30), "notApplicable"), (.extendHold(minutes: 15), "notApplicable"),
            (.condition(.battery), "invalidRequest"), (.condition(.any), "invalidRequest")
        ]
        for (command, expectedError) in rejectedCommands {
            let reply = await f.perform(command)
            XCTAssertFalse(reply.ok); XCTAssertEqual(reply.error, expectedError)
            XCTAssertTrue(reply.status?.holding == true); XCTAssertTrue(reply.status?.manualActive == true)
            XCTAssertTrue(reply.status?.automaticActive == true); XCTAssertNil(reply.status?.pendingBatteryMinutes)
            XCTAssertEqual(reply.status?.powerCondition, .ac)
            XCTAssertEqual(f.defaults.data(forKey: UserSessionController.preferenceKey), before)
        }
        let unsupportedExtension = await f.perform(.extendHold(minutes: 60))
        XCTAssertEqual(unsupportedExtension.error, "invalidRequest")
        XCTAssertEqual(f.defaults.data(forKey: UserSessionController.preferenceKey), before)
        XCTAssertEqual(f.backend.creates, 1); XCTAssertEqual(f.backend.releases, 0)
    }

    @MainActor
    func testBatteryObservationIsRecheckedForCommandsAndCancellationRemainsAvailable() async throws {
        var observed = MacCapabilities(supportedPlatform: true, internalBattery: true, lid: nil)
        let f = try CommandFixture(capabilities: observed, capabilityProbe: { observed }); defer { f.close() }
        let manual = await f.perform(.manual(minutes: 10)); XCTAssertTrue(manual.ok)
        let until = f.controller.status.until
        observed = MacCapabilities(supportedPlatform: true, internalBattery: nil, lid: nil)
        let refused = await f.perform(.hold(minutes: 30))
        XCTAssertFalse(refused.ok); XCTAssertEqual(refused.error, "batteryCapabilityUnavailable")
        XCTAssertNil(f.controller.status.pendingBatteryMinutes); XCTAssertTrue(f.controller.status.holding)
        XCTAssertEqual(f.controller.status.until, until)
        f.model.startBatteryHold(minutes: 30)
        XCTAssertEqual(f.model.errorText, UserSessionFailure("batteryCapabilityUnavailable").localizedDescription)
        observed = MacCapabilities(supportedPlatform: true, internalBattery: true, lid: nil)
        _ = await f.perform(.endManual)
        _ = await f.perform(.automatic(true))
        let acReservation = await f.perform(.hold(minutes: 30))
        XCTAssertFalse(acReservation.ok); XCTAssertEqual(acReservation.error, "batteryRequired")
        XCTAssertNil(f.controller.status.pendingBatteryMinutes)
        XCTAssertFalse(f.controller.status.manualActive); XCTAssertTrue(f.controller.status.automaticActive)
        f.controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        let started = await f.perform(.hold(minutes: 30)); XCTAssertTrue(started.ok)
        XCTAssertNil(f.model.errorText, "A recovered observation must clear only its own outdated notice")
        XCTAssertTrue(f.controller.status.manualActive); XCTAssertFalse(f.controller.status.automaticActive)
        XCTAssertNil(f.controller.status.pendingBatteryMinutes)
        let batteryDeadline = try XCTUnwrap(f.controller.status.manualContinuousDeadline)
        let requestID = try XCTUnwrap(f.controller.manualRequestID)
        observed = MacCapabilities(supportedPlatform: true, internalBattery: nil, lid: nil)
        let changed = await f.perform(.extendHold(minutes: 15))
        XCTAssertEqual(changed.error, "batteryCapabilityUnavailable")
        XCTAssertEqual(f.controller.status.manualContinuousDeadline, batteryDeadline)
        XCTAssertEqual(f.controller.manualRequestID, requestID)
        XCTAssertNil(f.controller.status.pendingBatteryMinutes)
        XCTAssertFalse(f.model.canStartHold); XCTAssertFalse(f.model.canExtendHold(minutes: 15))
        let cancelled = await f.perform(.cancelHold); XCTAssertTrue(cancelled.ok)
        XCTAssertNil(f.controller.status.pendingBatteryMinutes); XCTAssertNil(f.controller.status.until)
        XCTAssertFalse(f.controller.status.manualActive); XCTAssertFalse(f.controller.status.automaticActive)
        XCTAssertFalse(f.controller.status.holding)
        f.controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now)
        XCTAssertTrue(f.controller.status.automaticActive); XCTAssertFalse(f.controller.status.manualActive)
        XCTAssertTrue(f.controller.status.holding)
        XCTAssertEqual(f.backend.creates, 4); XCTAssertEqual(f.backend.releases, 3)
    }

    @MainActor
    func testUnsupportedGUIAndURLBatteryEditsPreserveImportedSettingsAndExplicitOff() async throws {
        for battery: Bool? in [false, nil] {
            var settings = IdleSessionSettings(); settings.enabled = false
            settings.automaticEnabled = true; settings.powerCondition = .battery; settings.automaticHoldMinutes = 45
            settings.legacyRootConfigurationPending = false
            let f = try CommandFixture(capabilities: .init(supportedPlatform: true, internalBattery: battery, lid: false), settings: settings)
            defer { f.close() }
            let before = f.defaults.data(forKey: UserSessionController.preferenceKey)
            f.model.setPowerCondition(.any); f.model.setAutomaticMinutes(120); f.model.startBatteryHold(minutes: 30)
            for text in ["tether://hold?minutes=30", "tether://condition/any", "tether://condition/battery"] {
                let url = try XCTUnwrap(URL(string: text))
                if url.host == "hold" { XCTAssertEqual(TetherCommand.parse(url: url), .hold(minutes: 30)) }
                else { XCTAssertNil(TetherCommand.parse(url: url), "Non-AC automatic conditions are retired at the URL parser") }
                f.model.handle(url: url)
            }
            XCTAssertEqual(f.controller.status.powerCondition, .ac)
            XCTAssertEqual(f.controller.settings.powerCondition, .battery, "Retain the old saved value as migration evidence only")
            XCTAssertFalse(f.controller.status.automaticEnabled)
            XCTAssertEqual(f.controller.status.automaticMinutes, 45); XCTAssertFalse(f.controller.status.enabled)
            XCTAssertNil(f.controller.status.pendingBatteryMinutes)
            XCTAssertEqual(f.defaults.data(forKey: UserSessionController.preferenceKey), before)
            XCTAssertEqual(f.backend.creates, 0); XCTAssertEqual(f.backend.releases, 0)
            let corrected = await f.perform(.condition(.ac))
            XCTAssertTrue(corrected.ok); XCTAssertEqual(corrected.status?.powerCondition, .ac)
            XCTAssertFalse(corrected.status?.enabled == true); XCTAssertFalse(corrected.status?.holding == true)
        }
    }

    @MainActor
    func testDesktopManualAndAutomaticCommandsUseOneRequestAndKeepTheirReasonsIndependent() async throws {
        let f = try CommandFixture(); defer { f.close() }
        let initial = await f.perform(.status)
        XCTAssertTrue(initial.ok); XCTAssertEqual(initial.lidSupport, .notRequired)
        XCTAssertNil(initial.lidClosed); XCTAssertNil(initial.helperConnected)
        let automatic = await f.perform(.automatic(true)); XCTAssertTrue(automatic.ok)
        XCTAssertTrue(automatic.status?.automaticActive == true)
        let manual = await f.perform(.manual(minutes: nil)); XCTAssertTrue(manual.ok)
        XCTAssertTrue(manual.status?.manualActive == true); XCTAssertNil(manual.status?.until)
        let ended = await f.perform(.endManual); XCTAssertTrue(ended.ok)
        XCTAssertFalse(ended.status?.manualActive == true); XCTAssertTrue(ended.status?.holding == true)
        let stopped = await f.perform(.automatic(false)); XCTAssertTrue(stopped.ok)
        XCTAssertFalse(stopped.status?.holding == true)
        XCTAssertEqual(f.backend.creates, 1); XCTAssertEqual(f.backend.releases, 1)
    }
    @MainActor
    func testBatteryManualAndLegacyHoldAliasUseOneBoundedTwoHourRequest() async throws {
        let f = try CommandFixture(power: .battery); defer { f.close() }
        let unlimited = await f.perform(.manual(minutes: nil))
        XCTAssertFalse(unlimited.ok); XCTAssertEqual(unlimited.error, "acRequired"); XCTAssertEqual(f.backend.creates, 0)
        let tooLong = await f.perform(.manual(minutes: 240)); XCTAssertFalse(tooLong.ok)
        XCTAssertFalse(f.controller.status.manualActive)
        let manual = await f.perform(.manual(minutes: 120)); XCTAssertTrue(manual.ok)
        XCTAssertEqual(try XCTUnwrap(manual.status?.until).timeIntervalSinceNow, 7200, accuracy: 2)
        let tooLongHold = await f.perform(.hold(minutes: 240)); XCTAssertEqual(tooLongHold.error, "invalidRequest")
        let overlapping = await f.perform(.hold(minutes: 120)); XCTAssertFalse(overlapping.ok)
        XCTAssertEqual(overlapping.status?.until, manual.status?.until)
        let manualEnd = await f.perform(.endManual)
        XCTAssertFalse(manualEnd.status?.manualActive == true); XCTAssertFalse(manualEnd.status?.holding == true)
        let reservation = await f.perform(.hold(minutes: 120)); XCTAssertTrue(reservation.ok)
        XCTAssertTrue(reservation.status?.manualActive == true)
        XCTAssertEqual(try XCTUnwrap(reservation.status?.until).timeIntervalSinceNow, 7200, accuracy: 2)
        let allEnd = await f.perform(.cancelHold); XCTAssertFalse(allEnd.status?.holding == true)
    }
    @MainActor
    func testRejectedExtensionsAndRepeatedToggleNeverRepeatEffects() async throws {
        let f = try CommandFixture(); defer { f.close() }
        let start = await f.perform(.manual(minutes: 60)); XCTAssertTrue(start.ok)
        let extensionRequest = f.request(.extendManual(minutes: 60))
        let once = await f.model.handleUserCommand(extensionRequest, peer: f.peer)
        let until = try XCTUnwrap(once.status?.until), renews = f.backend.renews
        let twice = await f.model.handleUserCommand(extensionRequest, peer: f.peer)
        XCTAssertFalse(once.ok); XCTAssertEqual(once.error, "invalidRequest")
        XCTAssertFalse(twice.ok); XCTAssertEqual(twice.error, "invalidRequest")
        XCTAssertEqual(twice.status?.until, until)
        XCTAssertEqual(twice.revision, once.revision); XCTAssertEqual(f.backend.renews, renews)
        let originalRequestID = try XCTUnwrap(f.controller.manualRequestID)
        var previousDeadline = try XCTUnwrap(f.controller.status.manualContinuousDeadline)
        for minutes in [15, 30] {
            let request = f.request(.extendManual(minutes: minutes))
            let extended = await f.model.handleUserCommand(request, peer: f.peer)
            XCTAssertTrue(extended.ok); XCTAssertNil(extended.error)
            let currentDeadline = try XCTUnwrap(extended.status?.manualContinuousDeadline)
            let extensionID = try XCTUnwrap(extended.status?.manualExtensionID)
            XCTAssertEqual(currentDeadline, previousDeadline + Double(minutes * 60), accuracy: 0.001)
            XCTAssertEqual(extended.status?.manualRequestID, originalRequestID)
            let renewed = f.backend.renews
            let repeated = await f.model.handleUserCommand(request, peer: f.peer)
            XCTAssertTrue(repeated.ok); XCTAssertEqual(repeated.replayed, true)
            XCTAssertEqual(repeated.status?.manualContinuousDeadline, currentDeadline)
            XCTAssertEqual(repeated.status?.manualExtensionID, extensionID)
            XCTAssertEqual(repeated.revision, extended.revision); XCTAssertEqual(f.backend.renews, renewed)
            XCTAssertEqual(f.backend.creates, 1)
            previousDeadline = currentDeadline
        }
        let toggle = f.request(.toggle)
        let off = await f.model.handleUserCommand(toggle, peer: f.peer)
        let replay = await f.model.handleUserCommand(toggle, peer: f.peer)
        XCTAssertFalse(off.status?.enabled == true); XCTAssertFalse(replay.status?.enabled == true)
        XCTAssertEqual(f.backend.releases, 1); XCTAssertEqual(f.backend.creates, 1)
    }
    @MainActor
    func testGUIChangeInvalidatesAnOlderCLIRevisionWithoutRunningIt() async throws {
        let f = try CommandFixture(); defer { f.close() }
        let old = f.request(.manual(minutes: 60))
        f.model.setEnabled(false)
        let reply = await f.model.handleUserCommand(old, peer: f.peer)
        XCTAssertFalse(reply.ok); XCTAssertEqual(reply.error, "staleRevision")
        XCTAssertFalse(f.controller.status.manualActive); XCTAssertEqual(f.backend.creates, 0)
    }
    @MainActor
    func testForeignGUIAndUnverifiedProcessCannotChangeTheAppState() async throws {
        let f = try CommandFixture(); defer { f.close() }
        var peer = f.peer; peer.login = GUISessionIdentity(uid: getuid(), sessionID: 100002)
        let different = await f.model.handleUserCommand(f.request(.manual(minutes: 60)), peer: peer)
        XCTAssertEqual(different.error, "guiSessionUnavailable")
        peer = f.peer; peer.process.started += 1
        let reused = await f.model.handleUserCommand(f.request(.manual(minutes: 60)), peer: peer)
        XCTAssertEqual(reused.error, "unauthorized"); XCTAssertEqual(f.backend.creates, 0)
        f.model.userCommandCompanion = "/not/the/companion"
        let unexpected = await f.perform(.status); XCTAssertEqual(unexpected.error, "unauthorized")
    }
    @MainActor
    func testFailedNativeReleaseIsNeverReportedAsASuccessfulOffCommand() async throws {
        let f = try CommandFixture(); defer { f.close() }
        let start = await f.perform(.manual(minutes: nil)); XCTAssertTrue(start.ok)
        f.backend.releaseCode = 5
        let off = await f.perform(.off)
        XCTAssertFalse(off.ok); XCTAssertEqual(off.error, "requestVerificationFailed")
        XCTAssertNotNil(off.status?.error); XCTAssertFalse(off.status?.enabled == true)
    }
    @MainActor
    func testExpiredNativeLeaseIsNotReportedAsHoldingBeforeTheNextPollingTick() throws {
        let f = try CommandFixture(); defer { f.close() }
        let past = ContinuousTime.now - 95
        _ = f.controller.start(duration: 60, now: past)
        XCTAssertFalse(f.controller.status.holding)
        XCTAssertFalse(f.model.userCommandReply(UserSessionRequest()).status?.holding == true)
        XCTAssertEqual(f.controller.workLease()?.reasons, [])
    }
    @MainActor
    func testInvalidAndExpiredRequestsAndPreviewSleepDoNotChangePower() async throws {
        let f = try CommandFixture(); defer { f.close() }
        var expired = f.request(.manual(minutes: 60)); expired.deadline = ContinuousTime.now - 1
        let reply = await f.model.handleUserCommand(expired, peer: f.peer)
        XCTAssertEqual(reply.error, "invalidRequest"); XCTAssertEqual(f.backend.creates, 0)
        let sleep = await f.perform(.sleep)
        XCTAssertEqual(sleep.error, "sleepUnavailable"); XCTAssertEqual(f.backend.creates, 0)
        let invalid = await f.perform(.manual(minutes: -1)); XCTAssertEqual(invalid.error, "invalidRequest")
        var newer = f.request(.manual(minutes: nil)); newer.build += 1
        let mismatch = await f.model.handleUserCommand(newer, peer: f.peer)
        XCTAssertEqual(mismatch.error, "unsupportedVersion"); XCTAssertEqual(f.backend.creates, 0)
    }

    @MainActor
    func testPendingSleepIsSupersededByANewerGUIOrURLManualStart() async throws {
        for viaURL in [false, true] {
            var settled = false, checks = 0, effects = 0
            let f = try CommandFixture(sleepExecutor: { effects += 1; return true },
                sleepSettled: { checks += 1; return settled })
            defer { f.close() }
            let pending = Task { await f.perform(.sleep) }
            let waitUntil = ContinuousTime.now + 1
            while checks == 0, ContinuousTime.now < waitUntil { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertGreaterThan(checks, 0, "The sleep request must be waiting before the newer command")
            // A stopped session requires an explicit Resume; starting work or
            // toggling automatic alone cannot clear the saved sleep boundary.
            f.model.setEnabled(true)
            if viaURL { f.model.handle(url: try XCTUnwrap(URL(string: "tether://manual/10m"))) }
            else { f.model.startManualSession(minutes: 10) }
            XCTAssertTrue(f.controller.status.manualActive); XCTAssertTrue(f.controller.status.holding)
            settled = true
            let reply = await pending.value
            XCTAssertFalse(reply.ok); XCTAssertEqual(reply.error, "superseded")
            XCTAssertEqual(effects, 0, "An old pending sleep must not reach its OS executor")
            XCTAssertTrue(f.controller.status.manualActive); XCTAssertTrue(f.controller.status.holding)
        }
    }

    @MainActor
    func testPendingSleepRechecksCurrentGUIAuthorityBeforeItsEffect() async throws {
        let login = GUISessionIdentity(uid: getuid(), sessionID: 100001)
        for unavailable in [false, true] {
            var owner = GUISessionObservation(login: login, consoleUID: getuid())
            var settled = false, checks = 0, effects = 0
            let f = try CommandFixture(sleepExecutor: { effects += 1; return true },
                sleepSettled: { checks += 1; return settled }, sleepAuthority: { owner })
            defer { f.close() }
            let pending = Task { await f.perform(.sleep) }
            let waitUntil = ContinuousTime.now + 1
            while checks == 0, ContinuousTime.now < waitUntil { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertGreaterThan(checks, 0)
            owner = unavailable ? GUISessionObservation(login: nil, consoleUID: nil)
                : GUISessionObservation(login: GUISessionIdentity(uid: login.uid, sessionID: 100002), consoleUID: login.uid)
            settled = true
            let reply = await pending.value
            XCTAssertFalse(reply.ok); XCTAssertEqual(reply.error, "guiSessionUnavailable")
            XCTAssertEqual(effects, 0, "A former or unobserved GUI owner cannot execute a delayed system sleep")
        }
    }

    @MainActor
    func testPendingSleepSurvivesPowerChangesAndARejectedNewStart() async throws {
        var settled = false, checks = 0, effects = 0
        let f = try CommandFixture(sleepExecutor: { effects += 1; return true },
            sleepSettled: { checks += 1; return settled })
        defer { f.close() }
        let pending = Task { await f.perform(.sleep) }
        let waitUntil = ContinuousTime.now + 1
        while checks == 0, ContinuousTime.now < waitUntil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertGreaterThan(checks, 0)
        f.controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        f.model.startManualSession(minutes: 0)
        XCTAssertFalse(f.controller.status.manualActive)
        settled = true
        let reply = await pending.value
        XCTAssertTrue(reply.ok); XCTAssertNil(reply.error); XCTAssertEqual(effects, 1)
    }

    @MainActor
    func testPendingSleepExpiresWithoutReachingItsEffect() async throws {
        var checks = 0, effects = 0
        let f = try CommandFixture(sleepExecutor: { effects += 1; return true },
            sleepSettled: { checks += 1; return false })
        defer { f.close() }
        var request = f.request(.sleep); request.deadline = ContinuousTime.now + 0.15
        let reply = await f.model.handleUserCommand(request, peer: f.peer)
        XCTAssertGreaterThan(checks, 0)
        XCTAssertFalse(reply.ok); XCTAssertEqual(reply.error, "expired"); XCTAssertEqual(effects, 0)
    }

    @MainActor
    func testPendingSleepIsSupersededByANewerBatteryReservation() async throws {
        var settled = false, checks = 0, effects = 0
        let f = try CommandFixture(power: .battery, sleepExecutor: { effects += 1; return true },
            sleepSettled: { checks += 1; return settled })
        defer { f.close() }
        let pending = Task { await f.perform(.sleep) }
        let waitUntil = ContinuousTime.now + 1
        while checks == 0, ContinuousTime.now < waitUntil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertGreaterThan(checks, 0)
        f.model.setEnabled(true)
        f.model.startBatteryHold(minutes: 10)
        XCTAssertNotNil(f.controller.status.until)
        XCTAssertTrue(f.controller.status.holding)
        settled = true
        let reply = await pending.value
        XCTAssertFalse(reply.ok); XCTAssertEqual(reply.error, "superseded"); XCTAssertEqual(effects, 0)
        XCTAssertNotNil(f.controller.status.until)
    }

    @MainActor
    func testGUISleepUsesTheSamePendingIntentAndNeverRunsAfterANewerResume() async throws {
        var settled = false, checks = 0, effects = 0
        let f = try CommandFixture(sleepExecutor: { effects += 1; return true },
            sleepSettled: { checks += 1; return settled })
        defer { f.close() }
        f.model.setTriggerEnabled(true)
        XCTAssertTrue(f.controller.status.holding)
        f.model.sleepNow()
        let waitUntil = ContinuousTime.now + 1
        while checks == 0, ContinuousTime.now < waitUntil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertGreaterThan(checks, 0); XCTAssertFalse(f.controller.status.holding)
        f.model.setEnabled(true)
        XCTAssertTrue(f.controller.status.holding)
        settled = true
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(effects, 0); XCTAssertTrue(f.controller.status.holding)
        XCTAssertNil(f.model.errorText)
    }

    @MainActor
    func testGUISleepWithoutAnExplicitPreviewExecutorRemainsUnavailable() throws {
        let f = try CommandFixture(); defer { f.close() }
        f.model.sleepNow()
        XCTAssertEqual(f.model.errorText, UserSessionFailure("sleepUnavailable").localizedDescription)
        XCTAssertFalse(f.controller.status.manualActive); XCTAssertEqual(f.backend.creates, 0)
    }

    @MainActor
    func testGUISleepIsSupersededBeforeItsTaskStarts() async throws {
        var effects = 0
        let f = try CommandFixture(sleepExecutor: { effects += 1; return true }, sleepSettled: { true })
        defer { f.close() }
        f.model.sleepNow()
        f.model.setEnabled(true)
        f.model.startManualSession(minutes: 10)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(effects, 0); XCTAssertTrue(f.controller.status.manualActive)
        XCTAssertTrue(f.controller.status.holding); XCTAssertNil(f.model.errorText)
    }

    @MainActor
    func testAcceptedSleepEffectIsNotReportedAsRetractedByANewerStart() async throws {
        var effects = 0
        var completion: CheckedContinuation<Bool, Never>?
        let f = try CommandFixture(sleepExecutor: {
            effects += 1
            return await withCheckedContinuation { completion = $0 }
        }, sleepSettled: { true })
        defer { f.close() }
        let pending = Task { await f.perform(.sleep) }
        let waitUntil = ContinuousTime.now + 1
        while completion == nil, ContinuousTime.now < waitUntil { try await Task.sleep(nanoseconds: 1_000_000) }
        guard let completion else {
            pending.cancel()
            XCTFail("The harmless sleep executor did not receive this request")
            _ = await pending.value
            return
        }
        XCTAssertEqual(effects, 1)
        f.model.startManualSession(minutes: 10)
        completion.resume(returning: true)
        let reply = await pending.value
        // This fixture acknowledges only request acceptance. It proves no physical
        // Sleep or cancellation of an effect that the OS has already accepted.
        XCTAssertTrue(reply.ok); XCTAssertNil(reply.error); XCTAssertEqual(effects, 1)
    }

    @MainActor
    func testRejectedURLManualExtensionPreservesDeadlineAndPendingIntent() async throws {
        var settled = false, checks = 0, effects = 0
        let f = try CommandFixture(sleepExecutor: { effects += 1; return true },
            sleepSettled: { checks += 1; return settled })
        defer { f.close() }
        f.model.startManualSession(minutes: 10)
        let before = try XCTUnwrap(f.controller.status.until)
        // Exercise the intent layer independently while a valid timer is present.
        let intent = try f.model.beginExplicitSleep(deadline: ContinuousTime.now + 3)
        let pending = Task { await f.model.executeExplicitSleep(intent) }
        let waitUntil = ContinuousTime.now + 1
        while checks == 0, ContinuousTime.now < waitUntil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertGreaterThan(checks, 0)
        f.model.handle(url: try XCTUnwrap(URL(string: "tether://manual/+5m")))
        XCTAssertEqual(try XCTUnwrap(f.controller.status.until), before)
        settled = true
        let result = await pending.value
        XCTAssertNil(result); XCTAssertEqual(effects, 1)
    }

    @MainActor
    func testQueuedSleepRechecksIntentDeadlineAndGUIBeforeSendingTheRPC() async throws {
        for scenario in ["newWork", "deadline", "newGUI", "unavailable", "quit", "writerAuthority", "valid"] {
            let f = try CommandFixture(sleepExecutor: { true }); defer { f.close() }
            let coordinatorPath = f.folder.appendingPathComponent("instance.lock").path
            let model = scenario == "writerAuthority" ? AppModel(preview: true,
                capabilities: MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false),
                previewSession: f.controller, previewDefaults: f.defaults, previewCoordinatorPath: coordinatorPath,
                previewSleepExecutor: { true }) : f.model
            if scenario == "writerAuthority" { model.userCommandOwnerProbe = { [owner = f.owner] in owner } }
            let observed = QueuedSleepObservation(f.owner)
            let service = LocalService(path: f.socket)
            try service.start { request, _ in
                if request.action == .sleep { observed.recordSleep() }
                return ServiceReply(id: request.id, ok: true, epoch: "queued-sleep-fixture", revision: 1, control: Control())
            }
            defer { service.stop() }
            let connection = ServiceConnection(path: f.socket)
            let releaseQueue = DispatchSemaphore(value: 0)
            defer { releaseQueue.signal() }
            // Hold the real serial transport actor before the sleep RPC can enter.
            // Returning false prevents this queue holder from sending any request.
            let holder = Task {
                try? await connection.write {
                    observed.markQueueHeld(); releaseQueue.wait(); return false
                }
            }
            let waitUntil = ContinuousTime.now + 1
            while !observed.queueHeld, ContinuousTime.now < waitUntil { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(observed.queueHeld)
            let intent = try model.beginExplicitSleep(deadline: ContinuousTime.now + (scenario == "deadline" ? 0.15 : 3))
            let preflight = model.queuedExplicitSleepPreflight(intent, observation: { observed.observation() })
            let pending = Task { () -> String? in
                do { _ = try await connection.perform(ServiceRequest(.sleep), preflight: preflight); return nil }
                catch let failure as UserSessionFailure { return failure.code }
                catch { return "unexpected: " + error.localizedDescription }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            XCTAssertEqual(observed.sleepRequests, 0)
            switch scenario {
            case "newWork": f.model.startManualSession(minutes: 10)
            case "deadline": try await Task.sleep(nanoseconds: 200_000_000)
            case "newGUI": observed.setObservation(GUISessionObservation(login: .init(uid: getuid(), sessionID: 100002), consoleUID: getuid()))
            case "unavailable": observed.setObservation(GUISessionObservation(login: nil, consoleUID: nil))
            case "quit":
                let quitAccepted = await model.prepareToQuit(); XCTAssertTrue(quitAccepted)
            case "writerAuthority":
                // Only the isolated fixture's lock is changed; no installed app
                // or power setting is touched. Fresh lease validation must fail.
                XCTAssertEqual(chmod(coordinatorPath, 0o644), 0)
                XCTAssertFalse(model.hasCoordinatorAuthority)
            default: break
            }
            releaseQueue.signal()
            _ = await holder.value
            let result = await pending.value
            let expected = scenario == "newWork" || scenario == "quit" ? "superseded"
                : scenario == "deadline" ? "expired" : scenario == "writerAuthority" ? "coordinatorUnavailable"
                : scenario == "valid" ? nil : "guiSessionUnavailable"
            XCTAssertEqual(result, expected, scenario)
            XCTAssertEqual(observed.sleepRequests, scenario == "valid" ? 1 : 0, scenario)
        }
    }
    @MainActor
    func testAnOlderAsynchronousResumeCannotUndoALaterOffCommand() async throws {
        let f = try CommandFixture(); defer { f.close() }
        var resume: CheckedContinuation<ServiceReply, Error>?
        var gate = WorkSessionLeaseGate()
        var preparation: WorkSessionPreparation?
        func reply(id: UUID, reason: String? = nil) -> ServiceReply {
            var status = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
                enabled: true, power: .ac, lidClosed: false, sleepDisabled: false, lastEvent: nil, lastEventAt: nil, thermal: 0)
            status.build = TetherPaths.build; status.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
            status.appConnected = true; status.appPID = getpid(); status.ownsOverride = false
            status.displayTopology = DisplayTopology.none
            var result = ServiceReply(id: id, ok: true, epoch: "resume-fixture", revision: 1, control: Control(),
                protection: .init(reason: reason, error: nil, dryRun: true))
            result.status = status
            result.workSessionBridge = WorkSessionBridge(coordinated: true, automaticBudget: ProtectionState(), manualBudget: nil)
            result.workSessionPreparation = preparation
            return result
        }
        let model = AppModel(preview: true,
            capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: f.controller, previewWorkService: { request in
                if request.action == .resume {
                    return try await withCheckedThrowingContinuation { resume = $0 }
                }
                if request.action == .prepareWorkSession, let lease = request.workSession {
                    preparation = WorkSessionPreparation(sessionID: lease.sessionID, epoch: "resume-fixture",
                        revision: 1, expiresAt: ContinuousTime.now + IdleSessionPolicy.healthTTL)
                } else if let lease = request.workSession {
                    XCTAssertTrue(gate.accept(lease, now: ContinuousTime.now, attaching: request.action == .attachWorkSession))
                }
                return reply(id: request.id, reason: "displayConflict")
            }, previewHelperReply: reply(id: UUID(), reason: "displayConflict"))
        model.userCommandCompanion = f.peer.process.executable; model.userCommandOwnerProbe = { f.owner }
        for _ in 0..<1000 { if !model.lidCommandPending { break }; await Task.yield() }
        let state = model.userCommandReply(UserSessionRequest())
        let request = UserSessionRequest(.on, epoch: state.epoch, revision: state.revision)
        let pending = Task { await model.handleUserCommand(request, peer: f.peer) }
        for _ in 0..<1000 { if resume != nil { break }; await Task.yield() }
        XCTAssertNotNil(resume)
        model.setEnabled(false)
        resume?.resume(returning: reply(id: UUID())); resume = nil
        let result = await pending.value
        XCTAssertFalse(result.ok); XCTAssertEqual(result.error, "superseded")
        XCTAssertFalse(f.controller.status.enabled); XCTAssertFalse(f.controller.status.holding)
        XCTAssertEqual(f.backend.creates, 0)
        // The next resume has no later GUI action, but its original lifetime ends
        // while awaiting the helper. A late acknowledgement still cannot enable it.
        f.controller.setPowerCondition(.battery)
        for _ in 0..<1000 { if !model.lidCommandPending { break }; await Task.yield() }
        XCTAssertEqual(model.coordinatedLidBlockReason, "displayConflict", "Prepare a protected resume, not an immediate on command")
        let next = model.userCommandReply(UserSessionRequest())
        var expiring = UserSessionRequest(.on, epoch: next.epoch, revision: next.revision)
        expiring.deadline = ContinuousTime.now + 0.05
        let expiredPending = Task { await model.handleUserCommand(expiring, peer: f.peer) }
        for _ in 0..<1000 { if resume != nil { break }; await Task.yield() }
        XCTAssertNotNil(resume)
        try await Task.sleep(nanoseconds: 100_000_000)
        resume?.resume(returning: reply(id: UUID())); resume = nil
        let expired = await expiredPending.value
        XCTAssertFalse(expired.ok); XCTAssertEqual(expired.error, "expired")
        XCTAssertFalse(f.controller.status.enabled); XCTAssertFalse(f.controller.status.holding)
        XCTAssertEqual(f.backend.creates, 0)
    }
    @MainActor
    func testPreviewRequiresAnExplicitPrivateEndpointBeforeItStartsACommandServer() throws {
        let f = try CommandFixture(); defer { f.close() }
        f.model.startUserCommandService()
        XCTAssertNil(f.model.userCommandService)
    }
    @MainActor
    func testActualCLICommandsReachTheCommonPolicyAndReportIndependentStateAsJSON() async throws {
        // A portable capability fixture is distinct from the real host hardware.
        let f = try CommandFixture(capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true)); defer { f.close() }
        let executable = try cliExecutable()
        // The child inherits this test process's real graphical login. Keep the
        // fixture console observation, but do not compare it to an invented ID.
        let observedOwner = GUISessionObservation(login: GUISessionProbe.caller() ?? f.owner.login, consoleUID: getuid())
        f.model.startUserCommandService(path: f.socket, expectedCompanion: executable, ownerProbe: { observedOwner })
        XCTAssertNotNil(f.model.userCommandService)
        let status = try await cli(["status", "--json"], fixture: f, executable: executable)
        XCTAssertEqual(status.code, 0, status.error)
        let before = try json(status.output)
        XCTAssertEqual(before["commonSessionAvailable"] as? Bool, true)
        let receipt = try XCTUnwrap(before["receipt"] as? [String: Any])
        XCTAssertEqual(receipt["lidSupport"] as? String, "unavailable")
        let start = try await cli(["manual", "unlimited", "--json"], fixture: f, executable: executable)
        XCTAssertEqual(start.code, 0, start.error); XCTAssertTrue(f.controller.status.manualActive); XCTAssertNil(f.controller.status.until)
        let automatic = try await cli(["auto", "on", "--json"], fixture: f, executable: executable)
        XCTAssertEqual(automatic.code, 0, automatic.error); XCTAssertTrue(f.controller.status.automaticActive)
        let end = try await cli(["manual", "off", "--json"], fixture: f, executable: executable)
        XCTAssertEqual(end.code, 0, end.error); XCTAssertFalse(f.controller.status.manualActive); XCTAssertTrue(f.controller.status.holding)
        for retired in ["battery", "any"] {
            let condition = try await cli(["condition", retired, "--json"], fixture: f, executable: executable)
            XCTAssertEqual(condition.code, 2, condition.error)
            XCTAssertEqual(f.controller.status.powerCondition, .ac)
            XCTAssertTrue(f.controller.status.automaticActive); XCTAssertTrue(f.controller.status.holding)
            XCTAssertEqual(f.backend.releases, 0)
        }
        let condition = try await cli(["condition", "ac", "--json"], fixture: f, executable: executable)
        XCTAssertEqual(condition.code, 0, condition.error); XCTAssertEqual(f.controller.status.powerCondition, .ac)
        let reservation = try await cli(["hold", "30m", "--json"], fixture: f, executable: executable)
        XCTAssertEqual(reservation.code, 1, reservation.error); XCTAssertTrue(reservation.error.contains("batteryRequired"))
        XCTAssertNil(f.controller.status.pendingBatteryMinutes)
        XCTAssertFalse(f.controller.status.manualActive); XCTAssertTrue(f.controller.status.automaticActive)
        f.controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        let battery = try await cli(["hold", "30m", "--json"], fixture: f, executable: executable)
        XCTAssertEqual(battery.code, 0, battery.error)
        XCTAssertTrue(f.controller.status.manualActive); XCTAssertFalse(f.controller.status.automaticActive)
        XCTAssertNil(f.controller.status.pendingBatteryMinutes)
        var manualDeadline = try XCTUnwrap(f.controller.status.manualContinuousDeadline)
        XCTAssertEqual(try XCTUnwrap(f.controller.status.until).timeIntervalSinceNow, 1800, accuracy: 3)
        for (command, minutes) in [("manual", 15), ("hold", 30)] {
            let extended = try await cli([command, "+\(minutes)m", "--json"], fixture: f, executable: executable)
            XCTAssertEqual(extended.code, 0, extended.error)
            let deadline = try XCTUnwrap(f.controller.status.manualContinuousDeadline)
            XCTAssertEqual(deadline, manualDeadline + Double(minutes * 60), accuracy: 0.001)
            manualDeadline = deadline
        }
        let retiredExtension = try await cli(["manual", "+1h", "--json"], fixture: f, executable: executable)
        XCTAssertEqual(retiredExtension.code, 2)
        XCTAssertEqual(f.controller.status.manualContinuousDeadline, manualDeadline)
        let off = try await cli(["off", "--json"], fixture: f, executable: executable)
        XCTAssertEqual(off.code, 0, off.error); XCTAssertFalse(f.controller.status.enabled); XCTAssertNil(f.controller.status.pendingBatteryMinutes)
        let paused = try await cli(["manual", "25h"], fixture: f, executable: executable)
        XCTAssertEqual(paused.code, 1); XCTAssertFalse(f.controller.status.manualActive)
        f.controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now)
        let resumed = try await cli(["on"], fixture: f, executable: executable)
        XCTAssertEqual(resumed.code, 0)
        let longAC = try await cli(["manual", "25h"], fixture: f, executable: executable)
        XCTAssertEqual(longAC.code, 0, longAC.error)
        XCTAssertEqual(try XCTUnwrap(f.controller.status.until).timeIntervalSinceNow, 25 * 3600, accuracy: 3)
        _ = try await cli(["off"], fixture: f, executable: executable)
        let flags = try await cli(["on", "--unexpected"], fixture: f, executable: executable)
        XCTAssertEqual(flags.code, 2); XCTAssertFalse(f.controller.status.enabled)
        let sleep = try await cli(["sleep"], fixture: f, executable: executable)
        XCTAssertEqual(sleep.code, 1); XCTAssertFalse(f.controller.status.enabled)
    }
    @MainActor
    func testActualCLIRejectsDesktopBatteryActionsAndKeepsTheManualRequest() async throws {
        let f = try CommandFixture(); defer { f.close() }
        let executable = try cliExecutable()
        let observedOwner = GUISessionObservation(login: GUISessionProbe.caller() ?? f.owner.login, consoleUID: getuid())
        f.model.startUserCommandService(path: f.socket, expectedCompanion: executable, ownerProbe: { observedOwner })
        let started = try await cli(["manual", "unlimited", "--json"], fixture: f, executable: executable)
        XCTAssertEqual(started.code, 0, started.error)
        let before = f.defaults.data(forKey: UserSessionController.preferenceKey)
        let removedExtension = try await cli(["hold", "+1h", "--json"], fixture: f, executable: executable)
        XCTAssertEqual(removedExtension.code, 2)
        XCTAssertEqual(f.defaults.data(forKey: UserSessionController.preferenceKey), before)
        let rejected: [([String], Int32)] = [
            (["hold", "30m"], 1), (["hold", "+15m"], 1),
            (["condition", "battery"], 2), (["condition", "any"], 2)
        ]
        for (arguments, expectedExit) in rejected {
            let result = try await cli(arguments + ["--json"], fixture: f, executable: executable)
            XCTAssertEqual(result.code, expectedExit, result.error)
            // Rejected commands use stderr even with --json. Re-read the actual
            // command socket to verify the post-failure state separately.
            XCTAssertTrue(result.output.isEmpty)
            if expectedExit == 1 {
                XCTAssertTrue(result.error.contains("internal battery") || result.error.contains("내장 배터리"), result.error)
            } else { XCTAssertTrue(result.error.contains("condition"), result.error) }
            let current = try await cli(["status", "--json"], fixture: f, executable: executable)
            XCTAssertEqual(current.code, 0, current.error)
            let receipt = try XCTUnwrap(try json(current.output)["receipt"] as? [String: Any])
            XCTAssertEqual(receipt["lidSupport"] as? String, "notRequired")
            let status = try XCTUnwrap(receipt["status"] as? [String: Any])
            XCTAssertEqual(status["canStartBatteryHold"] as? Bool, false)
            XCTAssertEqual(status["holding"] as? Bool, true)
            XCTAssertEqual(f.defaults.data(forKey: UserSessionController.preferenceKey), before)
        }
        XCTAssertEqual(f.controller.status.powerCondition, .ac); XCTAssertNil(f.controller.status.pendingBatteryMinutes)
        XCTAssertEqual(f.backend.creates, 1); XCTAssertEqual(f.backend.releases, 0)
    }
    @MainActor
    func testActualCLIWithoutACommandServerFailsWithoutCreatingASession() async throws {
        let f = try CommandFixture(); defer { f.close() }
        let result = try await cli(["manual", "unlimited"], fixture: f, executable: try cliExecutable())
        XCTAssertEqual(result.code, 1); XCTAssertFalse(result.error.isEmpty)
        XCTAssertFalse(f.controller.status.manualActive); XCTAssertEqual(f.backend.creates, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.socket))
    }
    private func cliExecutable() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = ProcessInfo.processInfo.environment["TETHER_TEST_CLI_EXECUTABLE"] ?? root.appendingPathComponent(".build/debug/TetherCLI").path
        guard FileManager.default.isExecutableFile(atPath: path) else { throw NSError(domain: "MissingBuiltCLI", code: 1) }
        return path
    }
    private func json(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
    @MainActor
    private func cli(_ arguments: [String], fixture: CommandFixture, executable: String) async throws -> (code: Int32, output: String, error: String) {
        let socket = fixture.socket
        let serverExecutable = try XCTUnwrap(ProcessIdentity.capture(pid: getpid())?.executable)
        return try await Task.detached {
            let process = Process(); let output = Pipe(), error = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "TETHER_SERVICE_SOCKET")
            env["TETHER_USER_SESSION_SOCKET"] = socket
            env["TETHER_USER_SESSION_SERVER_EXECUTABLE"] = serverExecutable
            process.environment = env; process.standardOutput = output; process.standardError = error
            try process.run()
            let text = output.fileHandleForReading.readDataToEndOfFile()
            let message = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: text, as: UTF8.self), String(decoding: message, as: UTF8.self))
        }.value
    }
}
