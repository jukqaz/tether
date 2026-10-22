import Darwin
import Foundation

/// Before exec, the native child holds the common lock and waits for its parent's
/// registration permit. Parent death closes the private pipe without starting pmset.
public enum PowerWriterGate {
    public static let capability = "power-writer-gate-v3"

    public static func perform(support: String, transaction: String) -> Int32 {
        let journal = URL(fileURLWithPath: support).appendingPathComponent("power-writer.json").path
        let boot = ContinuousTime.bootID
        guard let token = UUID(uuidString: transaction),
              let executable = PowerRecoveryCommand.writerExecutable(support: support),
              PowerRecoveryCommand.safeExecutable(executable),
              case .record(let prepared) = PowerWriterJournal.read(journal),
              prepared.transaction == token, prepared.boot == boot,
              prepared.executable == executable, allowed(prepared.arguments),
              prepared.deadline > ContinuousTime.now, prepared.deadline - ContinuousTime.now <= 10,
              let current = ProcessIdentity.capture(pid: getpid()),
              let gate = prepared.gateExecutable,
              ProcessIdentity.sameExecutable(current.executable, gate),
              let lock = try? RecoveryLock.adoptingInput(at: RecoveryLock.path(supportDirectory: support)) else { return 1 }
        defer { withExtendedLifetime(lock) {} }
        var channel = stat()
        guard fstat(STDERR_FILENO, &channel) == 0, channel.st_mode & S_IFMT == S_IFIFO,
              fcntl(STDERR_FILENO, F_GETFL) & O_ACCMODE == O_RDONLY,
              fcntl(STDERR_FILENO, F_SETFL, O_NONBLOCK) == 0 else { return 1 }
        var byte = UInt8(0)
        var permitted = false
        while ContinuousTime.now < prepared.deadline {
            let count = Darwin.read(STDERR_FILENO, &byte, 1)
            if count == 1 { permitted = byte == 0xA5; break }
            if count == 0 { return 1 }
            if errno != EAGAIN && errno != EINTR { return 1 }
            var descriptor = pollfd(fd: STDERR_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&descriptor, 1, 10)
        }
        guard permitted, case .record(let running) = PowerWriterJournal.read(journal),
              running.transaction == token, running.phase == .running,
              running.boot == boot, running.executable == executable,
              running.arguments == prepared.arguments, running.gateExecutable == gate,
              running.owner == prepared.owner, running.intentEpoch == prepared.intentEpoch,
              running.intentRevision == prepared.intentRevision,
              running.guiOwner == prepared.guiOwner,
              running.deadline == prepared.deadline, running.deadline > ContinuousTime.now,
              running.writerPID == getpid(), let writer = running.writer,
              writer.matchesLifetime(current), ProcessIdentity.sameExecutable(writer.executable, gate) else { return 1 }
        guard PowerWriterGUIAuthority.nativePermits(arguments: running.arguments, owner: running.guiOwner,
                                                    support: support, boot: boot, intentEpoch: running.intentEpoch) else {
            return PowerWriterGUIAuthority.denied
        }
        // The checked state read has a bounded lock wait; it must not turn a
        // once-valid deadline into a late command after GUI verification returns.
        guard running.deadline > ContinuousTime.now else { return 1 }
        // No descendants: exec replaces this gate, preserving its PID/start identity
        // and inherited lock. Restore stderr to the captured output before exec.
        guard dup2(STDOUT_FILENO, STDERR_FILENO) == STDERR_FILENO else { return 1 }
        let strings = ([executable] + running.arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { return 1 }
        var argv = strings + [nil]
        argv.withUnsafeMutableBufferPointer { _ = execv(executable, $0.baseAddress!) }
        return 1
    }

    private static func allowed(_ arguments: [String]) -> Bool {
        if [["sleepnow"], ["displaysleepnow"], ["-a", "disablesleep", "0"],
            ["-a", "disablesleep", "1"]].contains(arguments) { return true }
        guard arguments.count == 3, ["-b", "-c"].contains(arguments[0]),
              let key = PowerModeSetting.Key(rawValue: arguments[1]), let value = Int(arguments[2]),
              String(value) == arguments[2] else { return false }
        return (0...(key == .powermode ? 2 : 1)).contains(value)
    }
}
