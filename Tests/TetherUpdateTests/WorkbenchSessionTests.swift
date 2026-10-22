import XCTest
@testable import Tether
import TetherCore

/// The same private subprocess/IPC route used by the interactive preview. No native
/// assertion, installed helper, production preference or global power write is used.
@MainActor
private final class WorkbenchFixture {
    let folder = URL(fileURLWithPath: "/tmp/tether-wb-" + String(UUID().uuidString.prefix(12)))
    let helper = Process()
    private let previousSocket = ProcessInfo.processInfo.environment["TETHER_SERVICE_SOCKET"]
    private var readings: [String: Any] = ["power": "ac", "hardware": "portable", "lid": "open",
        "sleepDisabled": false, "fullWake": true, "external": false, "displaySleeping": true,
        "temperature": 30, "thermal": 0, "battery": 80]
    private(set) var session: WorkbenchSession?
    var client: ServiceClient { ServiceClient(path: folder.appendingPathComponent("service.sock").path) }

    init(power: String = "ac") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["TETHER_TEST_HELPER"]
            ?? root.appendingPathComponent(".build/debug/TetherHelper").path
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw ServiceFailure("unavailable")
        }
        let control = folder.appendingPathComponent("control.json")
        guard JSONFile.write(Control(), to: control.path, permissions: 0o600) else { throw ServiceFailure("writeFailed") }
        readings["power"] = power
        try patch()
        let log = folder.appendingPathComponent("helper.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        helper.executableURL = URL(fileURLWithPath: binary)
        helper.arguments = ["--dry-run", "--control", control.path, "--status", folder.appendingPathComponent("status.json").path,
            "--fake", folder.appendingPathComponent("fake.json").path]
        helper.standardOutput = output; helper.standardError = output
        setenv("TETHER_SERVICE_SOCKET", folder.appendingPathComponent("service.sock").path, 1)
        do { try helper.run() }
        catch { close(); throw error }
    }

    func ready() async throws -> ServiceReply {
        for _ in 0..<150 {
            guard helper.isRunning else { throw ServiceFailure("unavailable") }
            if let reply = try? client.perform(ServiceRequest(.snapshot)), reply.status != nil { return reply }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ServiceFailure("unavailable")
    }

    func open() async throws -> WorkbenchSession {
        let value = try WorkbenchSession(folder: folder, initial: await ready())
        session = value
        // New installations start with automatic/lid use off. These interaction
        // fixtures explicitly choose both before testing coordination.
        value.model.setEnabled(true)
        value.model.setAllowClosedLid(true)
        value.model.setPowerCondition(.ac)
        value.model.setUserAutomatic(true)
        return value
    }

    func patch(_ values: [String: Any] = [:], removing: [String] = []) throws {
        for key in removing { readings.removeValue(forKey: key) }
        readings.merge(values) { _, new in new }
        try JSONSerialization.data(withJSONObject: readings).write(to: folder.appendingPathComponent("fake.json"), options: .atomic)
    }

    func snapshot() throws -> ServiceReply { try client.perform(ServiceRequest(.snapshot)) }
    func snapshotDescription() -> String {
        (try? String(decoding: JSONEncoder().encode(snapshot()), as: UTF8.self)) ?? logsForFailure()
    }
    private func logsForFailure() -> String { (try? String(contentsOf: folder.appendingPathComponent("helper.log"), encoding: .utf8)) ?? "no log" }

    func close() {
        session?.cleanup(); session = nil
        if helper.isRunning {
            helper.terminate()
            for _ in 0..<100 where helper.isRunning { usleep(10_000) }
            if helper.isRunning { kill(helper.processIdentifier, SIGKILL) }
            helper.waitUntilExit()
        }
        if let previousSocket { setenv("TETHER_SERVICE_SOCKET", previousSocket, 1) }
        else { unsetenv("TETHER_SERVICE_SOCKET") }
        try? FileManager.default.removeItem(at: folder)
    }
}

final class WorkbenchSessionTests: XCTestCase {
    @MainActor
    private func wait(_ message: String, diagnostics: (() -> String)? = nil, condition: () throws -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(message + (diagnostics.map { "\n" + $0() } ?? ""), file: file, line: line)
        throw ServiceFailure("unavailable")
    }

    @MainActor
    func testPreviewRejectsLiveOrIncompatibleEndpointWithoutAttaching() async throws {
        let f = try WorkbenchFixture(); defer { f.close() }
        let initial = try await f.ready()
        for kind in [0, 1, 2, 3] {
            var rejected = initial
            if kind == 0 { rejected.protection?.dryRun = false }
            if kind == 1 { rejected.status?.build = TetherPaths.build + 1 }
            if kind == 2 { rejected.status?.workSessionCoordinatorVersion = 1 }
            if kind == 3 { rejected.status = nil }
            XCTAssertThrowsError(try WorkbenchSession(folder: f.folder, initial: rejected))
        }
        let unchanged = try f.snapshot()
        XCTAssertEqual(unchanged.status?.appConnected, initial.status?.appConnected)
        XCTAssertEqual(unchanged.status?.appPID, initial.status?.appPID)
        XCTAssertEqual(unchanged.status?.workSession, initial.status?.workSession)
        XCTAssertEqual(unchanged.workSessionBridge?.coordinated, initial.workSessionBridge?.coordinated)
    }

