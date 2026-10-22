import Foundation

/// JSON files shared by the app (the user) and the helper (root). The folder they live in is
/// root's alone, so nothing can be swapped for a link there; on top of that, nothing here follows
/// a link or trusts a predictable name, because the helper writes as root.
public enum JSONFile {
    /// Larger files are refused: anything readable by root stays small (control, status, usage).
    public static let maxSize = 4 << 20

    public static func read<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        guard let data = readBytes(from: path) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public static func readBytes(from path: String, expectedOwner: uid_t? = nil,
                                 expectedPermissions: mode_t? = nil) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }  // also releases the file lock
        var info = stat()
        guard fstat(fd, &info) == 0,
              (expectedOwner == nil && expectedPermissions == nil) || info.st_nlink == 1,
              expectedOwner.map({ info.st_uid == $0 }) ?? true,
              expectedPermissions.map({ info.st_mode & 0o7777 == $0 }) ?? true,
              lock(fd, exclusive: false), let data = readData(from: fd) else { return nil }
        return data
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(value)
    }

    /// Replaces the file whole, so a reader never sees half of it: a new file with an
    /// unpredictable name in the same folder (`mkstemp`, which never follows a link), its mode set
    /// on the open file, then renamed over the target, which replaces a link rather than
    /// following it. For the helper's own files.
    @discardableResult
    public static func write<T: Encodable>(_ value: T, to path: String, permissions: Int, durable: Bool = false) -> Bool {
        guard let data = encode(value), data.count <= maxSize else { return false }
        return writeBytes(data, to: path, permissions: permissions, durable: durable)
    }

    @discardableResult
    public static func writeBytes(_ data: Data, to path: String, permissions: Int, durable: Bool = false) -> Bool {
        guard data.count <= maxSize else { return false }
        var template = Array("\(path).XXXXXX".utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { return false }
        let temp = String(cString: template)
        let written = fchmod(fd, mode_t(permissions)) == 0 && writeAll(data, to: fd) && (!durable || fsync(fd) == 0)
        close(fd)
        guard written, rename(temp, path) == 0 else {
            unlink(temp)
            return false
        }
        return !durable || syncDirectory(containing: path)
    }

    /// Commit a journal name change before allowing its associated OS command.
    public static func syncDirectory(containing path: String) -> Bool {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return fsync(fd) == 0
    }

    /// Rewrites an existing file in place, keeping its owner and mode: how control.json is
    /// changed, which admins may write but whose folder only root may. Refuses a link, anything
    /// but a plain file, and a file with more than one name (a hard link to something else).
    @discardableResult
    public static func overwrite<T: Encodable>(_ value: T, at path: String) -> Bool {
        guard let data = encode(value), data.count <= maxSize else { return false }
        let fd = open(path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard lock(fd, exclusive: true), isWritableFile(fd) else { return false }
        return replaceContents(data, of: fd)
    }

    /// Holds one exclusive lock across decode, change and write. Readers take a shared lock,
    /// so app/CLI/helper changes cannot overwrite each other or read a truncated intermediate
    /// file. An unreadable or malformed file is left alone, never replaced with defaults.
    /// The closure must only change the value; it must not perform I/O or reenter this store.
    @discardableResult
    public static func update<T: Codable>(_ type: T.Type, at path: String, _ change: (inout T) -> Void) -> Bool {
        let fd = open(path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard lock(fd, exclusive: true), isWritableFile(fd), let data = readData(from: fd),
              var value = try? JSONDecoder().decode(type, from: data) else { return false }
        change(&value)
        guard let updated = encode(value), updated.count <= maxSize else { return false }
        return replaceContents(updated, of: fd)
    }

    private static func isWritableFile(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1
    }

    private static func readData(from fd: Int32) -> Data? {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= maxSize else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: maxSize + 1), data.count <= maxSize else { return nil }
        return data
    }

    private static func replaceContents(_ data: Data, of fd: Int32) -> Bool {
        guard lseek(fd, 0, SEEK_SET) == 0, ftruncate(fd, 0) == 0 else { return false }
        return writeAll(data, to: fd)
    }

    /// A suspended client must not stall the helper's safety checks indefinitely. A busy file
    /// fails after 250 ms; callers retain their last good settings or report that saving failed.
    private static func lock(_ fd: Int32, exclusive: Bool) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        repeat {
            if flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 { return true }
            guard errno == EWOULDBLOCK || errno == EINTR else { return false }
            usleep(2_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return false
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

/// A JSON file polled cheaply: it is decoded again only after it was replaced or changed (inode,
/// size or modification time), which costs one `stat` call per poll.
public final class JSONWatch<T: Decodable & Equatable> {
    public let path: String
    public private(set) var value: T?
    private var stamp: [Int] = []

    public init(_ type: T.Type, path: String) {
        self.path = path
    }

    /// Reads the file again if it changed; true when the decoded value is different.
    @discardableResult
    public func reload() -> Bool {
        var info = stat()
        let current = stat(path, &info) == 0
            ? [Int(truncatingIfNeeded: info.st_ino), Int(info.st_size), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
            : []
        guard current != stamp else { return false }
        // A locked or malformed file is not a new setting. Keep the last good value and retry
        // next poll even if its stat stamp is unchanged (e.g. a suspended writer just resumed).
        let decoded: T?
        if current.isEmpty {
            decoded = nil
        } else {
            guard let loaded = JSONFile.read(T.self, from: path) else { return false }
            decoded = loaded
        }
        stamp = current
        guard decoded != value else { return false }
        value = decoded
        return true
    }
}
