import Darwin
import Foundation

/// Private command-line recovery only. The service protocol does not expose this executor.
/// Every write requires the caller's common flock on stdin and uses a fixed pmset operation.
public enum PowerRecoveryCommand {
    public static let capability = "power-recovery-executor-v2"
    public enum Mode { case resolve, clear, write }

    public static func perform(_ mode: Mode, support: String, operation: String? = nil) -> Int32 {
        guard let executable = writerExecutable(support: support),
              !ContinuousTime.bootID.isEmpty, ContinuousTime.bootID != "unknown" else { return 1 }
        let journal = URL(fileURLWithPath: support).appendingPathComponent("power-writer.json").path
        if mode == .resolve {
            switch PowerWriterJournal.resolve(journal, boot: ContinuousTime.bootID,
                expectedExecutable: executable, stopExpired: true) {
            case .resolved: return 0
            case .active: return 75
            case .unresolved: return 1
            }
        }
        guard let lock = try? RecoveryLock.adoptingInput(at: RecoveryLock.path(supportDirectory: support)) else { return 1 }
        defer { withExtendedLifetime(lock) {} }
        if mode == .clear {
            return PowerWriterJournal.clearResolved(journal, boot: ContinuousTime.bootID,
                expectedExecutable: executable) ? 0 : 1
        }
        let arguments: [String]
        switch operation {
        case "release-sleep": arguments = ["-a", "disablesleep", "0"]
        case "request-sleep": arguments = ["sleepnow"]
        default: return 64
        }
        let guiOwner = operation == "request-sleep" ? PowerWriterGUIAuthority.controllerState(support: support)?.guiOwner : nil
        guard PowerWriterGUIAuthority.nativePermits(arguments: arguments, owner: guiOwner,
                                                    support: support, boot: ContinuousTime.bootID, intentEpoch: "recovery") else {
            return PowerWriterGUIAuthority.denied
        }
        guard safeExecutable(executable),
              let result = PowerWriterJournal.run(executable, arguments: arguments, lock: lock,
                journalPath: journal, boot: ContinuousTime.bootID, timeout: 2,
                intentEpoch: "recovery", intentRevision: nil,
                gateExecutable: ProcessIdentity.capture(pid: getpid())?.executable,
                guiOwner: guiOwner) else { return 1 }
        if result.status == PowerWriterGUIAuthority.denied { return PowerWriterGUIAuthority.denied }
        return result.status == 0 && result.terminationConfirmed && !result.timedOut ? 0 : 1
    }