    @MainActor
    func testAutomaticAndManualShareOneAllocationAndQuitDrainsOnlyPreview() async throws {
        let f = try WorkbenchFixture(); defer { f.close() }
        let s = try await f.open()
        try await wait("common attachment") { try s.model.workSessionHolding && !s.model.lidCommandPending && f.snapshot().status?.workSession != nil }
        XCTAssertTrue(s.model.usesUserSession); XCTAssertTrue(s.model.automaticWorkReasonActive)
        XCTAssertEqual(s.backend.creates, 1)
        s.model.startManualSession(minutes: 10)
        try await wait("two coordinated reasons") { Set(try f.snapshot().status?.workSession?.reasons ?? []) == [.automatic, .manual] }
        XCTAssertTrue(s.model.manualSessionActive); XCTAssertEqual(s.backend.creates, 1)
        s.model.endManualSession()
        try await wait("manual removal preserves automatic") { try f.snapshot().status?.workSession?.reasons == [.automatic] }
        XCTAssertTrue(s.model.workSessionHolding); XCTAssertFalse(s.model.manualSessionActive)
        XCTAssertEqual(s.backend.releases, 0)
        let stopped = await s.model.prepareToQuit()
        XCTAssertTrue(stopped); XCTAssertFalse(s.controller.status.holding)
        let root = try f.snapshot()
        XCTAssertFalse(root.status?.appConnected == true); XCTAssertFalse(root.status?.ownsOverride == true)
        XCTAssertNil(root.status?.workSession)
        XCTAssertEqual(s.backend.creates, 1); XCTAssertEqual(s.backend.releases, 1)
        let suite = s.suite; s.cleanup()
        XCTAssertTrue(UserDefaults.standard.persistentDomain(forName: suite)?.isEmpty ?? true)
    }

    @MainActor
    func testRootStopConsumesUnknownLidGrantAndFreshEmptyHandshakePreservesStopUntilExplicitResume() async throws {
        let f = try WorkbenchFixture(); defer { f.close() }
        let s = try await f.open()
        try await wait("initial automatic attachment") { !s.model.lidCommandPending && s.model.workSessionHolding }
        s.model.startManualSession(minutes: 10)
        try await wait("automatic and manual fully attached") {
            let root = try f.snapshot()
            return !s.model.lidCommandPending && !s.model.v4ManualApprovalPending
                && Set(root.status?.workSession?.reasons ?? []) == [.automatic, .manual]
                && root.status?.ownsOverride == true
        }
        let active = try XCTUnwrap(f.snapshot().status?.workSession)
        let oldManualID = try XCTUnwrap(active.manualRequestID)
        let oldDeadline = try XCTUnwrap(active.manualDeadline)
        let controllerID = s.controller.sessionID
        let logURL = f.folder.appendingPathComponent("helper.log")
        let beforeLog = try String(contentsOf: logURL, encoding: .utf8)
        let preparations = beforeLog.components(separatedBy: "work session prepared;").count - 1
        XCTAssertEqual(s.backend.creates, 1)

        // A missing lid observation normally preserves this already-issued grant
        // for its original finite grace. An authenticated root Stop must consume
        // it immediately, before the GUI has received that command's bridge.
        try f.patch(["lid": NSNull()])
        let unknown = try f.client.perform(ServiceRequest(.markDiagnostic))
        XCTAssertNil(unknown.status?.observedLidClosed)
        XCTAssertEqual(unknown.status?.workSession, active)
        let stopped = try f.client.perform(ServiceRequest(.stop))
        XCTAssertNil(stopped.status?.workSession)
        XCTAssertEqual(stopped.status?.ownsOverride, false)
        XCTAssertEqual(stopped.workSessionBridge?.stopRequested, true)

        s.model.refresh()
        try await wait("fresh preparation acknowledges root stop with disabled empty work", diagnostics: f.snapshotDescription) {
            let root = try f.snapshot()
            return !s.model.lidCommandPending && !s.model.workSessionHolding
                && root.workSessionBridge?.stopRequested == false
                && root.status?.workSession?.sessionID == controllerID
                && root.status?.workSession?.configuration.enabled == false
                && root.status?.workSession?.reasons.isEmpty == true
        }
        let acknowledged = try XCTUnwrap(f.snapshot().status?.workSession)
        let acknowledgedLog = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(acknowledgedLog.components(separatedBy: "work session prepared;").count - 1, preparations + 1,
            "The consumed root grant requires a fresh preparation instead of retrying only old sync messages")
        XCTAssertGreaterThan(acknowledged.sequence, active.sequence)
        XCTAssertEqual(s.controller.sessionID, controllerID)
        XCTAssertEqual(s.controller.runtimeMarkers.pauseReason, .userStop)
        XCTAssertTrue(s.controller.settings.automaticEnabled, "Stop preserves the saved automatic option")
        XCTAssertFalse(s.controller.settings.enabled)
        XCTAssertNil(acknowledged.manualRequestID)
        XCTAssertNil(acknowledged.manualDeadline)
        XCTAssertNil(s.controller.manualRequestID)
        XCTAssertNil(s.controller.status.manualContinuousDeadline)
        XCTAssertFalse(s.model.manualSessionActive)
        XCTAssertEqual(s.backend.releases, 1)

        // Healthy observations and ordinary refresh cannot clear the durable
        // user stop or restore the consumed manual request's original deadline.
        try f.patch(["lid": "open"])
        _ = try f.client.perform(ServiceRequest(.markDiagnostic))
        s.controller.refresh(); s.model.refresh()
        try await wait("ordinary refresh keeps the stop acknowledged") { !s.model.lidCommandPending }
        XCTAssertEqual(s.controller.runtimeMarkers.pauseReason, .userStop)
        XCTAssertFalse(s.model.workSessionHolding)
        XCTAssertNil(s.controller.manualRequestID)
        XCTAssertNil(s.controller.status.manualContinuousDeadline)
        XCTAssertEqual(s.backend.creates, 1)

        s.model.setEnabled(true)
        try await wait("explicit resume starts only new automatic work", diagnostics: f.snapshotDescription) {
            let root = try f.snapshot()
            return !s.model.lidCommandPending && s.model.workSessionHolding
                && root.status?.workSession?.sessionID == controllerID
                && root.status?.workSession?.reasons == [.automatic]
                && root.status?.ownsOverride == true
        }
        let resumed = try XCTUnwrap(f.snapshot().status?.workSession)
        XCTAssertNil(s.controller.runtimeMarkers.pauseReason)
        XCTAssertNil(resumed.manualRequestID)
        XCTAssertNil(resumed.manualDeadline)
        XCTAssertNotEqual(resumed.manualRequestID, oldManualID)
        XCTAssertNotEqual(resumed.manualDeadline, oldDeadline)
        XCTAssertFalse(s.model.manualSessionActive)
        XCTAssertEqual(s.backend.creates, 2)
        XCTAssertFalse(try String(contentsOf: logURL, encoding: .utf8).contains("IOPMSleepSystem [v3"))
        let quit = await s.model.prepareToQuit(); XCTAssertTrue(quit)
    }

