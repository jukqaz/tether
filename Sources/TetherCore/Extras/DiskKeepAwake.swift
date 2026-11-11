import Darwin
import Foundation

public struct DiskKeepAwakeSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    public var enabled = false
    public var directory: URL?
    public var interval: Double = 60
    public var maximumDuration: Double = 3600
    public init(enabled: Bool = false, directory: URL? = nil, interval: Double = 60, maximumDuration: Double = 3600) {
        self.enabled = enabled; self.directory = directory; self.interval = interval; self.maximumDuration = maximumDuration
    }
    public var isValid: Bool {
        version == Self.currentVersion && interval.isFinite && (15...300).contains(interval)
            && maximumDuration.isFinite && (15...7200).contains(maximumDuration)
            && (!enabled || directory.map(NativeDiskKeepAwakeBackend.isAllowedSelection) == true)
    }
    public func normalizedForImport() -> Self { var value = self; value.enabled = false; return value }
}

public enum DiskKeepAwakeError: String, Error, Codable, Sendable {
    case invalidSelection, directoryUnavailable, unsafeFile, openFailed, writeFailed, syncFailed, cleanupPending, authorizationExpired, unsupported
}

public protocol DiskKeepAwakeBackend: Sendable {
    var supportsAutomaticCleanup: Bool { get }
    func open(directory: URL, id: UUID) throws -> UUID
    func pulse(_ handle: UUID) throws
    func close(_ handle: UUID) throws
}
public enum DiskKeepAwakeState: Equatable, Sendable {
    case stopped, running(deadline: Double), failed(DiskKeepAwakeError), cleanupPending
}

/// The app must stop this independent tool on its owning session/protection/power boundary.
/// A second start never renews an existing deadline. The internal timer only expires/pulses this tool.
public actor DiskKeepAwakeDriver {
    private let backend: any DiskKeepAwakeBackend
    private let clock: @Sendable () -> Double
    private let automaticScheduling: Bool
    private var handle: UUID?
    private var deadline: Double?
    private var authorizationDeadline: Double?
    private var nextPulse: Double?
    private var lastObservation: Double?
    private var interval: Double = 60
    private var timer: Task<Void, Never>?
    public private(set) var state: DiskKeepAwakeState = .stopped

    public init(backend: any DiskKeepAwakeBackend = NativeDiskKeepAwakeBackend(), automaticScheduling: Bool = true,
                clock: @escaping @Sendable () -> Double = { ContinuousTime.now }) {
        self.backend = backend; self.automaticScheduling = automaticScheduling; self.clock = clock
    }
    deinit { timer?.cancel(); if let handle { try? backend.close(handle) } }

    @discardableResult
    public func start(settings: DiskKeepAwakeSettings, until: Double) -> DiskKeepAwakeState {
        let now = clock()
        guard settings.enabled else { return stop() }
        guard handle == nil else { return tick() }
        guard backend.supportsAutomaticCleanup else { state = .failed(.unsupported); return state }
        guard settings.isValid, let directory = settings.directory,
              now.isFinite, until.isFinite, until > now else { state = .failed(.invalidSelection); return state }
        do {
            handle = try backend.open(directory: directory, id: UUID())
            let final = min(until, now + settings.maximumDuration, now + 7200)
            deadline = final; authorizationDeadline = min(final, now + 15)
            interval = settings.interval; nextPulse = now; lastObservation = now
            return tick()
        } catch {
            state = .failed((error as? DiskKeepAwakeError) ?? .openFailed)
            return state
        }
    }
    /// Renew only a live fresh-observation permit; never a completed run or its total budget.
    /// The owning app passes a deadline justified by its latest confirmed common observations.
    @discardableResult
    public func authorize(until: Double) -> Bool {
        let now = clock()
        guard let deadline, let previous = authorizationDeadline, handle != nil,
              now.isFinite, until.isFinite, until > now, until <= now + 30,
              lastObservation.map({ now >= $0 }) == true else { return false }
        guard now < deadline, now < previous else { _ = stop(failure: .authorizationExpired); return false }
        authorizationDeadline = min(deadline, until)
        lastObservation = now
        schedule()
        return true
    }
    @discardableResult
    public func tick() -> DiskKeepAwakeState {
        guard let handle, let deadline else { return state }
        let now = clock()
        guard now.isFinite, let nextPulse, lastObservation.map({ now >= $0 }) == true else { return stop(failure: .invalidSelection) }
        lastObservation = now
        if now >= deadline { return stop() }
        guard let authorizationDeadline, now < authorizationDeadline else { return stop(failure: .authorizationExpired) }
        if now >= nextPulse {
            do { try backend.pulse(handle); self.nextPulse = now + interval }
            catch { return stop(failure: (error as? DiskKeepAwakeError) ?? .writeFailed) }
        }
        state = .running(deadline: deadline); schedule()
        return state
    }
    @discardableResult
    public func stop() -> DiskKeepAwakeState { stop(failure: nil) }
    private func stop(failure: DiskKeepAwakeError?) -> DiskKeepAwakeState {
        timer?.cancel(); timer = nil; deadline = nil; authorizationDeadline = nil; nextPulse = nil; lastObservation = nil
        if let handle {
            do { try backend.close(handle); self.handle = nil }
            catch { state = .cleanupPending; return state }
        }
        state = failure.map { .failed($0) } ?? .stopped
        return state
    }
    private func schedule() {
        timer?.cancel(); timer = nil
        guard automaticScheduling, let deadline, let authorizationDeadline, let nextPulse else { return }
        let delay = min(deadline, authorizationDeadline, nextPulse) - clock()
        guard delay.isFinite, delay > 0 else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(300, delay) * 1_000_000_000)) } catch { return }
            guard !Task.isCancelled else { return }
            _ = await self?.tick()
        }
    }
}

