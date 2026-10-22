import Darwin
import Foundation

/// One stable inode for Tether's OS writes and recovery. Never store data here, rename it,
/// or unlink it during an upgrade/removal: the ownership journal is a separate file.
public final class RecoveryLock {
    public enum Failure: Error, Equatable {
        case unsafePath
        case unavailable(Int32)
        case busy
        case invalidTimeout
    }

    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    /// Only a direct power writer gets a duplicate through stdin. Other subprocesses
    /// retain CLOEXEC. The duplicate keeps the same flock alive if the coordinator dies.
    public func childInput() throws -> FileHandle {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        guard copy >= 0 else { throw Failure.unavailable(errno) }
        return FileHandle(fileDescriptor: copy, closeOnDealloc: true)
    }

    /// Shell recovery passes its already-locked FD 9 as stdin to the private CLI.
    public static func adoptingInput(at path: String) throws -> RecoveryLock {
        var input = stat(), entry = stat()
        guard fstat(STDIN_FILENO, &input) == 0, lstat(path, &entry) == 0,
              safe(input), safe(entry), input.st_dev == entry.st_dev, input.st_ino == entry.st_ino else {
            throw Failure.unsafePath
        }
        let copy = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3)
        guard copy >= 0 else { throw Failure.unavailable(errno) }
        guard flock(copy, LOCK_EX | LOCK_NB) == 0 else { close(copy); throw Failure.busy }
        return RecoveryLock(descriptor: copy)
    }

    public static func path(supportDirectory: String) -> String {
        let support = URL(fileURLWithPath: supportDirectory).standardizedFileURL
        let parent = support.deletingLastPathComponent()
        if support.lastPathComponent == "Tether", parent.lastPathComponent == "Application Support" {
            return parent.appendingPathComponent(".tether-power-recovery.lock").path
        }
        // Isolated fixtures must not share a production/global temporary lock.
        return support.appendingPathComponent("recovery.lock").path
    }

    public static func acquire(at path: String, timeout: TimeInterval = 0.25) throws -> RecoveryLock {
        guard timeout.isFinite, timeout >= 0, timeout <= 5 else { throw Failure.invalidTimeout }
        let url = URL(fileURLWithPath: path)
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.unsafePath }
        defer { close(parent) }
        var directory = stat()
        guard fstat(parent, &directory) == 0, directory.st_uid == geteuid(),
              directory.st_mode & 0o022 == 0 else { throw Failure.unsafePath }
        let fd = openat(parent, url.lastPathComponent, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable(errno) }
        var acquired = false
        defer { if !acquired { close(fd) } }
        var opened = stat()
        guard fstat(fd, &opened) == 0, safe(opened) else { throw Failure.unsafePath }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else { throw Failure.unavailable(code) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.busy }
            usleep(5_000)
        }
        var entry = stat()
        guard fstatat(parent, url.lastPathComponent, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              safe(entry), entry.st_dev == opened.st_dev, entry.st_ino == opened.st_ino else {
            throw Failure.unsafePath
        }
        acquired = true
        return RecoveryLock(descriptor: fd)
    }

    private static func safe(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_nlink == 1 &&
        value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o600
    }
}