    @MainActor
    func testGUIFirstACUnplugEndsClosedWorkWithoutRemoteOrForeignRequests() async throws {
        for reasons in [[WorkSessionReason.automatic], [.manual], [.automatic, .manual]] {
            let f = try WorkbenchFixture(); defer { f.close() }
            try f.patch(["lid": "closed", "external": false, "authenticatedRemote": false,
                "foreignKeepAwake": false, "foreignDisplayKeepAwake": false,
                "displayTopology": "none", "displaySleeping": NSNull()])
            let s = try await f.open()
            s.model.setPowerCondition(.ac)
            if !reasons.contains(.automatic) { s.model.setUserAutomatic(false) }
            if reasons.contains(.manual) { s.model.startManualSession(minutes: 10) }
            try await wait("AC-only permit before GUI-first unplug") {
                let root = try f.snapshot()
                return !s.model.lidCommandPending && root.status?.ownsOverride == true
                    && Set(root.status?.workSession?.reasons ?? []) == Set(reasons)
                    && root.status?.workSession?.lidPermit?.powerScopes == [.ac]
            }
            try f.patch(["power": "battery"])
            // Only the production controller refreshes first. A helper marker
            // would consume the old permit first and hide the IPC race.
            s.controller.refresh()
            try await wait("GUI-first \(reasons) disconnect receipt and release", diagnostics: {
                let root = (try? f.snapshot()).flatMap { try? JSONEncoder().encode($0) }
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "unavailable"
                let log = (try? String(contentsOf: f.folder.appendingPathComponent("helper.log"), encoding: .utf8)) ?? "unavailable"
                return "root=\(root)\ncontroller=\(s.controller.status)\nhelper=\(log)"
            }) {
                let root = try f.snapshot()
                return !s.model.lidCommandPending && !s.model.workSessionHolding
                    && root.status?.ownsOverride == false
                    && root.workSessionBridge?.lidEndReceipt?.phase == .consumed
            }
            let end = try XCTUnwrap(f.snapshot().workSessionBridge?.lidEndReceipt)
            XCTAssertEqual(end.kind, .disconnect); XCTAssertEqual(end.outcome, "commandAccepted")
            XCTAssertNil(end.observedSleepAt, "Dry-run command acceptance is not observed OS Sleep")
            let log = try String(contentsOf: f.folder.appendingPathComponent("helper.log"), encoding: .utf8)
            XCTAssertEqual(log.components(separatedBy: "IOPMSleepSystem [v3").count - 1, 1)
            let stopped = await s.model.prepareToQuit(); XCTAssertTrue(stopped)
        }
    }

