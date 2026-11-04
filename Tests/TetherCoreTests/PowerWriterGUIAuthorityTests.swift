import Darwin
import Foundation
import XCTest
@testable import TetherCore

final class PowerWriterGUIAuthorityTests: XCTestCase {
    private let operations = [["-a", "disablesleep", "1"], ["sleepnow"], ["displaysleepnow"]]

    private func fixture() throws -> (GUISessionOwner, HelperState, ProcessIdentity, GUISessionObservation) {
        let process = try XCTUnwrap(ProcessIdentity.capture(pid: getpid()))
        let login = GUISessionIdentity(uid: process.uid, sessionID: 42)
        let owner = GUISessionOwner(bootID: "boot", process: process, login: login)
        var state = HelperState()
        state.guiOwner = owner; state.controllerUID = login.uid
        state.appUID = login.uid; state.appPID = process.pid; state.appStarted = process.started
        return (owner, state, process, GUISessionObservation(login: login, consoleUID: login.uid))
    }

    private func permits(_ owner: GUISessionOwner?, _ state: HelperState?, _ process: ProcessIdentity?,
                         _ observation: GUISessionObservation, boot: String = "boot") -> Bool {
        PowerWriterGUIAuthority.permits(arguments: ["sleepnow"], effectiveUID: 0,
            owner: owner, state: state, process: process, boot: boot, observation: observation)
    }

    func testRootRequiresAuthorityForEveryGUIControlledOperation() {
        for arguments in operations {
            XCTAssertTrue(PowerWriterGUIAuthority.requiresCheck(arguments: arguments, effectiveUID: 0, owner: nil))
            XCTAssertFalse(PowerWriterGUIAuthority.permits(arguments: arguments, effectiveUID: 0,
                owner: nil, state: nil, process: nil, boot: "boot",
                observation: GUISessionObservation(login: nil, consoleUID: nil)))
        }
    }

    func testRestorationDoesNotRequireALivingGUIController() {
        for arguments in [["-a", "disablesleep", "0"], ["-b", "lowpowermode", "0"], ["-c", "powermode", "1"]] {
            XCTAssertFalse(PowerWriterGUIAuthority.requiresCheck(arguments: arguments, effectiveUID: 0, owner: nil))
            XCTAssertTrue(PowerWriterGUIAuthority.permits(arguments: arguments, effectiveUID: 0,
                owner: nil, state: nil, process: nil, boot: "boot",
                observation: GUISessionObservation(login: nil, consoleUID: nil)))
        }
    }

    func testConfirmedOwnerAllowsAllGUIControlledOperations() throws {
        let (owner, state, process, observation) = try fixture()
        for arguments in operations {
            XCTAssertTrue(PowerWriterGUIAuthority.permits(arguments: arguments, effectiveUID: 0,
                owner: owner, state: state, process: process, boot: "boot", observation: observation))
            XCTAssertTrue(PowerWriterGUIAuthority.requiresCheck(arguments: arguments, effectiveUID: 501, owner: owner))
        }
    }
    func testCoordinatedAcquisitionChecksTheStoredLeaseAgainAtTheExecBoundary() throws {
        let (owner, original, process, observation) = try fixture()
        var state = original; state.userSessionCoordinated = true
        let arguments = ["-a", "disablesleep", "1"]
        func allowed(_ value: HelperState, at now: Double = 100, power: PowerSource = .ac) -> Bool {
            PowerWriterGUIAuthority.permits(arguments: arguments, effectiveUID: 0, owner: owner,
                state: value, process: process, boot: "boot", observation: observation, now: now, power: power,
                thermal: 0, fullWake: true, batteryPercent: 80)
        }
        XCTAssertFalse(allowed(state))
        var settings = IdleSessionSettings(); settings.automaticEnabled = true
        state.workSessionLease = WorkSessionLease(sessionID: UUID(), sequence: 1, power: .ac,
            expiry: 115, reasons: [.automatic], settings: settings,
            lidPermit: WorkSessionLidPermit(powerScopes: [.ac]))
        XCTAssertTrue(allowed(state)); XCTAssertFalse(allowed(state, at: 190))
        XCTAssertFalse(allowed(state, power: .battery)); XCTAssertFalse(allowed(state, power: .unknown))
        XCTAssertFalse(PowerWriterGUIAuthority.permits(arguments: arguments, effectiveUID: 0, owner: owner,
            state: state, process: process, boot: "boot", observation: observation, now: 100, power: .ac,
            thermal: 2, fullWake: true))
        XCTAssertFalse(PowerWriterGUIAuthority.permits(arguments: arguments, effectiveUID: 0, owner: owner,
            state: state, process: process, boot: "boot", observation: observation, now: 100, power: .ac,
            thermal: 0, fullWake: false))
        state.coordinatedStopPending = true; XCTAssertFalse(allowed(state))
        XCTAssertTrue(PowerWriterGUIAuthority.permits(arguments: ["-a", "disablesleep", "0"], effectiveUID: 0,
            owner: owner, state: state, process: process, boot: "boot", observation: observation))
    }

