import Darwin
import XCTest
@testable import TetherCore

final class AppCoordinatorLeaseTests: XCTestCase {
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("tether-app-lease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    func testASecondWriterCannotReplaceTheOwnerAndNormalReleaseKeepsTheSameLockFile() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("instance.lock").path
        var first: AppCoordinatorLease? = try AppCoordinatorLease.acquire(at: path)
        XCTAssertTrue(first?.isValid == true)
        var before = stat(); XCTAssertEqual(lstat(path, &before), 0)
        XCTAssertThrowsError(try AppCoordinatorLease.acquire(at: path)) { error in
            guard case AppCoordinatorFailure.alreadyRunning = error else { return XCTFail("Expected the live writer to win") }
        }
        XCTAssertTrue(first?.isValid == true)
        first = nil
        let next = try AppCoordinatorLease.acquire(at: path)
        var after = stat(); XCTAssertEqual(lstat(path, &after), 0)
        XCTAssertEqual(before.st_dev, after.st_dev); XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertTrue(next.isValid)
    }
    func testSymlinkHardlinkAndPublicLockPermissionsAreRejectedWithoutOverwritingTheirData() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("instance.lock").path
        let original = directory.appendingPathComponent("original")
        let bytes = Data("retained".utf8)
        try bytes.write(to: original); XCTAssertEqual(chmod(original.path, 0o600), 0)
        XCTAssertEqual(symlink(original.path, path), 0)
        XCTAssertThrowsError(try AppCoordinatorLease.acquire(at: path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(unlink(path), 0); XCTAssertEqual(link(original.path, path), 0)
        XCTAssertThrowsError(try AppCoordinatorLease.acquire(at: path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(unlink(path), 0); try bytes.write(to: URL(fileURLWithPath: path)); XCTAssertEqual(chmod(path, 0o644), 0)
        XCTAssertThrowsError(try AppCoordinatorLease.acquire(at: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
    }
    func testUnverifiedOrLinkedDirectoriesAreRejected() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
        XCTAssertThrowsError(try AppCoordinatorLease.acquire(at: directory.appendingPathComponent("instance.lock").path))
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        let shortcut = directory.appendingPathComponent("shortcut")
        XCTAssertEqual(symlink(directory.path, shortcut.path), 0)
        XCTAssertThrowsError(try AppCoordinatorLease.acquire(at: shortcut.appendingPathComponent("instance.lock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("instance.lock").path))
    }
    func testReplacementOrPermissionChangeRevokesTheOldLease() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("instance.lock").path
        let subject = try AppCoordinatorLease.acquire(at: path)
        XCTAssertEqual(chmod(path, 0o644), 0); XCTAssertFalse(subject.isValid)
        XCTAssertEqual(chmod(path, 0o600), 0); XCTAssertTrue(subject.isValid)
        XCTAssertEqual(rename(path, directory.appendingPathComponent("previous.lock").path), 0)
        let replacement = try AppCoordinatorLease.acquire(at: path)
        XCTAssertFalse(subject.isValid); XCTAssertTrue(replacement.isValid)
    }
    func testRealChildHoldsTheKernelLockAndItsCrashReleasesItWithoutDeletingTheFile() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/TetherWriterFixture")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let child = Process(); child.executableURL = executable
        child.arguments = ["--app-coordinator-lock", directory.path]
        let input = Pipe(), output = Pipe(), error = Pipe()
        child.standardInput = input; child.standardOutput = output; child.standardError = error
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let ready = try XCTUnwrap(output.fileHandleForReading.read(upToCount: 6))
        XCTAssertEqual(String(decoding: ready, as: UTF8.self), "ready\n")
        let path = directory.appendingPathComponent("instance.lock").path
        var before = stat(); XCTAssertEqual(lstat(path, &before), 0)
        XCTAssertThrowsError(try AppCoordinatorLease.acquire(at: path))
        let identity = try XCTUnwrap(ProcessIdentity.capture(pid: child.processIdentifier))
        XCTAssertTrue(child.isRunning)
        XCTAssertTrue(identity.matchesLifetime(try XCTUnwrap(ProcessIdentity.capture(pid: child.processIdentifier))))
        XCTAssertEqual(kill(child.processIdentifier, SIGKILL), 0)
        child.waitUntilExit()
        var after = stat(); XCTAssertEqual(lstat(path, &after), 0)
        XCTAssertEqual(before.st_dev, after.st_dev); XCTAssertEqual(before.st_ino, after.st_ino)
        let next = try AppCoordinatorLease.acquire(at: path)
        XCTAssertTrue(next.isValid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