    @MainActor
    func testExplicitReleaseAtUnplugDoesNotRequestDisconnectSleep() async throws {
        for release in ["disabled", "automaticOff", "lidOff", "manualOff", "userStop", "followOS", "thermal"] {
            let f = try WorkbenchFixture(); defer { f.close() }
            try f.patch(["lid": "closed"])
            let s = try await f.open()
            s.model.setPowerCondition(.ac)
            if release == "manualOff" {
                s.model.setUserAutomatic(false)
                s.model.startManualSession(minutes: 10)
            }
            try await wait("AC permit before explicit \(release)") {
                let root = try f.snapshot()
                return !s.model.lidCommandPending && root.status?.ownsOverride == true
                    && root.status?.workSession?.lidPermit?.powerScopes == [.ac]
                    && (release != "manualOff" || root.status?.workSession?.reasons == [.manual])
            }
            try f.patch(["power": "battery", "thermal": release == "thermal" ? 2 : 0])
            switch release {
            case "disabled": s.model.setEnabled(false)
            case "automaticOff": s.model.setUserAutomatic(false)
            case "lidOff": s.model.setAllowClosedLid(false)
            case "manualOff": s.model.endManualSession()
            case "userStop": s.controller.stopCurrent()
            case "followOS": s.model.setDisconnectAction(.followOS)
            default: s.controller.refresh()
            }
            try await wait("explicit \(release) releases the root permit") {
                let root = try f.snapshot()
                return !s.model.lidCommandPending && !s.model.workSessionHolding
                    && root.status?.ownsOverride == false && root.status?.workSession?.power == .battery
            }
            let root = try f.snapshot()
            XCTAssertEqual(root.status?.workSession?.disconnectEndRequested, false, release)
            XCTAssertNil(root.workSessionBridge?.lidEndReceipt, release)
            let log = try String(contentsOf: f.folder.appendingPathComponent("helper.log"), encoding: .utf8)
            XCTAssertFalse(log.contains("IOPMSleepSystem [v3"), release)
            let stopped = await s.model.prepareToQuit(); XCTAssertTrue(stopped)
        }
    }

    @MainActor
    func testOldManualDisconnectCannotTurnAutomaticOffIntoSleep() async throws {
        let f = try WorkbenchFixture(); defer { f.close() }
        try f.patch(["lid": "closed"])
        let s = try await f.open()
        s.model.setAllowClosedLid(false); s.model.setPowerCondition(.ac)
        s.model.startManualSession(minutes: 10)
        try await wait("manual work without lid authority") {
            let root = try f.snapshot()
            return !s.model.lidCommandPending && root.status?.workSession?.reasons.contains(.manual) == true
                && root.status?.ownsOverride == false
        }
        try f.patch(["power": "battery"]); s.controller.refresh()
        try await wait("old manual disconnect") { !s.model.lidCommandPending && !s.model.workSessionHolding }
        XCTAssertEqual(s.controller.status.manualEndReason, .powerDisconnected)
        try f.patch(["power": "ac"]); s.controller.refresh()
        s.model.setAllowClosedLid(true)
        try await wait("new automatic-only AC permit") {
            let root = try f.snapshot()
            return !s.model.lidCommandPending && root.status?.ownsOverride == true
                && root.status?.workSession?.reasons == [.automatic]
        }
        try f.patch(["power": "battery"]); s.model.setUserAutomatic(false)
        try await wait("automatic Off releases new work") {
            let root = try f.snapshot()
            return !s.model.lidCommandPending && !s.model.workSessionHolding
                && root.status?.ownsOverride == false && root.status?.workSession?.power == .battery
        }
        let root = try f.snapshot()
        XCTAssertEqual(root.status?.workSession?.disconnectEndRequested, false)
        XCTAssertNil(root.workSessionBridge?.lidEndReceipt)
        let log = try String(contentsOf: f.folder.appendingPathComponent("helper.log"), encoding: .utf8)
        XCTAssertFalse(log.contains("IOPMSleepSystem [v3"))
        let stopped = await s.model.prepareToQuit(); XCTAssertTrue(stopped)
    }

    @MainActor
    func testFreshBatteryInputRejectsUnlimitedAndCapsManualBudget() async throws {
        let f = try WorkbenchFixture(); defer { f.close() }
        let s = try await f.open()
        try await wait("initial attachment") { !s.model.lidCommandPending && s.model.workSessionHolding }
        s.model.setUserAutomatic(false)
        try await wait("automatic off") { !s.model.lidCommandPending && !s.model.workSessionHolding }
        // Do not refresh the controller first: the start action must read the new input.
        try f.patch(["power": "battery"])
        s.model.startUntimedSession()
        XCTAssertEqual(s.controller.status.power, .battery)
        XCTAssertFalse(s.controller.status.manualActive); XCTAssertFalse(s.controller.status.holding)
        s.model.startManualSession(minutes: 180)
        XCTAssertFalse(s.controller.status.manualActive)
        s.model.startManualSession(minutes: 120)
        XCTAssertTrue(s.controller.status.manualActive)
        let deadline = try XCTUnwrap(s.model.manualSessionUntil)
        XCTAssertGreaterThan(deadline.timeIntervalSinceNow, 7_195)
        XCTAssertLessThanOrEqual(deadline.timeIntervalSinceNow, 7_200)
        XCTAssertEqual(s.model.manualMaximumMinutes, 120)
        try await wait("battery manual lease") { try f.snapshot().status?.workSession?.reasons == [.manual] }
        XCTAssertEqual(try f.snapshot().status?.workSession?.power, .battery)
        try f.patch(["power": "ac"]); s.controller.refresh()
        try await wait("AC change relayed") { try f.snapshot().status?.workSession?.power == .ac }
        // Returning to AC cannot extend the original battery-started request.
        XCTAssertEqual(s.model.manualSessionUntil, deadline)
        let stopped = await s.model.prepareToQuit(); XCTAssertTrue(stopped)
    }

