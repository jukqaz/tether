import Foundation

/// JSON files shared by the app (the user) and the helper (root). The folder they live in is
/// root's alone, so nothing can be swapped for a link there; on top of that, nothing here follows
/// a link or trusts a predictable name, because the helper writes as root.
public enum JSONFile {
    /// Larger files are refused: anything readable by root stays small (control, status, usage).
    public static let maxSize = 4 << 20

    public static func read<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxSize + 1), data.count <= maxSize else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
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
    public static func write<T: Encodable>(_ value: T, to path: String, permissions: Int) -> Bool {
        guard let data = encode(value) else { return false }
        var template = Array("\(path).XXXXXX".utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { return false }
        let temp = String(cString: template)
        let written = fchmod(fd, mode_t(permissions)) == 0 && writeAll(data, to: fd)
        close(fd)
        guard written, rename(temp, path) == 0 else {
            unlink(temp)
            return false
        }
        return true
    }

    /// Rewrites an existing file in place, keeping its owner and mode: how control.json is
    /// changed, which admins may write but whose folder only root may. Refuses a link, anything
    /// but a plain file, and a file with more than one name (a hard link to something else).
    @discardableResult
    public static func overwrite<T: Encodable>(_ value: T, at path: String) -> Bool {
        guard let data = encode(value) else { return false }
        let fd = open(path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              ftruncate(fd, 0) == 0 else { return false }
        return writeAll(data, to: fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
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
        stamp = current
        let decoded = current.isEmpty ? nil : JSONFile.read(T.self, from: path)
        guard decoded != value else { return false }
        value = decoded
        return true
    }
}