/// Experimental filesystem primitive, unavailable to the production driver until cleanup can
/// be guaranteed. POSIX stat+unlink cannot atomically prove the same inode at deletion time.
/// This backend NEVER unlinks paths; close drops only its descriptors and reports cleanup debt.
/// Direct use is limited to explicitly owned temporary-directory tests, not a supported app tool.
public final class NativeDiskKeepAwakeBackend: DiskKeepAwakeBackend, @unchecked Sendable {
    public static let automaticCleanupAvailable = false
    public var supportsAutomaticCleanup: Bool { Self.automaticCleanupAvailable }
    private struct OpenFile {
        var directory: URL
        var directoryFD: Int32
        var fileFD: Int32
        var name: String
        var device: dev_t
        var inode: ino_t
        var directoryDevice: dev_t
        var directoryInode: ino_t
    }
    private let lock = NSLock()
    private var files: [UUID: OpenFile] = [:]
    private var cleanupDebts: Set<UUID> = []
    public init() {}
    deinit {
        for value in files.values { Darwin.close(value.fileFD); Darwin.close(value.directoryFD) }
    }
    public static func isAllowedSelection(_ directory: URL) -> Bool {
        guard directory.isFileURL, directory.host == nil || directory.host == "", directory.path.hasPrefix("/") else { return false }
        let path = directory.path
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !["/", "/Users", "/Volumes", "/private", "/Library"].contains(path) else { return false }
        return !["/System", "/bin", "/sbin", "/usr", "/Library", "/private/etc", "/private/var/db", "/private/var/root"]
            .contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    public func open(directory: URL, id: UUID) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard files[id] == nil, !cleanupDebts.contains(id), Self.isAllowedSelection(directory) else { throw DiskKeepAwakeError.invalidSelection }
        let directoryFD = try Self.openDirectory(directory)
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0 else { Darwin.close(directoryFD); throw DiskKeepAwakeError.directoryUnavailable }
        // Shared non-sticky directories cannot protect the selected file's name binding.
        // Even a private directory does not make same-UID path deletion atomic; see close().
        guard directoryInfo.st_mode & 0o022 == 0 || directoryInfo.st_mode & mode_t(S_ISVTX) != 0 else {
            Darwin.close(directoryFD); throw DiskKeepAwakeError.invalidSelection
        }
        let name = ".tether-owned-" + id.uuidString.lowercased()
        let fileFD = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fileFD >= 0 else { Darwin.close(directoryFD); throw DiskKeepAwakeError.openFailed }
        var info = stat()
        guard fstat(fileFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else {
            Darwin.close(fileFD); Darwin.close(directoryFD); throw DiskKeepAwakeError.unsafeFile
        }
        files[id] = OpenFile(directory: directory, directoryFD: directoryFD, fileFD: fileFD, name: name,
            device: info.st_dev, inode: info.st_ino, directoryDevice: directoryInfo.st_dev, directoryInode: directoryInfo.st_ino)
        return id
    }
    public func pulse(_ handle: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let file = files[handle] else { throw DiskKeepAwakeError.unsafeFile }
        let check = try Self.openDirectory(file.directory)
        defer { Darwin.close(check) }
        var directoryInfo = stat()
        guard fstat(check, &directoryInfo) == 0, directoryInfo.st_dev == file.directoryDevice,
              directoryInfo.st_ino == file.directoryInode else { throw DiskKeepAwakeError.directoryUnavailable }
        try Self.verifyOwned(file)
        let data = [UInt8](repeating: 0, count: 4096)
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let written = pwrite(file.fileFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw DiskKeepAwakeError.writeFailed }
                offset += written
            }
        }
        guard ftruncate(file.fileFD, 4096) == 0 else { throw DiskKeepAwakeError.writeFailed }
        guard fsync(file.fileFD) == 0 else { throw DiskKeepAwakeError.syncFailed }
    }
    public func close(_ handle: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if cleanupDebts.contains(handle) { throw DiskKeepAwakeError.cleanupPending }
        guard let file = files.removeValue(forKey: handle) else { return }
        Darwin.close(file.fileFD); Darwin.close(file.directoryFD)
        cleanupDebts.insert(handle)
        throw DiskKeepAwakeError.cleanupPending
    }
    private static func openDirectory(_ directory: URL) throws -> Int32 {
        guard isAllowedSelection(directory) else { throw DiskKeepAwakeError.invalidSelection }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw DiskKeepAwakeError.directoryUnavailable }
        for component in directory.path.split(separator: "/") {
            let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            Darwin.close(current)
            guard next >= 0 else { throw DiskKeepAwakeError.directoryUnavailable }
            current = next
        }
        return current
    }
    private static func verifyOwned(_ file: OpenFile) throws {
        var byFD = stat(), byName = stat()
        guard fstat(file.fileFD, &byFD) == 0,
              fstatat(file.directoryFD, file.name, &byName, AT_SYMLINK_NOFOLLOW) == 0,
              byFD.st_mode & S_IFMT == S_IFREG, byFD.st_uid == geteuid(), byFD.st_nlink == 1,
              byFD.st_dev == file.device, byFD.st_ino == file.inode,
              byName.st_mode & S_IFMT == S_IFREG, byName.st_dev == file.device, byName.st_ino == file.inode else {
            throw DiskKeepAwakeError.unsafeFile
        }
    }
}