    func testRevokedOrReplacedStateCannotExecuteQueuedOperation() throws {
        let (owner, state, process, observation) = try fixture()
        XCTAssertFalse(permits(owner, nil, process, observation))
        var changed = state; changed.guiOwner = nil
        XCTAssertFalse(permits(owner, changed, process, observation))
        changed.guiOwner = GUISessionOwner(bootID: "new-boot", process: process, login: owner.login)
        XCTAssertFalse(permits(owner, changed, process, observation))
    }

    func testV3NativeExecRechecksFixedBatteryReceiptProtectionAndRecoveryDebt() throws {
        let (owner, original, process, observation) = try fixture()
        let permitID = UUID(), sessionID = UUID()
        var state = original; state.userSessionCoordinated = true; state.lidExecutionVersion = 3
        state.workSessionLease = WorkSessionLease(sessionID: sessionID, sequence: 1, power: .battery,
            expiry: 115, reasons: [.manual], manualDeadline: 900, settings: IdleSessionSettings(),
            lidPermit: WorkSessionLidPermit(powerScopes: [.battery], batteryPermitID: permitID,
                batteryDuration: 600, batteryDeadline: 1000))
        func allowed(_ value: HelperState, at now: Double = 100) -> Bool {
            PowerWriterGUIAuthority.permits(arguments: ["-a", "disablesleep", "1"], effectiveUID: 0,
                owner: owner, state: value, process: process, boot: "boot", observation: observation,
                now: now, power: .battery, thermal: 0, fullWake: true, batteryPercent: 80)
        }
        XCTAssertFalse(allowed(state), "An app deadline alone cannot replace the journalled first use")
        state.batteryPermitReceipts = [WorkSessionBatteryPermitReceipt(bootID: "boot", sessionID: sessionID,
            permitID: permitID, observedAt: 100, deadline: 160)]
        XCTAssertTrue(allowed(state))
        var refreshed = state; refreshed.workSessionLease?.expiry = 175
        XCTAssertFalse(allowed(refreshed, at: 160), "A valid fresh health lease cannot extend the first battery receipt")
        var blocked = state
        blocked.lidProtection = WorkSessionProtectionLatch(bootID: "boot", reason: "thermal", observedAt: 101,
            sessionID: sessionID, sequence: 1)
        XCTAssertFalse(allowed(blocked))
        blocked = state; blocked.savedBatteryLowPower = 0
        XCTAssertFalse(allowed(blocked), "Legacy restoration debt blocks new global writers")
        blocked = state
        blocked.lidEndReceipt = WorkSessionEndReceipt(bootID: "boot", sessionID: sessionID, sequence: 1,
            observedAt: 101, kind: .disconnect, action: .sleepIfClosed)
        XCTAssertFalse(allowed(blocked), "A late queued lease cannot bypass the consumed event")
        blocked.workSessionLease?.endConsumptionID = blocked.lidEndReceipt?.id
        blocked.workSessionLease?.sequence = 2
        XCTAssertTrue(allowed(blocked), "A newly accepted higher-sequence grant passes the exec boundary; the helper separately rejects reuse of a consumed manual identity")
    }

