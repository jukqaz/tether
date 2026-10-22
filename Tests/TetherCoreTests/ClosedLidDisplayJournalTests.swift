import Darwin
import Foundation
import XCTest
@testable import TetherCore

final class ClosedLidDisplayJournalTests: XCTestCase {
    private let target = ClosedLidDisplayTarget(id: 121, vendor: 343, model: 565)

    private func fixture(_ body: (URL, FileClosedLidDisplayRecoveryJournal) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-display-journal-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = FileClosedLidDisplayRecoveryJournal(url: folder.appendingPathComponent("display-recovery.json"))
        try body(folder, journal)
    }

    func testDurableRoundTripUsesPrivateFileAndRemovesOnlyAfterReadableRecoveryRecord() throws {
        try fixture { _, journal in
            XCTAssertNil(try journal.load())
            XCTAssertNoThrow(try journal.remove())
            var record = ClosedLidDisplayRecoveryRecord(target: target, original: 0.65)
            try journal.save(record)
            XCTAssertEqual(try journal.load(), record)
            var info = stat()
            XCTAssertEqual(lstat(journal.url.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o7777, 0o600)
            XCTAssertEqual(info.st_uid, getuid())
            XCTAssertEqual(info.st_nlink, 1)
            record.phase = .applied
            try journal.save(record)
            XCTAssertEqual(try journal.load(), record)
            record.phase = .restoring
            try journal.save(record)
            XCTAssertEqual(try journal.load()?.original, 0.65)
            try journal.remove()
            XCTAssertNil(try journal.load())
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path))
            XCTAssertNoThrow(try journal.remove(), "A second completed cleanup is idempotent")
        }
    }

    func testNewRecoveryDirectoryIsPrivateAndInvalidRecordCannotReplaceOriginal() throws {
        try fixture { folder, _ in
            let url = folder.appendingPathComponent("new-support/Tether/display-recovery.json")
            let journal = FileClosedLidDisplayRecoveryJournal(url: url)
            let record = ClosedLidDisplayRecoveryRecord(target: target, original: 0.8)
            try journal.save(record)
            var info = stat()
            XCTAssertEqual(lstat(url.deletingLastPathComponent().path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o7777, 0o700)
            let original = try Data(contentsOf: url)
            var invalid = record; invalid.version = 99
            XCTAssertThrowsError(try journal.save(invalid))
            invalid = record; invalid.original = .nan
            XCTAssertThrowsError(try journal.save(invalid))
            invalid = record; invalid.applied = 0.2
            XCTAssertThrowsError(try journal.save(invalid))
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(try journal.load(), record)
        }
    }

    func testCorruptAndFutureSchemaRecordsArePreservedByReadAndCleanupFailures() throws {
        try fixture { _, journal in
            var future = ClosedLidDisplayRecoveryRecord(target: target, original: 0.8)
            future.version = 99
            for bytes in [Data("{corrupt".utf8), try JSONEncoder().encode(future)] {
                XCTAssertTrue(JSONFile.writeBytes(bytes, to: journal.url.path, permissions: 0o600, durable: true))
                XCTAssertThrowsError(try journal.load())
                XCTAssertThrowsError(try journal.remove())
                XCTAssertEqual(try Data(contentsOf: journal.url), bytes)
            }
        }
    }

    func testUnexpectedSymlinkAndHardlinkCannotBeLoadedOrDeleted() throws {
        for kind in ["symlink", "hardlink"] {
            try fixture { folder, journal in
                let record = ClosedLidDisplayRecoveryRecord(target: target, original: 0.75)
                let original = folder.appendingPathComponent("original.json")
                XCTAssertTrue(JSONFile.write(record, to: original.path, permissions: 0o600, durable: true))
                let bytes = try Data(contentsOf: original)
                if kind == "symlink" {
                    XCTAssertEqual(symlink(original.path, journal.url.path), 0)
                } else {
                    XCTAssertEqual(link(original.path, journal.url.path), 0)
                }
                XCTAssertThrowsError(try journal.load(), kind)
                XCTAssertThrowsError(try journal.remove(), kind)
                var info = stat()
                XCTAssertEqual(lstat(journal.url.path, &info), 0, "Unexpected replacement must remain intact: \(kind)")
                XCTAssertEqual(try Data(contentsOf: original), bytes)
            }
        }
    }

    func testUnsafeOrSymlinkedImmediateDirectoryCannotReceiveRecoveryWrites() throws {
        for kind in ["writable", "symlink"] {
            try fixture { folder, _ in
                let support = folder.appendingPathComponent("support", isDirectory: true)
                if kind == "writable" {
                    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
                    XCTAssertEqual(chmod(support.path, 0o777), 0)
                } else {
                    let destination = folder.appendingPathComponent("destination", isDirectory: true)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    XCTAssertEqual(symlink(destination.path, support.path), 0)
                }
                let journal = FileClosedLidDisplayRecoveryJournal(url: support.appendingPathComponent("recovery.json"))
                XCTAssertThrowsError(try journal.save(.init(target: target, original: 0.8)), kind)
                XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path))
                if kind == "writable" {
                    var info = stat(); XCTAssertEqual(lstat(support.path, &info), 0)
                    XCTAssertEqual(info.st_mode & 0o7777, 0o777, "Refusal cannot silently rewrite unrelated directory permissions")
                }
            }
        }
    }

    func testUnexpectedPublicFilePermissionsAreNotSilentlyRepairedOrRemoved() throws {
        try fixture { _, journal in
            let record = ClosedLidDisplayRecoveryRecord(target: target, original: 0.9)
            try journal.save(record)
            let original = try Data(contentsOf: journal.url)
            XCTAssertEqual(chmod(journal.url.path, 0o644), 0)
            XCTAssertThrowsError(try journal.load())
            XCTAssertThrowsError(try journal.remove())
            XCTAssertEqual(try Data(contentsOf: journal.url), original)
            var info = stat(); XCTAssertEqual(lstat(journal.url.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o7777, 0o644)
        }
    }
}
