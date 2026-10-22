import Foundation

/// Copy-before-truncate preserves launchd's open stdout/stderr inode. Renaming the active
/// log would leave launchd writing into an archive. No links or foreign files are followed.
public enum LogArchive {
    public static let maxBytes = 2_000_000
    public static let archiveCount = 3
    public enum Rotation { case unchanged, rotated, failed }

    public static func rotate(descriptor: Int32, path: String, limit: Int = maxBytes) -> Rotation {
        var output = stat()
        guard fstat(descriptor, &output) == 0, output.st_mode & S_IFMT == S_IFREG,
              output.st_size > limit else { return .unchanged }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var directory = stat()
        guard limit > 0, lstat(parent, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == geteuid(), directory.st_mode & 0o022 == 0 else { return .failed }
        for number in 1...archiveCount {
            var archive = stat()
            if lstat(path + ".\(number)", &archive) == 0 {
                guard archive.st_mode & S_IFMT == S_IFREG, archive.st_nlink == 1, archive.st_uid == geteuid() else { return .failed }
            } else if errno != ENOENT { return .failed }
        }
        let input = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { return .failed }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_ino == output.st_ino, info.st_dev == output.st_dev,
              let data = tail(descriptor: input, size: info.st_size, limit: limit) else { return .failed }
        // Persist a new copy before moving history or truncating anything.
        var template = Array((parent + "/.log-XXXXXX").utf8CString)
        let temporary = mkstemp(&template)
        guard temporary >= 0 else { return .failed }
        let tempPath = String(cString: template)
        defer { close(temporary); unlink(tempPath) }
        guard fchmod(temporary, 0o644) == 0, write(data, to: temporary), fsync(temporary) == 0 else { return .failed }
        for number in stride(from: archiveCount - 1, through: 1, by: -1) {
            if rename(path + ".\(number)", path + ".\(number + 1)") != 0, errno != ENOENT { return .failed }
        }
        guard rename(tempPath, path + ".1") == 0 else { return .failed }
        // Never clear the current log if archiving failed (disk full, permissions, etc.).
        guard ftruncate(descriptor, 0) == 0 else { return .failed }
        _ = lseek(descriptor, 0, SEEK_SET)
        return .rotated
    }

    /// Oldest first; each read is bounded even if an older installation left a huge file.
    public static func read(path: String) -> String {
        let paths = stride(from: archiveCount, through: 1, by: -1).map { path + ".\($0)" } + [path]
        return paths.compactMap { file -> String? in
            let fd = open(file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  let data = tail(descriptor: fd, size: info.st_size, limit: maxBytes) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
    }

    private static func tail(descriptor: Int32, size: off_t, limit: Int) -> Data? {
        let count = Int(min(off_t(limit), max(0, size)))
        let start = max(0, size - off_t(count))
        var data = Data(count: count)
        let success = data.withUnsafeMutableBytes { bytes -> Bool in
            var read = 0
            while read < count {
                let n = pread(descriptor, bytes.baseAddress!.advanced(by: read), count - read, start + off_t(read))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                read += n
            }
            return true
        }
        guard success else { return nil }
        // An oversized file's first partial line is not a complete diagnostic event.
        if start > 0, let newline = data.firstIndex(of: 10) { data.removeSubrange(...newline) }
        return data
    }

    private static func write(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var written = 0
            while written < data.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), data.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
    }
}
