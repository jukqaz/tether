import Darwin
import XCTest
@testable import TetherCore

final class RecoveryLockTests: XCTestCase {
    private func fixture(_ body: (URL, String) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tether-lock-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder, RecoveryLock.path(supportDirectory: folder.path))
    }

    func testProductionLockSurvivesSupportDirectoryRemoval() throws {
        try fixture { folder, _ in
            let support = folder.appendingPathComponent("Application Support/Tether")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let path = RecoveryLock.path(supportDirectory: support.path)
            XCTAssertEqual(path, support.deletingLastPathComponent().appendingPathComponent(".tether-power-recovery.lock").path)
            let lock = try RecoveryLock.acquire(at: path)
            try FileManager.default.removeItem(at: support)
            XCTAssertThrowsError(try RecoveryLock.acquire(at: path, timeout: 0)) { XCTAssertEqual($0 as? RecoveryLock.Failure, .busy) }
            withExtendedLifetime(lock) {}
        }
    }

    func testJournalAtomicReplacementCannotSplitLock() throws {
        try fixture { folder, path in
            let lock = try RecoveryLock.acquire(at: path)
            let journal = folder.appendingPathComponent("power-ownership.json").path
            for value in 0..<8 {
                XCTAssertTrue(JSONFile.write(["generation": value], to: journal, permissions: 0o600))
                XCTAssertThrowsError(try RecoveryLock.acquire(at: path, timeout: 0)) { XCTAssertEqual($0 as? RecoveryLock.Failure, .busy) }
            }
            withExtendedLifetime(lock) {}
        }
    }

    func testReleaseAllowsNextTransactionOnSameInode() throws {
        try fixture { _, path in
            var lock: RecoveryLock? = try RecoveryLock.acquire(at: path)
            var before = stat(); XCTAssertEqual(lstat(path, &before), 0)
            XCTAssertNotNil(lock); lock = nil
            let next = try RecoveryLock.acquire(at: path, timeout: 0)
            var after = stat(); XCTAssertEqual(lstat(path, &after), 0)
            XCTAssertEqual(before.st_ino, after.st_ino)
            withExtendedLifetime(next) {}
        }
    }

    func testBusyWaitIsBounded() throws {
        try fixture { _, path in
            let lock = try RecoveryLock.acquire(at: path)
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try RecoveryLock.acquire(at: path, timeout: 0.03)) { XCTAssertEqual($0 as? RecoveryLock.Failure, .busy) }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.3)
            withExtendedLifetime(lock) {}
        }
    }

    func testUnsafeLinkHardLinkDirectoryAndPermissionsAreRefused() throws {
        for kind in ["symlink", "hardlink", "directory", "permissions"] {
            try fixture { folder, path in
                let target = folder.appendingPathComponent("target").path
                XCTAssertTrue(JSONFile.write(["untouched": true], to: target, permissions: 0o600))
                switch kind {
                case "symlink": XCTAssertEqual(symlink(target, path), 0)
                case "hardlink": XCTAssertEqual(link(target, path), 0)
                case "directory": try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
                default: FileManager.default.createFile(atPath: path, contents: nil); XCTAssertEqual(chmod(path, 0o666), 0)
                }
                XCTAssertThrowsError(try RecoveryLock.acquire(at: path, timeout: 0), kind)
                XCTAssertEqual(JSONFile.read([String: Bool].self, from: target), ["untouched": true])
            }
        }
    }

    func testWritableParentAndParentSymlinkAreRefused() throws {
        try fixture { folder, path in
            XCTAssertEqual(chmod(folder.path, 0o777), 0)
            XCTAssertThrowsError(try RecoveryLock.acquire(at: path))
            XCTAssertEqual(chmod(folder.path, 0o700), 0)
            let alias = folder.appendingPathComponent("alias").path
            XCTAssertEqual(symlink(folder.path, alias), 0)
            XCTAssertThrowsError(try RecoveryLock.acquire(at: alias + "/other.lock"))
        }
    }

    func testInvalidTimeoutNeverCreatesLock() throws {
        try fixture { _, path in
            for timeout in [Double.nan, .infinity, -1, 6] {
                XCTAssertThrowsError(try RecoveryLock.acquire(at: path, timeout: timeout)) { XCTAssertEqual($0 as? RecoveryLock.Failure, .invalidTimeout) }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testNativeLockExcludesShellRecoveryLock() throws {
        try fixture { folder, path in
            let lock = try RecoveryLock.acquire(at: path)
            let library = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/tether-recovery-lock.sh").path
            let result = Shell.run("/bin/sh", ["-c", ". \"$1\"; recovery_lock_path \"$2\"; recovery_lock_acquire 0", "test", library, folder.path])
            XCTAssertEqual(result.status, 75, result.output)
            withExtendedLifetime(lock) {}
        }
    }

    func testLockNotInheritedByUnrelatedExecutedChild() throws {
        try fixture { _, path in
            var lock: RecoveryLock? = try RecoveryLock.acquire(at: path)
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["5"]
            try child.run()
            defer { child.terminate(); child.waitUntilExit() }
            XCTAssertNotNil(lock); lock = nil
            let next = try RecoveryLock.acquire(at: path, timeout: 0)
            withExtendedLifetime(next) {}
        }
    }
}