    func testApprovedControllerAndAppMustStillMatch() throws {
        let (owner, state, process, observation) = try fixture()
        var changed = state; changed.controllerUID = owner.login.uid + 1
        XCTAssertFalse(permits(owner, changed, process, observation))
        changed = state; changed.appUID = owner.login.uid + 1
        XCTAssertFalse(permits(owner, changed, process, observation))
        changed = state; changed.appPID = process.pid + 1
        XCTAssertFalse(permits(owner, changed, process, observation))
        changed = state; changed.appStarted = process.started - 1
        XCTAssertFalse(permits(owner, changed, process, observation))
        // Additive legacy account approval cannot invent a missing graphical login.
        changed = state; changed.controllerUID = nil
        XCTAssertTrue(permits(owner, changed, process, observation))
        changed.guiOwner = nil
        XCTAssertFalse(permits(owner, changed, process, observation))
    }

    func testNativeExecUsesApprovedFirstBatteryContinuationAndFreshProtectionOptions() throws {
        let (owner, original, process, observation) = try fixture()
        let permitID = UUID(), sessionID = UUID()
        var settings = IdleSessionSettings()
        settings.automaticEnabled = true; settings.automaticPowerCondition = .any
        settings.v4.automaticMode = .advanced
        settings.disconnectPolicy = .continueEligible; settings.stopOnSeriousThermal = false
        var state = original; state.userSessionCoordinated = true; state.lidExecutionVersion = 3
        state.workSessionLease = WorkSessionLease(sessionID: sessionID, sequence: 1, power: .ac,
            expiry: 115, reasons: [.automatic], settings: settings,
            lidPermit: WorkSessionLidPermit(powerScopes: [.ac, .battery], batteryPermitID: permitID,
                batteryDuration: 7200, batteryTimeLimit: .twoHours), automaticRequestID: permitID)
        state.batteryPermitReceipts = [WorkSessionBatteryPermitReceipt(bootID: "boot", sessionID: sessionID,
            permitID: permitID, observedAt: 101, deadline: 7301)]
        func allowed(_ value: HelperState, thermal: Int = 2, lowMode: Bool? = false) -> Bool {
            PowerWriterGUIAuthority.permits(arguments: ["-a", "disablesleep", "1"], effectiveUID: 0,
                owner: owner, state: value, process: process, boot: "boot", observation: observation,
                now: 102, power: .battery, thermal: thermal, fullWake: true, batteryPercent: 80, lowPowerMode: lowMode)
        }
        XCTAssertTrue(allowed(state), "The exec gate must honor the already approved opposite-power scope and threshold")
        XCTAssertFalse(allowed(state, thermal: 3), "Critical pressure is never optional")
        var blocked = state; blocked.workSessionLease?.configuration.disconnectPolicy = .endAll
        XCTAssertFalse(allowed(blocked))
        blocked = state; blocked.batteryPermitReceipts = nil
        XCTAssertFalse(allowed(blocked), "First battery use must be durably anchored before native exec")
        blocked = state; blocked.workSessionLease?.configuration.stopOnLowPowerMode = true
        XCTAssertFalse(allowed(blocked, lowMode: true)); XCTAssertFalse(allowed(blocked, lowMode: nil))
        XCTAssertTrue(allowed(blocked, lowMode: false))
    }

    func testChangedOrUnavailableConsoleAndSessionAreDenied() throws {
        let (owner, state, process, _) = try fixture()
        for observation in [
            GUISessionObservation(login: owner.login, consoleUID: owner.login.uid + 1),
            GUISessionObservation(login: owner.login, consoleUID: nil),
            GUISessionObservation(login: nil, consoleUID: owner.login.uid),
            GUISessionObservation(login: GUISessionIdentity(uid: owner.login.uid, sessionID: 43), consoleUID: owner.login.uid)
        ] { XCTAssertFalse(permits(owner, state, process, observation)) }
    }

    func testExitedReusedOrChangedExecutableControllerIsDenied() throws {
        let (owner, state, process, observation) = try fixture()
        XCTAssertFalse(permits(owner, state, nil, observation))
        var reused = process; reused.started -= 1
        XCTAssertFalse(permits(owner, state, reused, observation))
        reused = process; reused.uid += 1
        XCTAssertFalse(permits(owner, state, reused, observation))
        reused = process; reused.executable = "/usr/bin/true"
        XCTAssertFalse(permits(owner, state, reused, observation))
        XCTAssertFalse(permits(owner, state, process, observation, boot: "new-boot"))
    }

