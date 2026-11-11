import Foundation
import TetherCore

/// The support folder's permissions, checked as root at every start.
extension Helper {
    static let knownFiles: Set<String> = ["control.json", "control.json.backup", "status.json", "usage.json", "helper-state.json", "suite-state.json", "protection-state.json", "migration-report.json", "power-ownership.json", "power-writer.json", "watchdog-status.json"]

    /// Only root may add, remove or replace files in the support folder, so nothing in it can be
    /// swapped for a link between two of the helper's steps. Changes now go through the socket.
    /// 2.0.0 made the folder admin-writable, so the folder is taken back, anything that
    /// isn't a known plain file with a single name is removed, and control.json is set to
    /// root:wheel 0644, created if it had to go.
    func secureSupportFolder() {
        guard !dryRun, geteuid() == 0 else { return }
        let folder = URL(fileURLWithPath: statusPath).deletingLastPathComponent().path
        var info = stat()
        guard lstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return }
        // The folder's parent is root's alone, so the path can't be swapped under us.
        if info.st_uid != 0 || info.st_gid != 0 || info.st_mode & 0o7777 != 0o755 {
            chown(folder, 0, 0)
            chmod(folder, 0o755)
            log("support folder made root-only (was \(String(info.st_mode & 0o7777, radix: 8)), owner \(info.st_uid):\(info.st_gid))")
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
            // Keep migration backups and retired-version data for rollback. Only validate
            // files this helper will actually read or write.
            guard Self.knownFiles.contains(name) else { continue }
            let path = folder + "/" + name
            var entry = stat()
            guard lstat(path, &entry) == 0 else { continue }
            let plain = (entry.st_mode & S_IFMT) == S_IFREG && entry.st_nlink == 1
            guard !plain else { continue }
            protection.block("stateUnreadable")
            log("support folder: refused unsafe \(printable(name))")
        }
        secureControlFile(controlPath)
    }

    /// control.json: a plain file writable only by root. Opened without
    /// following links, and changed through the open file.
    func secureControlFile(_ path: String) {
        var fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT {
            fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if fd >= 0 {
                let empty = Data("{\n  \"enabled\" : true\n}\n".utf8)
                _ = empty.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                log("support folder: created control.json")
            }
        }
        guard fd >= 0 else {
            log("warning: control.json can't be opened (\(String(cString: strerror(errno))))")
            return
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { return }
        if info.st_uid != 0 || info.st_gid != 0 { fchown(fd, 0, 0) }
        if info.st_mode & 0o7777 != 0o644 { fchmod(fd, 0o644) }
    }

    /// A name or path from a file somebody else can write, safe to put in the log on one line.
    func printable(_ text: String) -> String {
        String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "?" : Character($0) })
    }
}
