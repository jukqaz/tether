import Darwin
import Foundation

public enum UserSessionEndpoint {
    public static var production: String {
        URL(fileURLWithPath: AppCoordinatorLease.production).deletingLastPathComponent()
            .appendingPathComponent("commands.sock").path
    }
    public static var path: String { ProcessInfo.processInfo.environment["TETHER_USER_SESSION_SOCKET"] ?? production }

    static func verifyFolder(_ path: String, create: Bool) throws {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var info = stat()
        if lstat(folder, &info) != 0 {
            guard create, path == production else { throw UserSessionFailure("unsafeEndpoint") }
            let parent = URL(fileURLWithPath: folder).deletingLastPathComponent().path
            guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw UserSessionFailure("unsafeEndpoint") }
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard lstat(folder, &info) == 0 else { throw UserSessionFailure("unsafeEndpoint") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw UserSessionFailure("unsafeEndpoint")
        }
    }

    public static func coordinatorExecutable(forClient executable: String) -> String? {
        let client = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let folder = client.deletingLastPathComponent()
        if folder.lastPathComponent == "Helpers", folder.deletingLastPathComponent().lastPathComponent == "Contents" {
            return folder.deletingLastPathComponent().appendingPathComponent("MacOS/Tether").path
        }
        if client.lastPathComponent == "TetherCLI" { return folder.appendingPathComponent("Tether").path }
        return nil
    }
    public static func companionExecutable(forCoordinator executable: String) -> String? {
        let app = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let folder = app.deletingLastPathComponent()
        if folder.lastPathComponent == "MacOS", folder.deletingLastPathComponent().lastPathComponent == "Contents" {
            return folder.deletingLastPathComponent().appendingPathComponent("Helpers/tether").path
        }
        if app.lastPathComponent == "Tether" { return folder.appendingPathComponent("TetherCLI").path }
        return nil
    }
}

public struct UserSessionPeer: Sendable {
    public var uid: UInt32
    public var process: ProcessIdentity
    public var login: GUISessionIdentity?
    public init(uid: UInt32, process: ProcessIdentity, login: GUISessionIdentity?) {
        self.uid = uid; self.process = process; self.login = login
    }
}

public struct UserSessionClient {
    public let path: String
    private let expectedServer: String
    public init(path: String = UserSessionEndpoint.path, expectedServer: String) { self.path = path; self.expectedServer = expectedServer }
    public func call(_ request: UserSessionRequest) throws -> UserSessionReply {
        do { try UserSessionEndpoint.verifyFolder(path, create: false) }
        catch {
            var info = stat()
            if lstat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &info) != 0, errno == ENOENT {
                throw UserSessionFailure("appUnavailable")
            }
            throw error
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw UserSessionFailure("appUnavailable") }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw UserSessionFailure("unsafeEndpoint")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UserSessionFailure("appUnavailable") }
        defer { close(fd) }
        ServiceWire.options(fd)
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard try ServiceWire.address(path, { connect(fd, $0, $1) }) == 0 else { throw UserSessionFailure("appUnavailable") }
        var uid: uid_t = 0, gid: gid_t = 0, pid: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              let process = ProcessIdentity.capture(pid: pid), process.uid == uid,
              ProcessIdentity.sameExecutable(process.executable, expectedServer) else { throw UserSessionFailure("unexpectedServer") }
        try ServiceWire.send(request, fd: fd)
        let reply = try ServiceWire.receive(UserSessionReply.self, fd: fd, timeout: 15)
        guard reply.version == 1, reply.build == TetherPaths.build else { throw UserSessionFailure("unsupportedVersion") }
        guard reply.id == request.id else { throw UserSessionFailure("invalidRequest") }
        return reply
    }
    public func snapshot() throws -> UserSessionReply {
        let reply = try call(UserSessionRequest())
        guard reply.ok else { throw UserSessionFailure(reply.error ?? "coordinatorUnavailable") }
        return reply
    }
    /// CAS failures have no receipt and can reuse this ID. A lost acknowledgement
    /// retries the identical frame, so an extension or toggle cannot run twice.
    public func perform(_ command: TetherCommand, workEvent: V4WorkEvent? = nil,
                        manualPID: V4ProcessIdentity? = nil) throws -> UserSessionReply {
        if command == .status && workEvent == nil && manualPID == nil { return try snapshot() }
        let id = UUID(), started = ContinuousTime.now
        for _ in 0..<8 {
            let state = try snapshot()
            let request = UserSessionRequest(command, id: id, epoch: state.epoch, revision: state.revision,
                now: started, workEvent: workEvent, manualPID: manualPID)
            let reply: UserSessionReply
            do { reply = try call(request) }
            catch let failure as ServiceFailure where failure.code == "connectionClosed" {
                guard ContinuousTime.now < request.deadline else { throw UserSessionFailure("expired") }
                reply = try call(request)
            }
            if reply.error == "staleRevision" { continue }
            // A policy refusal still carries a useful structured task receipt. Authentication/transport
            // failures have no task result and continue to throw, so they cannot look like admission.
            if workEvent != nil, reply.workEventResult != nil { return reply }
            guard reply.ok else { throw UserSessionFailure(reply.error ?? "failed") }
            return reply
        }
        throw UserSessionFailure("staleRevision")
    }
}