    @MainActor
    func testRetiredContinuationCannotCarryRequestsAcrossUnplugAndManualEndKeepsACAuto() async throws {
        let f = try WorkbenchFixture(); defer { f.close() }
        let s = try await f.open()
        try await wait("initial attachment") { !s.model.lidCommandPending && s.model.workSessionHolding }
        s.model.setManualBatteryContinuationMinutes(15)
        XCTAssertNil(s.controller.status.manualBatteryContinuationMinutes)
        s.model.startManualSession(minutes: 10)
        try await wait("dual AC reasons confirmed") {
            try !s.model.lidCommandPending && Set(f.snapshot().status?.workSession?.reasons ?? []) == [.automatic, .manual]
        }
        try f.patch(["power": "battery"]); s.controller.refresh()
        try await wait("unplug consumes both requests") {
            try !s.model.lidCommandPending && !s.model.workSessionHolding && f.snapshot().status?.ownsOverride == false
        }
        XCTAssertFalse(s.controller.status.manualActive)
        XCTAssertNil(s.controller.status.manualContinuousDeadline)
        XCTAssertNil(s.controller.status.pendingBatteryMinutes)
        try f.patch(["power": "ac"]); s.controller.refresh()
        try await wait("new AC automatic reason only") {
            try !s.model.lidCommandPending && f.snapshot().status?.workSession?.reasons == [.automatic]
        }
        XCTAssertFalse(s.model.manualSessionActive)
        s.model.startManualSession(minutes: 10)
        try await wait("new manual request") {
            try !s.model.lidCommandPending && Set(f.snapshot().status?.workSession?.reasons ?? []) == [.automatic, .manual]
        }
        s.model.endManualSession()
        try await wait("manual end preserves AC automatic") { try f.snapshot().status?.workSession?.reasons == [.automatic] }
        XCTAssertFalse(s.model.manualSessionActive)
        XCTAssertTrue(s.model.workSessionHolding)
        let stopped = await s.model.prepareToQuit(); XCTAssertTrue(stopped)
    }

    @MainActor
    func testBatteryManualRequiresFreshStartAndReunplugConsumesItThroughHelperIPC() async throws {
        let f = try WorkbenchFixture(); defer { f.close() }
        let s = try await f.open()
        try await wait("initial attachment") { !s.model.lidCommandPending && s.model.workSessionHolding }
        s.model.setUserAutomatic(false)
        try await wait("automatic off") { !s.model.lidCommandPending && !s.model.workSessionHolding }
        try f.patch(["power": "battery"]); s.controller.refresh()
        s.model.startManualSession(minutes: 15)
        try await wait("explicit battery manual confirmed") {
            try !s.model.lidCommandPending && f.snapshot().status?.workSession?.reasons == [.manual]
        }
        let deadline = try XCTUnwrap(s.model.manualSessionUntil)
        let request = try XCTUnwrap(s.controller.manualRequestID)
        for enabled in [true, false] {
            s.model.setUserAutomatic(enabled)
            XCTAssertEqual(s.controller.manualRequestID, request)
            XCTAssertEqual(s.model.manualSessionUntil, deadline)
            XCTAssertFalse(s.model.automaticWorkReasonActive)
        }
        try f.patch(["power": "ac"]); s.controller.refresh()
        try await wait("AC reconnect preserves deadline") { try !s.model.lidCommandPending && f.snapshot().status?.workSession?.power == .ac }
        XCTAssertEqual(s.model.manualSessionUntil, deadline)
        try f.patch(["power": "battery"]); s.controller.refresh()
        try await wait("second unplug consumes battery-started manual") { !s.model.lidCommandPending && !s.model.workSessionHolding }
        XCTAssertFalse(s.model.manualSessionActive)
        XCTAssertNil(s.controller.manualRequestID)
        XCTAssertNil(s.model.manualSessionUntil)
        let stopped = await s.model.prepareToQuit(); XCTAssertTrue(stopped)
    }

    @MainActor
    func testHardwareObservationChangesPreserveGeneralSessionAndDeadline() async throws {
        let f = try WorkbenchFixture(); defer { f.close() }
        let s = try await f.open()
        try await wait("initial attachment") { !s.model.lidCommandPending && s.model.workSessionHolding }
        s.model.startManualSession(minutes: 10); s.model.setUserAutomatic(false)
        try await wait("manual attachment") { !s.model.lidCommandPending && s.model.clamshellActive }
        let deadline = s.model.manualSessionUntil
        for hardware in ["unknown", "desktop"] {
            try f.patch(["hardware": hardware]); s.model.refresh()
            try await wait("lid detach for \(hardware)") { try !s.model.lidCommandPending && f.snapshot().status?.appConnected == false }
            XCTAssertTrue(s.model.usesUserSession); XCTAssertTrue(s.model.workSessionHolding)
            XCTAssertTrue(s.model.manualSessionActive); XCTAssertEqual(s.model.manualSessionUntil, deadline)
            XCTAssertEqual(s.backend.creates, 1); XCTAssertEqual(s.backend.releases, 0)
        }
        try f.patch(["hardware": "portable"]); s.model.refresh()
        try await wait("lid reconnect") { !s.model.lidCommandPending && s.model.clamshellActive }
        XCTAssertEqual(s.model.manualSessionUntil, deadline); XCTAssertEqual(s.backend.creates, 1)
        let stopped = await s.model.prepareToQuit(); XCTAssertTrue(stopped)
    }

