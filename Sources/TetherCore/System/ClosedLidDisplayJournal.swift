import Foundation
import Darwin

/// Per-user recovery record. Failure/corruption stays visible and is never
/// replaced with a guessed original. No native brightness calls occur here.
public final class FileClosedLidDisplayRecoveryJournal: ClosedLidDisplayRecoveryJournaling {
    public enum Failure: Error { case unavailable, invalidRecord }
    public let url: URL
    public init(url: URL) { self.url = url }
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether", isDirectory: true)
            .appendingPathComponent("closed-lid-display-recovery.json")
    }
    public func load() throws -> ClosedLidDisplayRecoveryRecord? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw Failure.unavailable
        }
        guard let bytes = JSONFile.readBytes(from: url.path, expectedOwner: getuid(), expectedPermissions: 0o600),
              let record = try? JSONDecoder().decode(ClosedLidDisplayRecoveryRecord.self, from: bytes),
              record.isValid else { throw Failure.invalidRecord }
        return record
    }
    public func save(_ record: ClosedLidDisplayRecoveryRecord) throws {
        guard record.isValid else { throw Failure.invalidRecord }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0,
              JSONFile.write(record, to: url.path, permissions: 0o600, durable: true) else {
            throw Failure.unavailable
        }
    }
    public func remove() throws {
        // Refuse an unexpected replacement instead of unlinking somebody else's
        // file. A failed directory fsync remains an explicit recovery debt.
        if try load() == nil { return }
        guard unlink(url.path) == 0, JSONFile.syncDirectory(containing: url.path) else { throw Failure.unavailable }
    }
}
