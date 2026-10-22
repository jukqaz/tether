import Darwin
import Foundation

/// Root's app-retirement cleanup traverses user-writable home directories. Pin every
/// directory without following links, then inspect and unlink only the fixed leaf.
public enum AppResidueCleanup {
    static let maximumPlistSize = 64 << 10

    @discardableResult
    public static func removeCLI(at path: String) -> Bool {
        guard let parent = openParent(of: path) else { return false }
        defer { close(parent.descriptor) }
        return removeCLI(named: parent.name, from: parent.descriptor)
    }

    @discardableResult
    public static func removeLoginItem(at path: String, appPath: String) -> Bool {
        guard let parent = openParent(of: path) else { return false }
        defer { close(parent.descriptor) }
        return removeLoginItem(named: parent.name, from: parent.descriptor, appPath: appPath)
    }

    /// Do not standardize or resolve the path: every component must itself be a directory.
    /// Home directories may belong to their users; root ownership is not required here.
    static func openParent(of path: String) -> (descriptor: Int32, name: String)? {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\0") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        for component in components.dropLast() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }
        return (descriptor, name)
    }

    static func removeCLI(named name: String, from parent: Int32) -> Bool {
        guard name == "tether" else { return false }
        var entry = stat()
        guard fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              entry.st_mode & S_IFMT == S_IFLNK else { return false }
        let capacity = Int(PATH_MAX) + 1
        var bytes = [CChar](repeating: 0, count: capacity)
        let count = readlinkat(parent, name, &bytes, capacity)
        guard count > 0, count < capacity,
              let target = String(bytes: bytes.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8),
              target.hasSuffix("Tether.app/Contents/Helpers/tether"),
              sameEntry(entry, named: name, from: parent) else { return false }
        return unlinkat(parent, name, 0) == 0
    }

    static func removeLoginItem(named name: String, from parent: Int32, appPath: String) -> Bool {
        guard name == "local.tether.app.plist" else { return false }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var entry = stat()
        guard fstat(descriptor, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG,
              entry.st_nlink == 1, entry.st_size >= 0, entry.st_size <= maximumPlistSize,
              let data = readPlist(from: descriptor),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              (plist["ProgramArguments"] as? [String])?.first == appPath,
              sameEntry(entry, named: name, from: parent) else { return false }
        // No AT_REMOVEDIR and no recursive deletion, even if the leaf changes after inspection.
        return unlinkat(parent, name, 0) == 0
    }

    private static func readPlist(from descriptor: Int32) -> Data? {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while data.count <= maximumPlistSize {
            let count = Darwin.read(descriptor, &bytes, min(bytes.count, maximumPlistSize + 1 - data.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
        }
        return nil
    }

    private static func sameEntry(_ original: stat, named name: String, from parent: Int32) -> Bool {
        var current = stat()
        return fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
            current.st_dev == original.st_dev && current.st_ino == original.st_ino &&
            current.st_mode & S_IFMT == original.st_mode & S_IFMT && current.st_nlink == original.st_nlink
    }
}