    func testLegacyJournalDecodesWithoutInventingGUIAuthority() throws {
        let (_, _, process, _) = try fixture()
        let record = PowerWriterRecord(boot: "boot", owner: process,
            executable: "/usr/bin/pmset", arguments: ["sleepnow"], deadline: 100)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(PowerWriterRecord.self, from: data)
        XCTAssertEqual(decoded.schema, 1); XCTAssertNil(decoded.guiOwner)
        XCTAssertFalse(permits(decoded.guiOwner, nil, process,
            GUISessionObservation(login: nil, consoleUID: nil)))
    }

    private func folder(_ test: (URL, String, HelperState) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, state, _, _) = try fixture()
        let path = directory.appendingPathComponent("helper-state.json").path
        XCTAssertTrue(JSONFile.write(state, to: path, permissions: 0o600, durable: true))
        try test(directory, path, state)
    }

    func testControllerStateUsesStrictPermissionsOnTheOpenedFile() throws {
        try folder { directory, path, state in
            XCTAssertEqual(PowerWriterGUIAuthority.controllerState(support: directory.path), state)
            XCTAssertNotNil(JSONFile.readBytes(from: path, expectedOwner: geteuid(), expectedPermissions: 0o600))
            XCTAssertNil(JSONFile.readBytes(from: path, expectedOwner: geteuid() + 1, expectedPermissions: 0o600))
            XCTAssertEqual(chmod(path, 0o640), 0)
            XCTAssertNil(PowerWriterGUIAuthority.controllerState(support: directory.path))
            XCTAssertNotNil(JSONFile.readBytes(from: path), "Existing general read contract remains unchanged")
        }
    }

    func testControllerStateRejectsLinksMissingAndInvalidFiles() throws {
        try folder { directory, path, _ in
            let other = directory.appendingPathComponent("other.json").path
            XCTAssertEqual(link(path, other), 0)
            XCTAssertNil(PowerWriterGUIAuthority.controllerState(support: directory.path))
            XCTAssertEqual(unlink(other), 0)
            XCTAssertEqual(rename(path, other), 0)
            XCTAssertEqual(symlink(other, path), 0)
            XCTAssertNil(PowerWriterGUIAuthority.controllerState(support: directory.path))
            XCTAssertEqual(unlink(path), 0)
            XCTAssertNil(PowerWriterGUIAuthority.controllerState(support: directory.path))
            XCTAssertTrue(JSONFile.write(["not": "a state"], to: path, permissions: 0o600))
            // HelperState's optional fields do not fabricate any owner from empty JSON.
            XCTAssertNil(PowerWriterGUIAuthority.controllerState(support: directory.path)?.guiOwner)
            try Data("invalid-json".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertNil(PowerWriterGUIAuthority.controllerState(support: directory.path))
        }
    }

    func testControllerStateRejectsWritableOrLinkedSupportDirectory() throws {
        try folder { directory, _, _ in
            XCTAssertEqual(chmod(directory.path, 0o720), 0)
            XCTAssertNil(PowerWriterGUIAuthority.controllerState(support: directory.path))
            XCTAssertEqual(chmod(directory.path, 0o700), 0)
            let alias = directory.appendingPathComponent("alias").path
            XCTAssertEqual(symlink(directory.path, alias), 0)
            XCTAssertNil(PowerWriterGUIAuthority.controllerState(support: alias))
        }
    }

    func testKnownGUIRejectionBeforeLaunchDoesNotInventAnUnresolvedWriter() throws {
        try folder { directory, _, state in
            let lock = try RecoveryLock.acquire(at: RecoveryLock.path(supportDirectory: directory.path), timeout: 0)
            let identity = try XCTUnwrap(state.guiOwner?.process)
            let invalid = GUISessionOwner(bootID: ContinuousTime.bootID, process: identity,
                login: GUISessionIdentity(uid: identity.uid, sessionID: 0))
            let journal = directory.appendingPathComponent("power-writer.json").path
            let result = try XCTUnwrap(PowerWriterJournal.run("/bin/echo", arguments: ["sleepnow"],
                lock: lock, journalPath: journal, boot: ContinuousTime.bootID,
                gateExecutable: identity.executable, guiOwner: invalid))
            XCTAssertEqual(result.status, 77); XCTAssertTrue(result.terminationConfirmed)
            XCTAssertFalse(result.timedOut); XCTAssertNil(result.processID)
            XCTAssertEqual(PowerWriterJournal.read(journal), .absent)
        }
    }
}