    @MainActor
    func testMissingLidReadingsDoNotCancelManualWorkOrCreateAnotherAllocation() async throws {
        let f = try WorkbenchFixture(); defer { f.close() }
        let s = try await f.open()
        try await wait("initial attachment") { !s.model.lidCommandPending && s.model.workSessionHolding }
        s.model.startManualSession(minutes: 10)
        try await wait("manual attachment fully approved") {
            try f.snapshot().status?.workSession?.reasons.contains(.manual) == true
                && !s.model.v4ManualApprovalPending && s.model.manualLidFeaturesConfirmed
        }
        let deadline = s.model.manualSessionUntil
        let originalGrant = try XCTUnwrap(f.snapshot().status?.workSession)
        try f.patch(["lid": NSNull(), "sleepDisabled": NSNull()])
        // Unknown readback preserves only the already-issued finite grant.
        // Ownership evidence is not confirmation of the current OS effect.
        for _ in 0..<2 {
            let held = try f.client.perform(ServiceRequest(.markDiagnostic))
            XCTAssertNil(held.status?.observedSleepDisabled)
            XCTAssertEqual(held.status?.workSession, originalGrant)
            s.model.refresh()
        }
        try await wait("missing observation relayed") {
            s.model.refresh()
            return s.model.status?.observedLidClosed == nil && s.model.status?.observedSleepDisabled == nil
        }
        XCTAssertTrue(try f.snapshot().status?.ownsOverride == true)
        XCTAssertTrue(s.model.workSessionHolding); XCTAssertTrue(s.model.manualSessionActive)
        XCTAssertEqual(s.model.manualSessionUntil, deadline); XCTAssertEqual(s.backend.creates, 1)
        // Move beyond the original finite grant. The fresh readback can confirm
        // its release, but cannot revive the old root request or replace the
        // still-healthy general allocation.
        try f.patch(["lid": "open", "sleepDisabled": true, "manualClock": ContinuousTime.now + 31])
        let restored = try f.client.perform(ServiceRequest(.markDiagnostic))
        XCTAssertEqual(restored.status?.ownsOverride, false, "A successful readback must confirm only our override was restored")
        s.model.refresh()
        try await wait("observation recovered") { s.model.status?.observedLidClosed == false && !s.model.lidCommandPending }
        XCTAssertEqual(s.model.manualSessionUntil, deadline); XCTAssertEqual(s.backend.releases, 0)
        let stopped = await s.model.prepareToQuit()
        XCTAssertTrue(stopped, "Quit after recovered observation: \(s.model.errorText ?? "none")\n\(f.snapshotDescription())")
    }

