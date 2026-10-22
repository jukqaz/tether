import Darwin
import XCTest
@testable import TetherCore

final class PowerWriterJournalTests: XCTestCase {
    private func fixture(_ body: (URL, RecoveryLock, String) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tether-writer-unit-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let lock = try RecoveryLock.acquire(at: RecoveryLock.path(supportDirectory: folder.path))
        try body(folder, lock, folder.appendingPathComponent("power-writer.json").path)
    }

    private func record(_ path: String, pid: Int32? = nil, deadline: Double = ContinuousTime.now + 5) throws -> PowerWriterRecord {
        var record = PowerWriterRecord(boot: ContinuousTime.bootID,
            owner: try XCTUnwrap(ProcessIdentity.capture(pid: getpid())),
            executable: "/bin/sleep", arguments: ["10"], deadline: deadline)
        if let pid { record.writerPID = pid; record.writer = try XCTUnwrap(ProcessIdentity.capture(pid: pid)); record.phase = .running }
        XCTAssertTrue(JSONFile.write(record, to: path, permissions: 0o600, durable: true))
        return record
    }

    private func child(_ body: (Process) throws -> Void) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["10"]
        try process.run()
        defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() }
        try body(process)
    }

    func testPreparedRecordIsDurableBeforeRegistrationAndIntentIsPreserved() throws {
        try fixture { _, lock, path in
            let result = PowerWriterJournal.run("/bin/sleep", arguments: ["0.02"], lock: lock,
                journalPath: path, boot: ContinuousTime.bootID, timeout: 1,
                intentEpoch: "epoch-7", intentRevision: 42, beforeRegistration: { pid in
                    guard case .record(let saved) = PowerWriterJournal.read(path) else { return XCTFail("Missing prepared journal") }
                    XCTAssertEqual(saved.phase, .prepared); XCTAssertNil(saved.writerPID)
                    XCTAssertEqual(saved.owner.pid, getpid()); XCTAssertEqual(saved.intentEpoch, "epoch-7")
                    XCTAssertEqual(saved.intentRevision, 42); XCTAssertTrue(saved.inheritsRecoveryLock)
                    XCTAssertNotNil(ProcessIdentity.capture(pid: pid))
                })
            XCTAssertEqual(result?.status, 0); XCTAssertEqual(result?.terminationConfirmed, true)
            XCTAssertEqual(PowerWriterJournal.read(path), .absent)
        }
    }

    func testIgnoringTermHasNoLateEffectAndIsClearedOnlyAfterObservedExit() throws {
        try fixture { folder, lock, path in
            let late = folder.appendingPathComponent("late-write")
            let writer = "$SIG{TERM}='IGNORE'; $|=1; print 'ready'; select undef,undef,undef,1; open(my $f,'>', $ARGV[0]) or die $!; print $f 'late';"
            let result = try XCTUnwrap(PowerWriterJournal.run("/usr/bin/perl", arguments: ["-e", writer, late.path],
                lock: lock, journalPath: path, boot: ContinuousTime.bootID, timeout: 0.1))
            XCTAssertTrue(result.output.hasPrefix("ready")); XCTAssertEqual(result.status, 124)
            XCTAssertEqual(result.exitStatus, SIGKILL); XCTAssertTrue(result.terminationConfirmed)
            XCTAssertTrue(ProcessIdentity.exited(pid: result.processID!)); XCTAssertEqual(PowerWriterJournal.read(path), .absent)
            usleep(1_100_000)
            XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
        }
    }

    func testUnexpiredWriterIsNotStoppedAndExpiredWriterIsObservedBeforeClear() throws {
        try fixture { _, _, path in
            try child { process in
                let saved = try record(path, pid: process.processIdentifier)
                XCTAssertEqual(PowerWriterJournal.resolve(path, boot: saved.boot, expectedExecutable: "/bin/sleep", stopExpired: true), .active)
                XCTAssertTrue(process.isRunning)
                XCTAssertFalse(PowerWriterJournal.clearResolved(path, boot: saved.boot, expectedExecutable: "/bin/sleep"))
                XCTAssertEqual(PowerWriterJournal.resolve(path, boot: saved.boot, expectedExecutable: "/bin/sleep", stopExpired: true, now: saved.deadline + 1), .resolved)
                XCTAssertTrue(ProcessIdentity.exited(pid: process.processIdentifier))
                XCTAssertTrue(PowerWriterJournal.clearResolved(path, boot: saved.boot, expectedExecutable: "/bin/sleep"))
            }
        }
    }

    func testReusedPIDIsNeverSignalled() throws {
        try fixture { _, _, path in
            try child { process in
                var saved = try record(path, pid: process.processIdentifier, deadline: ContinuousTime.now - 1)
                saved.writer!.started -= 1
                XCTAssertTrue(JSONFile.write(saved, to: path, permissions: 0o600, durable: true))
                XCTAssertEqual(PowerWriterJournal.resolve(path, boot: saved.boot, expectedExecutable: "/bin/sleep", stopExpired: true), .resolved)
                XCTAssertTrue(process.isRunning)
            }
        }
    }

    func testWrongExecutableAndMissingIdentityKeepLiveWriterAndJournal() throws {
        try fixture { _, _, path in
            try child { process in
                var saved = try record(path, pid: process.processIdentifier, deadline: ContinuousTime.now - 1)
                saved.executable = "/usr/bin/pmset"
                XCTAssertTrue(JSONFile.write(saved, to: path, permissions: 0o600, durable: true))
                XCTAssertEqual(PowerWriterJournal.resolve(path, boot: saved.boot, expectedExecutable: "/usr/bin/pmset", stopExpired: true), .unresolved)
                saved.executable = "/bin/sleep"; saved.writer = nil
                XCTAssertTrue(JSONFile.write(saved, to: path, permissions: 0o600, durable: true))
                XCTAssertEqual(PowerWriterJournal.resolve(path, boot: saved.boot, expectedExecutable: "/bin/sleep", stopExpired: true), .unresolved)
                XCTAssertFalse(PowerWriterJournal.clearResolved(path, boot: saved.boot, expectedExecutable: "/bin/sleep"))
                XCTAssertTrue(process.isRunning)
            }
        }
    }

    func testOldBootDoesNotStopCurrentProcess() throws {
        try fixture { _, _, path in
            try child { process in
                var saved = try record(path, pid: process.processIdentifier, deadline: ContinuousTime.now - 1)
                saved.boot = "previous-boot"
                XCTAssertTrue(JSONFile.write(saved, to: path, permissions: 0o600, durable: true))
                XCTAssertTrue(PowerWriterJournal.clearResolved(path, boot: ContinuousTime.bootID, expectedExecutable: "/bin/sleep"))
                XCTAssertTrue(process.isRunning)
            }
        }
    }

    func testOldCompletionCannotDeleteOrOverwriteNewTransaction() throws {
        try fixture { _, lock, path in
            var next: PowerWriterRecord?
            let result = PowerWriterJournal.run("/bin/sleep", arguments: ["10"], lock: lock,
                journalPath: path, boot: ContinuousTime.bootID, timeout: 0.05, beforeRegistration: { _ in
                    next = try? self.record(path)
                })
            XCTAssertNil(result)
            XCTAssertEqual(PowerWriterJournal.read(path), .record(try XCTUnwrap(next)))
        }
    }

    func testUnresolvedRecordPreventsStartingAnotherWriter() throws {
        try fixture { folder, lock, path in
            var saved = try record(path); saved.phase = .writerUnresolved
            XCTAssertTrue(JSONFile.write(saved, to: path, permissions: 0o600, durable: true))
            let marker = folder.appendingPathComponent("unexpected")
            XCTAssertNil(PowerWriterJournal.run("/usr/bin/touch", arguments: [marker.path], lock: lock,
                journalPath: path, boot: saved.boot))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path)); XCTAssertEqual(PowerWriterJournal.read(path), .record(saved))
        }
    }

    func testUnsafeMalformedAndFutureSchemaRecordsAreRetained() throws {
        try fixture { folder, lock, path in
            for kind in ["permissions", "schema", "malformed", "symlink", "hardlink"] {
                try? FileManager.default.removeItem(atPath: path)
                var saved = try record(path)
                switch kind {
                case "permissions": XCTAssertEqual(chmod(path, 0o644), 0)
                case "schema": saved.schema = 99; XCTAssertTrue(JSONFile.write(saved, to: path, permissions: 0o600))
                case "malformed": XCTAssertTrue(JSONFile.writeBytes(Data("{".utf8), to: path, permissions: 0o600))
                case "symlink": try FileManager.default.moveItem(atPath: path, toPath: folder.appendingPathComponent("target").path); XCTAssertEqual(symlink(folder.appendingPathComponent("target").path, path), 0)
                default: XCTAssertEqual(link(path, folder.appendingPathComponent("hardlink").path), 0)
                }
                XCTAssertEqual(PowerWriterJournal.read(path), .unsafe, kind)
                XCTAssertFalse(PowerWriterJournal.clearResolved(path, boot: saved.boot, expectedExecutable: "/bin/sleep"), kind)
                XCTAssertNil(PowerWriterJournal.run("/bin/sleep", arguments: ["0"], lock: lock, journalPath: path, boot: saved.boot), kind)
                XCTAssertTrue(FileManager.default.fileExists(atPath: path), kind)
            }
        }
    }

    func testInvalidTimeoutAndUnknownBootDoNotStartWriterOrCreateJournal() throws {
        try fixture { _, lock, path in
            for timeout in [Double.nan, .infinity, 0, -1, 11] {
                XCTAssertNil(PowerWriterJournal.run("/bin/sleep", arguments: ["0"], lock: lock, journalPath: path, boot: ContinuousTime.bootID, timeout: timeout))
                XCTAssertEqual(PowerWriterJournal.read(path), .absent)
            }
            XCTAssertNil(PowerWriterJournal.run("/bin/sleep", arguments: ["0"], lock: lock, journalPath: path, boot: "unknown"))
            XCTAssertEqual(PowerWriterJournal.read(path), .absent)
        }
    }

    func testLegacyRecordRemainsReadableAndForeignGateMetadataIsRejected() throws {
        try fixture { _, _, path in
            var saved = try record(path)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
            XCTAssertNil(encoded["gateExecutable"])
            XCTAssertEqual(PowerWriterJournal.read(path), .record(saved))
            saved.gateExecutable = saved.owner.executable
            XCTAssertTrue(JSONFile.write(saved, to: path, permissions: 0o600, durable: true))
            XCTAssertEqual(PowerWriterJournal.read(path), .record(saved))
            saved.gateExecutable = "/usr/bin/true"
            XCTAssertTrue(JSONFile.write(saved, to: path, permissions: 0o600, durable: true))
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertEqual(PowerWriterJournal.read(path), .unsafe)
            XCTAssertEqual(PowerWriterJournal.resolve(path, boot: saved.boot, expectedExecutable: saved.executable, stopExpired: true), .unresolved)
            XCTAssertFalse(PowerWriterJournal.clearResolved(path, boot: saved.boot, expectedExecutable: saved.executable))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        }
    }

    func testGateCannotSelectAProgramOtherThanItsCoordinator() throws {
        try fixture { folder, lock, path in
            XCTAssertNil(PowerWriterJournal.run("/bin/sleep", arguments: ["0"], lock: lock,
                journalPath: path, boot: ContinuousTime.bootID, gateExecutable: "/usr/bin/true"))
            XCTAssertEqual(PowerWriterJournal.read(path), .absent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("unexpected").path))
        }
    }
}