/// A user-owned endpoint, with an exclusive lifetime lock and bounded clients.
/// This server never launches commands or reads/writes the privileged control file.
public final class UserSessionService {
    private let path: String
    private var source: DispatchSourceRead?
    private var socketIdentity: (dev_t, ino_t)?
    private let slots = DispatchSemaphore(value: 8)
    private let queue = DispatchQueue(label: "tether.user-command.accept")
    public init(path: String = UserSessionEndpoint.path) { self.path = path }

    public func start(_ handle: @escaping @MainActor (UserSessionRequest, UserSessionPeer) async -> UserSessionReply) throws {
        guard source == nil else { return }
        try UserSessionEndpoint.verifyFolder(path, create: true)
        let lockPath = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("commands.lock").path
        let lock = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw UserSessionFailure("unsafeEndpoint") }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { close(lock); throw UserSessionFailure("unsafeEndpoint") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw UserSessionFailure("busy") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(lock); throw UserSessionFailure("appUnavailable") }
        do {
            if lstat(path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw UserSessionFailure("unsafeEndpoint") }
                guard unlink(path) == 0 else { throw UserSessionFailure("unsafeEndpoint") }
            }
            ServiceWire.options(fd)
            guard try ServiceWire.address(path, { bind(fd, $0, $1) }) == 0,
                  lstat(path, &info) == 0 else { throw UserSessionFailure("unsafeEndpoint") }
            socketIdentity = (info.st_dev, info.st_ino)
            guard chmod(path, 0o600) == 0 else { throw UserSessionFailure("unsafeEndpoint") }
            guard listen(fd, 8) == 0 else { throw UserSessionFailure("appUnavailable") }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        } catch {
            removeOwnedSocket(); close(fd); close(lock); throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                guard self.slots.wait(timeout: .now()) == .success else { close(client); continue }
                ServiceWire.options(client)
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        var uid: uid_t = 0, gid: gid_t = 0, pid: Int32 = 0
                        var size = socklen_t(MemoryLayout<Int32>.size)
                        guard getpeereid(client, &uid, &gid) == 0, uid == geteuid(),
                              getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
                              let process = ProcessIdentity.capture(pid: pid), process.uid == uid else { throw UserSessionFailure("unauthorized") }
                        let request = try ServiceWire.receive(UserSessionRequest.self, fd: client)
                        let peer = UserSessionPeer(uid: uid, process: process, login: GUISessionProbe.peer(fd: client, uid: uid, pid: pid))
                        Task.detached {
                            defer { close(client); self.slots.signal() }
                            let reply = await handle(request, peer)
                            try? ServiceWire.send(reply, fd: client)
                        }
                    } catch { close(client); self.slots.signal() }
                }
            }
        }
        source.setCancelHandler { close(fd); close(lock) }
        self.source = source; source.resume()
    }
    private func removeOwnedSocket() {
        guard let identity = socketIdentity else { return }
        var info = stat()
        if lstat(path, &info) == 0, info.st_dev == identity.0, info.st_ino == identity.1,
           info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK { _ = unlink(path) }
        socketIdentity = nil
    }
    public func stop() { removeOwnedSocket(); source?.cancel(); source = nil }
    deinit { stop() }
}