    @MainActor
    func testUnchangedDisplayChoiceKeepsObservationsIndependentWithoutWriting() async throws {
        let f = try WorkbenchFixture(); defer { f.close() }
        let s = try await f.open()
        try await wait("initial common attachment") {
            !s.model.lidCommandPending && s.model.workSessionHolding && s.model.automaticWorkReasonActive
        }
        s.model.setClosedLidDisplayMode(.unchanged)
        try await wait("helper acknowledges unchanged display choice") {
            try f.snapshot().status?.workSession?.effectiveClosedLidDisplayMode == .unchanged
        }
        s.model.startManualSession(minutes: 10)
        try await wait("automatic and manual reasons attached") {
            Set(try f.snapshot().status?.workSession?.reasons ?? []) == [.automatic, .manual]
        }
        let deadline = try XCTUnwrap(s.model.manualSessionUntil)
        let sessionID = try XCTUnwrap(f.snapshot().status?.workSession?.sessionID)

        func assertWorkRetained(file: StaticString = #filePath, line: UInt = #line) throws {
            let reply = try f.snapshot()
            XCTAssertTrue(s.model.workSessionHolding, file: file, line: line)
            XCTAssertTrue(s.model.manualSessionActive, file: file, line: line)
            XCTAssertTrue(s.model.automaticWorkReasonActive, file: file, line: line)
            XCTAssertEqual(s.model.manualSessionUntil, deadline, file: file, line: line)
            XCTAssertEqual(s.backend.creates, 1, file: file, line: line)
            XCTAssertEqual(s.backend.releases, 0, file: file, line: line)
            XCTAssertNil(s.model.protection?.blockReason, file: file, line: line)
            XCTAssertNil(reply.protection?.blockReason, file: file, line: line)
            XCTAssertTrue(reply.status?.ownsOverride == true, file: file, line: line)
            XCTAssertEqual(reply.status?.workSession?.sessionID, sessionID, file: file, line: line)
            XCTAssertEqual(Set(reply.status?.workSession?.reasons ?? []), [.automatic, .manual], file: file, line: line)
        }

        // The unchanged choice reports panel observations without starting a
        // display writer. Foreign display requests do not grant a writer.
        try f.patch(["lid": "closed", "foreignDisplayRequest": true, "displaySleeping": false, "displayClock": 100.0])
        _ = try f.client.perform(ServiceRequest(.markDiagnostic))
        try await wait("awake panel observation reaches the common model") {
            s.model.refresh()
            return s.model.status?.observedLidClosed == true && s.model.status?.displaySleeping == false
        }
        XCTAssertNil(s.model.displaySleepStatus)
        XCTAssertEqual(try f.snapshot().status?.displayRecovery?.phase, .inactive)
        XCTAssertEqual(try f.snapshot().status?.displayRecovery?.requests, 0)
        try assertWorkRetained()

        // Query failure is not a known lit panel and must not issue display commands.
        try f.patch(["foreignDisplayRequest": false, "displaySleeping": NSNull(), "displayClock": 100.0])
        _ = try f.client.perform(ServiceRequest(.markDiagnostic))
        try await wait("missing display observation is shown separately") {
            s.model.refresh()
            return s.model.status?.displaySleeping == nil
        }
        XCTAssertNil(s.model.displaySleepStatus)
        XCTAssertNil(try f.snapshot().status?.displaySleeping)
        try assertWorkRetained()

        // Crossing the old display timeout cannot create a stopped recovery
        // controller or another display command in the lease-only executor.
        try f.patch(["displayClock": 100.0 + DisplaySleepGate.acknowledgementWindow])
        _ = try f.client.perform(ServiceRequest(.markDiagnostic))
        s.model.refresh()
        XCTAssertEqual(try f.snapshot().status?.displayRecovery?.phase, .inactive)
        XCTAssertEqual(try f.snapshot().status?.displayRecovery?.requests, 0)
        try assertWorkRetained()

        try f.patch(["lid": "open"])
        _ = try f.client.perform(ServiceRequest(.markDiagnostic))
        try await wait("opening the lid clears the closed-screen notice") {
            s.model.refresh()
            return s.model.status?.observedLidClosed == false && s.model.displaySleepStatus == nil
                && !s.model.needsActivityReview
        }
        try assertWorkRetained()
        let helperLog = try String(contentsOf: f.folder.appendingPathComponent("helper.log"), encoding: .utf8)
        XCTAssertFalse(helperLog.contains("pmset displaysleepnow"))
        XCTAssertFalse(helperLog.contains("IOPMSleepSystem"))
        let stopped = await s.model.prepareToQuit(); XCTAssertTrue(stopped)
    }

    @MainActor
    func testAdditionalDisplayPresentationUsesCurrentPanelObservationAndRejectsOldSamples() throws {
        let name = "TetherDisplayPresentation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        func preview(topology: DisplayTopology = .virtualOnly, sleeping: Bool? = true,
                     timestamp: Double = Date().timeIntervalSince1970, lid: Bool? = true,
                     wake: Bool? = true) -> AppModel {
            var status = Status(updatedAt: timestamp, version: TetherPaths.version, enabled: true,
                power: .ac, lidClosed: lid ?? false, sleepDisabled: true,
                lastEvent: nil, lastEventAt: nil, fullWake: wake)
            status.build = TetherPaths.build
            status.lidObservationAvailable = lid != nil; status.sleepOverrideObservationAvailable = true
            status.ownsOverride = true; status.appConnected = true
            status.externalDisplay = topology.mayHaveExternal; status.displayTopology = topology
            status.displaySleeping = sleeping
            // The helper phase belongs to a previous display setup; it is not the current panel reading.
            status.displayRecovery = DisplayRecoveryStatus(phase: .asleep, requests: 2)
            var reply = ServiceReply(id: UUID(), ok: true, epoch: "display-preview", revision: 1,
                control: Control(enabled: true), protection: ProtectionStatus(reason: nil, error: nil, dryRun: true))
            reply.status = status
            return AppModel(preview: true,
                capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
                previewWorkService: { _ in reply }, previewHelperReply: reply, previewDefaults: defaults)
        }

