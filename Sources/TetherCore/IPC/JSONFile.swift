import Foundation

public enum JSONFile {
    public static func read<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Writes a sibling temp file and renames it over the target, so a reader never sees a
    /// partial file. The temp file stays in the same folder, which is the only one the app
    /// is guaranteed to be allowed to write.
    @discardableResult
    public static func write<T: Encodable>(_ value: T, to path: String, permissions: Int) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temp = "\(path).\(getpid()).tmp"
        do {
            try encoder.encode(value).write(to: URL(fileURLWithPath: temp))
        } catch {
            return false
        }
        guard chmod(temp, mode_t(permissions)) == 0, rename(temp, path) == 0 else {
            unlink(temp)
            return false
        }
        return true
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
