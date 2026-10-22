import Darwin
import Foundation

/// Prepared before launch; a direct writer inherits the recovery flock until it exits.
/// This is a writer lifetime journal, separate from ownership/effect verification.
public struct PowerWriterRecord: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case prepared, running, writerUnresolved }
    public var schema = 1
    public var transaction = UUID()
    public var phase = Phase.prepared
    public var boot: String
    public var owner: ProcessIdentity
    public var writer: ProcessIdentity?
    public var writerPID: Int32?
    public var executable: String
    /// Optional schema-1 extension. Old readers refuse a live gate's different
    /// executable; they can consume the record once the same inherited lock releases.
    public var gateExecutable: String?
    public var arguments: [String]
    public var deadline: Double
    public var inheritsRecoveryLock = true
    public var intentEpoch: String?
    public var intentRevision: UInt64?
    /// Optional schema-1 extension. Root GUI-controlled operations require it;
    /// restoration is allowed even after this GUI controller has gone away.
    public var guiOwner: GUISessionOwner?

    public init(boot: String, owner: ProcessIdentity, executable: String, arguments: [String], deadline: Double) {
        self.boot = boot; self.owner = owner; self.executable = executable
        self.arguments = arguments; self.deadline = deadline
    }
}

public enum PowerWriterJournal {
    public enum State: Equatable { case absent, record(PowerWriterRecord), unsafe }
    public enum Resolution: Equatable { case resolved, active, unresolved }