        for topology in [DisplayTopology.virtualOnly, .externalWithVirtual, .externalUnverified] {
            for (sleeping, phase) in [(true as Bool?, DisplaySleepGate.Phase.asleep), (false, .deferred), (nil, .unavailable)] {
                let model = preview(topology: topology, sleeping: sleeping)
                XCTAssertTrue(model.clamshellActive)
                XCTAssertEqual(model.displaySleepStatus?.phase, phase)
                XCTAssertNotNil(model.displaySleepSummary); XCTAssertNotNil(model.displaySleepDetail)
                XCTAssertEqual(model.status?.displayRecovery?.phase, .asleep)
                XCTAssertEqual(model.status?.displayRecovery?.requests, 2)
                if sleeping != true {
                    XCTAssertNotEqual(model.displaySleepSummary, L("Built-in display sleep observed", "내장 화면 절전 관측"))
                }
            }
        }
        let now = Date().timeIntervalSince1970
        for timestamp in [now - 31, now + 3_600, Double.infinity, Double.nan] {
            let model = preview(timestamp: timestamp)
            XCTAssertNil(model.displaySleepStatus); XCTAssertNil(model.displaySleepSummary); XCTAssertNil(model.displaySleepDetail)
        }
        for model in [preview(lid: false), preview(lid: nil), preview(wake: false), preview(wake: nil), preview(topology: .unknown)] {
            XCTAssertNil(model.displaySleepStatus); XCTAssertNil(model.displaySleepSummary); XCTAssertNil(model.displaySleepDetail)
        }
    }

    @MainActor
    func testVirtualDisplayNoticeTracksPanelAndLidWithoutChangingCommonWorkOrIssuingSleep() async throws {
        let f = try WorkbenchFixture(); defer { f.close() }
        let s = try await f.open()
        try await wait("initial common attachment") {
            s.model.workSessionHolding && !s.model.lidCommandPending
        }
        s.model.startManualSession(minutes: 10)
        try await wait("manual reason attached") { try f.snapshot().status?.workSession?.reasons.contains(.manual) == true }
        let deadline = try XCTUnwrap(s.model.manualSessionUntil)
        let sessionID = try XCTUnwrap(f.snapshot().status?.workSession?.sessionID)

        for (topology, sleeping, phase) in [
            (DisplayTopology.virtualOnly, false as Bool?, DisplaySleepGate.Phase.deferred),
            (.externalWithVirtual, true, .asleep),
            (.externalWithVirtual, nil, .unavailable),
            (.externalUnverified, false, .deferred)
        ] {
            try f.patch(["lid": "closed", "displayTopology": topology.rawValue, "displaySleeping": sleeping.map { $0 as Any } ?? NSNull()])
            _ = try f.client.perform(ServiceRequest(.markDiagnostic))
            try await wait("current additional-display observation reaches presentation") {
                s.model.refresh()
                return s.model.snapshot.displayTopology == topology && s.model.status?.displaySleeping == sleeping
                    && s.model.displaySleepStatus?.phase == phase
            }
            XCTAssertEqual(try f.snapshot().status?.displayRecovery?.phase, .inactive)
            XCTAssertEqual(try f.snapshot().status?.displayRecovery?.requests, 0)
            XCTAssertTrue(s.model.workSessionHolding); XCTAssertTrue(s.model.manualSessionActive)
            XCTAssertEqual(s.model.manualSessionUntil, deadline)
            XCTAssertEqual(try f.snapshot().status?.workSession?.sessionID, sessionID)
            XCTAssertEqual(s.backend.creates, 1); XCTAssertEqual(s.backend.releases, 0)
            XCTAssertNotNil(s.model.displaySleepDetail)
        }
        // Keep the earlier asleep reading in the fixture: an open lid must hide the closed-screen notice.
        try f.patch(["lid": "open", "displayTopology": DisplayTopology.virtualOnly.rawValue, "displaySleeping": true])
        _ = try f.client.perform(ServiceRequest(.markDiagnostic))
        try await wait("opening clears earlier display presentation") {
            s.model.refresh()
            return s.model.status?.observedLidClosed == false && s.model.displaySleepStatus == nil
        }
        XCTAssertNil(s.model.displaySleepSummary); XCTAssertNil(s.model.displaySleepDetail)
        try f.patch(["lid": "closed", "displaySleeping": false])
        _ = try f.client.perform(ServiceRequest(.markDiagnostic))
        try await wait("closing again does not reuse the old asleep observation") {
            s.model.refresh()
            return s.model.status?.observedLidClosed == true && s.model.displaySleepStatus?.phase == .deferred
        }
        XCTAssertEqual(s.model.manualSessionUntil, deadline); XCTAssertEqual(s.backend.releases, 0)
        XCTAssertEqual(try f.snapshot().status?.workSession?.sessionID, sessionID)
        let log = try String(contentsOf: f.folder.appendingPathComponent("helper.log"), encoding: .utf8)
        XCTAssertFalse(log.contains("pmset displaysleepnow")); XCTAssertFalse(log.contains("IOPMSleepSystem"))
        try f.patch(["lid": "open"])
        _ = try f.client.perform(ServiceRequest(.markDiagnostic))
        let stopped = await s.model.prepareToQuit(); XCTAssertTrue(stopped)
    }

    func testFailedFixtureReadNeverFallsBackToThisMac() throws {
        let path = URL(fileURLWithPath: "/tmp/tether-workbench-missing-" + UUID().uuidString)
        let missing = WorkbenchInput.read(path)
        XCTAssertEqual(missing.environment.power, .unknown); XCTAssertNil(missing.environment.fullWake)
        XCTAssertNil(missing.environment.thermal); XCTAssertNil(missing.environment.batteryPercent)
        XCTAssertFalse(missing.capabilities.lidControlAvailable); XCTAssertNil(missing.capabilities.internalBattery)
        try Data("not JSON".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        XCTAssertEqual(WorkbenchInput.read(path).environment.power, .unknown)
        XCTAssertFalse(WorkbenchInput.read(path).capabilities.lidControlAvailable)
    }
}