    private static func installLibrary(support: String) -> Int32 {
        if geteuid() == 0 {
            guard support == "/Library/Application Support/Tether" else { return -1 }
            return open("/Library", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard let value = ProcessInfo.processInfo.environment["TETHER_INSTALL_TEST_ROOT"] else { return -1 }
        let root = URL(fileURLWithPath: value).standardizedFileURL
        guard ["/tmp", "/private/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("tether-install-test-"),
              support == root.appendingPathComponent("Library/Application Support/Tether").path else { return -1 }
        let fixture = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fixture >= 0 else { return -1 }
        defer { close(fixture) }
        var entry = stat()
        guard fstat(fixture, &entry) == 0, safeLogDirectory(entry), noLogACL(fixture),
              entry.st_mode & 0o7777 == 0o700 else { return -1 }
        return openat(fixture, "Library", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    /// Installer-only repair of the fixed diagnostic log directory. Validate every
    /// existing log before changing permissions, and keep launchd's active inode.
    /// This operation neither adopts a power lock nor exposes private state files.
    public static func prepareLogs(support: String) -> Int32 {
        let library = installLibrary(support: support)
        guard library >= 0 else { return 1 }
        defer { close(library) }
        var directory = stat()
        guard fstat(library, &directory) == 0, safeLogDirectory(directory), noLogACL(library) else { return 1 }
        let parent = openLogDirectory("Logs", at: library)
        guard parent >= 0 else { return 1 }
        defer { close(parent) }
        let logs = openLogDirectory("Tether", at: parent)
        guard logs >= 0 else { return 1 }
        defer { close(logs) }

        let names = ["helper.log", "helper.log.1", "helper.log.2", "helper.log.3"]
        var opened: [(name: String, descriptor: Int32, entry: stat)] = []
        defer { for file in opened { close(file.descriptor) } }
        for name in names {
            let descriptor = openat(logs, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if descriptor < 0 {
                guard errno == ENOENT else { return 1 }
                continue
            }
            var entry = stat()
            guard fstat(descriptor, &entry) == 0, safeLogFile(entry), noLogACL(descriptor) else { close(descriptor); return 1 }
            opened.append((name, descriptor, entry))
        }
        // A late unsafe archive must not cause an earlier valid log to be chmodded.
        // Permission writes use only these verified descriptors, never a followed path.
        for file in opened {
            var entry = stat()
            guard fstatat(logs, file.name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  safeLogFile(entry), entry.st_dev == file.entry.st_dev,
                  entry.st_ino == file.entry.st_ino else { return 1 }
        }
        if !opened.contains(where: { $0.name == "helper.log" }) {
            let descriptor = openat(logs, "helper.log", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { return 1 }
            var entry = stat()
            guard fstat(descriptor, &entry) == 0, safeLogFile(entry) else { close(descriptor); return 1 }
            opened.append(("helper.log", descriptor, entry))
        }
        for file in opened {
            var entry = stat()
            guard fstat(file.descriptor, &entry) == 0, safeLogFile(entry), noLogACL(file.descriptor),
                  fchmod(file.descriptor, 0o644) == 0 else { return 1 }
        }
        guard fchmod(logs, 0o755) == 0 else { return 1 }
        return 0
    }

    private static func safeLogDirectory(_ entry: stat) -> Bool {
        entry.st_mode & S_IFMT == S_IFDIR && entry.st_uid == geteuid() && entry.st_mode & 0o022 == 0
    }

    private static func safeLogFile(_ entry: stat) -> Bool {
        entry.st_mode & S_IFMT == S_IFREG && entry.st_uid == geteuid() && entry.st_nlink == 1
    }

    /// Mode bits alone cannot guarantee root-only writes when an extended ACL
    /// grants access. Leave such a path untouched rather than stripping its ACL.
    private static func noLogACL(_ descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        errno = 0
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }

    private static func openLogDirectory(_ name: String, at parent: Int32) -> Int32 {
        var created = false
        var entry = stat()
        if fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT, mkdirat(parent, name, 0o755) == 0 else { return -1 }
            created = true
        } else if !safeLogDirectory(entry) { return -1 }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        guard fstat(descriptor, &entry) == 0, safeLogDirectory(entry), noLogACL(descriptor),
              !created || fchmod(descriptor, 0o755) == 0 else { close(descriptor); return -1 }
        return descriptor
    }

    static func safeExecutable(_ path: String, requiringOwner: Bool = true) -> Bool {
        var entry = stat()
        return lstat(path, &entry) == 0 && entry.st_mode & S_IFMT == S_IFREG && entry.st_nlink == 1 &&
            entry.st_mode & 0o022 == 0 && entry.st_mode & 0o111 != 0 &&
            (!requiringOwner || entry.st_uid == geteuid() || entry.st_uid == 0)
    }

    static func writerExecutable(support: String) -> String? {
        // Root always uses the system executable; test environment variables cannot redirect it.
        if geteuid() == 0 { return "/usr/bin/pmset" }
        let env = ProcessInfo.processInfo.environment
        let candidates = [("TETHER_RECOVERY_TEST_ROOT", "tether-recovery-test-"),
                          ("TETHER_INSTALL_TEST_ROOT", "tether-install-test-"),
                          ("TETHER_UNINSTALL_TEST_ROOT", "tether-uninstall-test-")]
        for (name, prefix) in candidates {
            guard let value = env[name] else { continue }
            let root = URL(fileURLWithPath: value).standardizedFileURL
            guard ["/tmp", "/private/tmp"].contains(root.deletingLastPathComponent().path),
                  root.lastPathComponent.hasPrefix(prefix),
                  URL(fileURLWithPath: support).standardizedFileURL.path.hasPrefix(root.path + "/") ||
                    URL(fileURLWithPath: support).standardizedFileURL.path == root.path else { continue }
            var entry = stat()
            guard lstat(root.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFDIR,
                  entry.st_uid == geteuid(), entry.st_mode & 0o777 == 0o700 else { continue }
            return root.appendingPathComponent("mock/pmset").path
        }
        return nil
    }
}