    public static func read(_ path: String) -> State {
        var entry = stat()
        if lstat(path, &entry) != 0 { return errno == ENOENT ? .absent : .unsafe }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var parent = stat()
        guard lstat(folder, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR,
              parent.st_uid == geteuid(), parent.st_mode & 0o022 == 0,
              entry.st_mode & S_IFMT == S_IFREG, entry.st_nlink == 1,
              entry.st_uid == geteuid(), entry.st_mode & 0o7777 == 0o600,
              let value = JSONFile.read(PowerWriterRecord.self, from: path), value.schema == 1,
              !value.boot.isEmpty, value.boot != "unknown", value.owner.pid > 1,
              value.owner.uid == geteuid(), value.owner.started > 0,
              value.deadline.isFinite, value.deadline > 0, value.inheritsRecoveryLock,
              value.writerPID.map({ $0 > 1 && $0 != value.owner.pid }) ?? true,
              value.gateExecutable.map({ $0.hasPrefix("/") && $0 == value.owner.executable }) ?? true,
              value.writer.map({ $0.pid == value.writerPID && $0.uid == value.owner.uid && $0.started > 0 }) ?? true else { return .unsafe }
        return .record(value)
    }

    /// May inspect/stop the identified expired writer before acquiring its inherited lock.
    /// Never clears the journal here; clearing requires the common recovery lock.
    public static func resolve(_ path: String, boot: String, expectedExecutable: String,
                               stopExpired: Bool, now: Double = ContinuousTime.now) -> Resolution {
        switch read(path) {
        case .absent: return .resolved
        case .unsafe: return .unresolved
        case .record(let record):
            guard !boot.isEmpty, boot != "unknown", now.isFinite else { return .unresolved }
            if record.boot != boot { return .resolved }
            guard record.executable == expectedExecutable else { return .unresolved }
            guard let pid = record.writerPID else { return record.phase == .prepared ? .resolved : .unresolved }
            if ProcessIdentity.exited(pid: pid) { return .resolved }
            guard let saved = record.writer, let current = ProcessIdentity.capture(pid: pid) else { return .unresolved }
            if !saved.matchesLifetime(current) { return .resolved } // Reused PID: never signal its new owner.
            guard matchesExecutable(current.executable, record: record) else { return .unresolved }
            guard stopExpired, now >= record.deadline else { return .active }
            // Revalidate both journal generation and lifetime immediately before each signal.
            for (signal, wait) in [(SIGTERM, Shell.terminationGrace), (SIGKILL, Shell.terminationConfirmationWindow)] {
                guard read(path) == .record(record) else { return .unresolved }
                if ProcessIdentity.exited(pid: pid) { return .resolved }
                guard let latest = ProcessIdentity.capture(pid: pid) else { return .unresolved }
                if !saved.matchesLifetime(latest) { return .resolved }
                guard matchesExecutable(latest.executable, record: record) else { return .unresolved }
                guard kill(pid, signal) == 0 || errno == ESRCH else { return .unresolved }
                let until = ContinuousTime.now + wait
                repeat {
                    if ProcessIdentity.exited(pid: pid) { return .resolved }
                    if let latest = ProcessIdentity.capture(pid: pid), !saved.matchesLifetime(latest) { return .resolved }
                    usleep(5_000)
                } while ContinuousTime.now < until
            }
            return .unresolved
        }
    }

    private static func matchesExecutable(_ executable: String, record: PowerWriterRecord) -> Bool {
        ProcessIdentity.sameExecutable(executable, record.executable) ||
            record.gateExecutable.map { ProcessIdentity.sameExecutable(executable, $0) } == true
    }

    /// Caller owns the stable recovery lock. No new record may be deleted by an old completion.
    public static func clear(_ path: String, transaction: UUID) -> Bool {
        guard case .record(let current) = read(path), current.transaction == transaction else { return false }
        guard unlink(path) == 0 else { return false }
        return JSONFile.syncDirectory(containing: path)
    }

    public static func clearResolved(_ path: String, boot: String, expectedExecutable: String) -> Bool {
        guard resolve(path, boot: boot, expectedExecutable: expectedExecutable, stopExpired: false) == .resolved else { return false }
        switch read(path) {
        case .absent: return true
        case .unsafe: return false
        case .record(let record): return clear(path, transaction: record.transaction)
        }
    }

    /// The executable is supplied by trusted code; production uses only /usr/bin/pmset.
    public static func run(_ executable: String, arguments: [String], lock: RecoveryLock,
                           journalPath: String, boot: String, timeout: Double = 2,
                           intentEpoch: String? = nil, intentRevision: UInt64? = nil,
                           gateExecutable: String? = nil,
                           guiOwner: GUISessionOwner? = nil,
                           beforeRegistration: ((Int32) -> Void)? = nil,
                           afterRegistration: ((Int32) -> Void)? = nil) -> Shell.Result? {
        guard timeout.isFinite, timeout > 0, timeout <= 10,
              geteuid() != 0 || gateExecutable != nil,
              !boot.isEmpty, boot != "unknown", clearResolved(journalPath, boot: boot, expectedExecutable: executable),
              let owner = ProcessIdentity.capture(pid: getpid()), let input = try? lock.childInput() else { return nil }
        let support = URL(fileURLWithPath: journalPath).deletingLastPathComponent().path
        guard PowerWriterGUIAuthority.nativePermits(arguments: arguments, owner: guiOwner,
                                                    support: support, boot: boot, intentEpoch: intentEpoch) else {
            // No writer was launched. Distinguish known GUI rejection from an
            // unresolved writer so own-setting recovery remains possible.
            return Shell.Result(status: PowerWriterGUIAuthority.denied,
                output: "Current GUI or automatic sleep policy denied the writer", timedOut: false,
                processID: nil, terminationConfirmed: true, exitStatus: nil)
        }
        if let gateExecutable {
            // The gate is strictly the already-running coordinator itself. An
            // administrator-approved bundled coordinator may still be user-owned.
            // The target pmset executable retains the stricter root-owner check.
            guard PowerRecoveryCommand.safeExecutable(gateExecutable, requiringOwner: false),
                  ProcessIdentity.sameExecutable(gateExecutable, owner.executable) else { return nil }
        }
        var record = PowerWriterRecord(boot: boot, owner: owner, executable: executable,
                                       arguments: arguments, deadline: ContinuousTime.now + timeout)
        record.gateExecutable = gateExecutable
        record.intentEpoch = intentEpoch; record.intentRevision = intentRevision
        record.guiOwner = guiOwner
        guard JSONFile.write(record, to: journalPath, permissions: 0o600, durable: true) else { return nil }
        let remaining = record.deadline - ContinuousTime.now
        guard remaining > 0 else { _ = clear(journalPath, transaction: record.transaction); return nil }
        let launch = gateExecutable ?? executable
        let launchArguments = gateExecutable == nil ? arguments : ["--writer-gate", "--support",
            URL(fileURLWithPath: journalPath).deletingLastPathComponent().path,
            "--transaction", record.transaction.uuidString]
        let result = Shell.run(launch, launchArguments, timeout: remaining, inheritedInput: input,
            requiresStartPermission: gateExecutable != nil, didStart: { pid in
            beforeRegistration?(pid)
            guard case .record(let current) = read(journalPath), current.transaction == record.transaction else { return false }
            let identity = ProcessIdentity.capture(pid: pid)
            if let gateExecutable {
                guard let identity, ProcessIdentity.sameExecutable(identity.executable, gateExecutable) else { return false }
            }
            record.writerPID = pid; record.writer = identity; record.phase = .running
            guard JSONFile.write(record, to: journalPath, permissions: 0o600, durable: true) else { return false }
            afterRegistration?(pid)
            return true
        })
        if result.terminationConfirmed {
            guard clear(journalPath, transaction: record.transaction) else { return nil }
        } else {
            record.phase = .writerUnresolved
            if case .record(let current) = read(journalPath), current.transaction == record.transaction {
                _ = JSONFile.write(record, to: journalPath, permissions: 0o600, durable: true)
            }
        }
        withExtendedLifetime(input) {}
        return result
    }
}
