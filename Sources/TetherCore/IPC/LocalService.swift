import Foundation

public enum ServiceAction: String, Codable, Sendable {
    case snapshot, configure, stop, resume, sleep, startHold, startManualSession, endManualSession, attachApp, detachApp, markDiagnostic
    case prepareWorkSession, attachWorkSession, syncWorkSession
}

public struct ServiceRequest: Codable, Equatable, Sendable {
    public var version = 2
    // Set by the server from LOCAL_PEERPID, never decoded from client JSON.
    public var authenticatedPID: Int32? = nil
    // Set from LOCAL_PEERTOKEN and Security session metadata, never from JSON.
    public var authenticatedGUILogin: GUISessionIdentity? = nil
    private enum CodingKeys: String, CodingKey { case version, id, action, epoch, revision, control, minutes, manualBatteryContinuationMinutes, holdSource, workSession }
    public var id = UUID()
    public var action: ServiceAction
    public var epoch: String?
    public var revision: UInt64?
    public var control: Control?
    public var minutes: Int?
    public var manualBatteryContinuationMinutes: Int?
    public var holdSource: String?
    public var workSession: WorkSessionLease?
    public init(_ action: ServiceAction) { self.action = action }
}

public struct ServiceReply: Codable, Sendable {
    public var version = 2
    public var id: UUID
    public var ok: Bool
    public var error: String?
    public var epoch: String
    public var revision: UInt64
    public var control: Control
    public var protection: ProtectionStatus?
    public var status: Status?
    public var workSessionBridge: WorkSessionBridge?
    public var workSessionPreparation: WorkSessionPreparation?
    public init(id: UUID, ok: Bool, error: String? = nil, epoch: String, revision: UInt64, control: Control, protection: ProtectionStatus? = nil) {
        self.id = id; self.ok = ok; self.error = error; self.epoch = epoch; self.revision = revision
        self.control = control; self.protection = protection
    }

    /// The installer and GUI must approve the same contract that runtime lid
    /// coordination uses. An old or missing coordinator is not installation success.
    public func isCurrentHelperReady(now: Date = Date()) -> Bool {
        guard ok, version == 2, control.schemaVersion == Control.currentSchema,
              protection?.protocolVersion == 2, protection?.blockReason != "migrationFailed",
              let status, status.matchesCurrentBuild,
              status.workSessionCoordinatorVersion == WorkSessionLease.coordinatorVersion,
              status.systemPowerObservationAvailable != false,
              status.updatedAt.isFinite, now.timeIntervalSince1970.isFinite else { return false }
        let age = now.timeIntervalSince1970 - status.updatedAt
        return age.isFinite && age >= 0 && age < 30
    }

    /// Build 49 has the authenticated protocol-2 detach contract, but no common
    /// session bridge. Only this verified legacy contract can yield general work
    /// to the app while its administrator update is postponed. Unknown helpers
    /// and incomplete protection observations are never inferred as safe.
    public func canHandOffLegacyGeneralWork(now: Date = Date()) -> Bool {
        guard ok, version == 2, control.isSupported,
              let protection, protection.protocolVersion == 2,
              protection.lastError == nil,
              protection.blockReason.map({ ["thermal", "battery", "sensor", "time", "budget", "displayConflict"].contains($0) }) ?? true,
              let status, status.version == "2026.9.1", status.build == 49,
              status.workSessionCoordinatorVersion == nil, workSessionBridge == nil,
              status.workSession == nil, status.power != .unknown, !epoch.isEmpty,
              status.updatedAt.isFinite, now.timeIntervalSince1970.isFinite else { return false }
        let age = now.timeIntervalSince1970 - status.updatedAt
        return age >= 0 && age < 30
    }

    /// Called only after a confirmed same-process detach. The legacy automatic
    /// budget is not public; the manual status also has no monotonic sample time.
    /// Assume both started at boot instead of minting allowance from an aged
    /// snapshot. A stable AC return or a verified current bridge may follow.
    /// Temporary sessions are consumed, never replayed by this handoff.
    public func legacyGeneralWorkBridge(clock: Double = ContinuousTime.now, boot: String = ContinuousTime.bootID,
                                        now: Date = Date()) -> WorkSessionBridge? {
        guard canHandOffLegacyGeneralWork(now: now), clock.isFinite, clock >= 0, !boot.isEmpty, boot != "unknown",
              status?.appConnected == false, status?.appPID == nil, status?.ownsOverride == false else { return nil }
        var automatic = ProtectionState(); automatic.restart(boot: boot)
        automatic.prepareBatteryBudget(power: .battery, needed: true, clock: 0, boot: boot)
        if let reason = WorkSessionBridge.generalWorkBlockReason(protection?.blockReason) { automatic.block(reason) }
        var manual = ProtectionState(); manual.restart(boot: boot)
        manual.prepareBatteryBudget(power: .battery, needed: true, clock: 0, boot: boot)
        return WorkSessionBridge(coordinated: false, automaticBudget: automatic, manualBudget: manual)
    }
}

public struct ServiceFailure: LocalizedError {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var errorDescription: String? {
        switch code {
        case "coordinatorRequired": L("This session is managed by the Tether app. Use its session controls.", "이 세션은 Tether 앱에서 관리합니다. 앱의 세션 조작을 사용해 주세요.")
        case "invalidWorkLease": L("The lid request is stale or cannot be verified. General work is reported separately.", "덮개 요청이 오래됐거나 확인할 수 없습니다. 일반 작업 유지 상태는 별도로 표시합니다.")
        case "unavailable": L("The helper service is unavailable. Install the matching helper.", "도우미에 연결할 수 없습니다. 이 버전의 도우미를 설치해 주세요.")
        case "advancedAutomationRequired": L("Basic automatic starts use power only. Select advanced automation before changing its power range.", "기본 자동 시작은 전원 연결 중에만 동작합니다. 전원 범위를 바꾸려면 고급 자동화를 먼저 선택하세요.")
        case "safetyBlocked": L("Safety protection is holding this Mac back. Resume after charging or cooling.", "배터리·발열 보호로 중지됐습니다. 충전하거나 냉각한 뒤 재개해 주세요.")
        case "powerConflict": L("Another power setting is active. Resolve it before resuming.", "다른 절전 방지 설정이 활성화돼 있습니다. 충돌을 해결한 뒤 재개해 주세요.")
        case "powerUnconfirmed": L("Power return is not confirmed yet. Keep power connected, then retry.", "안정적인 전원 복귀를 아직 확인하지 못했습니다. 연결을 유지한 뒤 다시 시도해 주세요.")
        case "sessionUnavailable": L("Open Tether to manage this session.", "Tether 앱을 열어 관리 세션을 연결해 주세요.")
        case "guiSessionUnavailable": L("This graphical login cannot currently control Tether. No new power request was made.", "현재 로그인 세션의 제어 권한을 확인할 수 없습니다. 새 작업 유지 요청은 적용하지 않았습니다.")
        case "powerVerificationFailed": L("The power change was not confirmed. Review diagnostics.", "전원 설정 적용을 확인하지 못했습니다. 진단을 확인해 주세요.")
        case "powerObservationUnavailable": L("The current lid, wake or sleep setting could not be read. Recovery records are retained; retry after observation recovers.", "덮개·깨움·절전 설정을 읽지 못했습니다. 복구 기록은 보존되며, 상태가 확인된 뒤 다시 시도할 수 있습니다.")
        case "bootSessionUnavailable": protectionReason(code)
        case "paused": L("Tether is paused. Resume it first.", "Tether가 중지되어 있습니다. 먼저 재개해 주세요.")
        case "notOwner", "unauthorized": L("This request is not allowed for this user.", "이 사용자에게 허용되지 않은 요청입니다.")
        case "staleRevision": L("Settings changed meanwhile. Try again.", "그사이에 설정이 바뀌었습니다. 다시 시도해 주세요.")
        case "holdAlreadyRunning": L("A timer is already running. Extend or end it first.", "이미 타이머가 실행 중입니다. 연장하거나 먼저 끝내 주세요.")
        case "acRequired": L("Unlimited manual sessions require connected power.", "무제한 수동 세션은 전원이 연결돼 있을 때 시작할 수 있습니다.")
        case "manualBatteryBudget": L("The manual battery allowance is exhausted. Keep power connected to renew it.", "수동 세션의 배터리 시간 한도를 소진했습니다. 전원을 연결해 유지한 뒤 다시 시작해 주세요.")
        case "pmsetTimeout": L("The power command timed out. Check System & Diagnostics.", "전원 명령 응답 시간이 초과됐습니다. 시스템·진단을 확인해 주세요.")
        case "pmsetFailed": L("macOS did not accept the power change.", "macOS가 전원 설정 변경을 받아들이지 않았습니다.")
        case "powerWriterUnresolved": L("A previous power command has not been safely resolved. New changes are paused; the recovery record is retained.", "이전 전원 명령의 종료를 확인하지 못했습니다. 새 변경을 보류하고 복구 기록을 보존합니다.")
        case "recoveryLockBusy": L("Another power recovery or helper update is in progress. Try again after it finishes.", "전원 복구 또는 도우미 업데이트가 진행 중입니다. 완료 후 다시 시도해 주세요.")
        case "recoveryLockUnavailable": L("The power recovery lock could not be verified. Power changes are paused.", "전원 복구 기록의 보호 상태를 확인하지 못해 변경을 보류합니다.")
        case "lowPowerUnreadable": L("Low Power Mode could not be read; its setting was left alone.", "저전력 모드를 확인하지 못해 설정을 변경하지 않았습니다.")
        case "writeFailed": L("The helper could not save the change.", "도우미가 변경을 저장하지 못했습니다.")
        case "configurationUnreadable", "stateUnreadable": L("Saved state could not be read. Review the backup before resuming.", "저장된 상태를 읽지 못했습니다. 백업을 확인한 뒤 재개해 주세요.")
        case "statusWriteFailed": L("The helper could not publish its state.", "도우미가 상태를 저장하지 못했습니다.")
        case "unsupportedVersion": L("Update the app, CLI and helper together.", "앱·CLI·도우미를 함께 업데이트해 주세요.")
        default: L("The request failed: \(code)", "요청 실패: \(code)")
        }
    }
}

/// A bounded, newline-framed JSON protocol over a local Unix socket in a protected folder.
/// Only fixed operations are accepted; requests never carry executable paths or shell commands.
enum ServiceWire {
    static let maxBytes = 256 * 1024
    static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path), !path.utf8.contains(0) else { throw ServiceFailure("socketPathTooLong") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    static func options(_ fd: Int32) {
        // Darwin's accepted sockets inherit O_NONBLOCK from the listener. Each bounded worker
        // needs blocking reads with a timeout; otherwise a newly connected client can lose a
        // race before sending its first frame and be disconnected with EAGAIN.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    static func receive<T: Decodable>(_ type: T.Type, fd: Int32, timeout: Double = 4) throws -> T {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = ContinuousTime.now + timeout
        while data.count <= maxBytes, ContinuousTime.now < deadline {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw ServiceFailure("connectionClosed") }
            data.append(contentsOf: buffer.prefix(n))
            guard data.count <= maxBytes else { throw ServiceFailure("requestTooLarge") }
            if let end = data.firstIndex(of: 10) {
                guard end == data.count - 1 else { throw ServiceFailure("invalidFrame") }
                return try JSONDecoder().decode(type, from: data.prefix(end))
            }
        }
        throw ServiceFailure("requestTooLarge")
    }
    static func send<T: Encodable>(_ value: T, fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        guard data.count < maxBytes else { throw ServiceFailure("replyTooLarge") }
        data.append(10)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ServiceFailure("connectionClosed") }
                offset += count
            }
        }
    }
}

public struct ServiceClient {
    public let path: String
    public init(path: String = TetherPaths.serviceSocket) { self.path = path }
    public func call(_ request: ServiceRequest) throws -> ServiceReply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServiceFailure("unavailable") }
        defer { close(fd) }
        ServiceWire.options(fd)
        guard try ServiceWire.address(path, { connect(fd, $0, $1) }) == 0 else { throw ServiceFailure("unavailable") }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0,
              uid == 0 || (path != TetherPaths.productionSocket && uid == geteuid()) else { throw ServiceFailure("unauthorized") }
        try ServiceWire.send(request, fd: fd)
        let reply = try ServiceWire.receive(ServiceReply.self, fd: fd)
        guard reply.id == request.id, reply.version == 2 else { throw ServiceFailure("unsupportedVersion") }
        return reply
    }
    public func perform(_ request: ServiceRequest) throws -> ServiceReply {
        let reply = try call(request)
        guard reply.ok else { throw ServiceFailure(reply.error ?? "failed") }
        return reply
    }
    public func updateControl(_ change: (inout Control) -> Void) -> Bool {
        for _ in 0..<8 {
            guard let before = try? perform(ServiceRequest(.snapshot)) else { return false }
            var next = before.control
            change(&next)
            var request = ServiceRequest(.configure)
            request.control = next; request.epoch = before.epoch; request.revision = before.revision
            guard let reply = try? call(request) else { return false }
            if reply.ok { return true }
            if reply.error != "staleRevision" { return false }
        }
        return false
    }
}

public final class LocalService {
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let path: String
    private let slots = DispatchSemaphore(value: 16)
    private let queue = DispatchQueue(label: "tether.service.accept")
    public init(path: String) { self.path = path }

    public func start(_ handle: @escaping (ServiceRequest, UInt32) -> ServiceReply) throws {
        // The caller owns and secures the folder. Never unlink an unexpected file.
        var old = stat()
        if lstat(path, &old) == 0 {
            guard old.st_mode & S_IFMT == S_IFSOCK, old.st_uid == geteuid() else { throw ServiceFailure("unsafeSocket") }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServiceFailure("unavailable") }
        listener = fd
        ServiceWire.options(fd)
        guard try ServiceWire.address(path, { bind(fd, $0, $1) }) == 0 else { close(fd); listener = -1; throw ServiceFailure("bindFailed") }
        if geteuid() == 0 {
            chown(path, 0, getgrnam("admin")?.pointee.gr_gid ?? 80)
            chmod(path, 0o660)
        } else { chmod(path, 0o600) }
        guard listen(fd, 16) == 0 else { stop(); throw ServiceFailure("listenFailed") }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                guard self.slots.wait(timeout: .now()) == .success else { close(client); continue }
                ServiceWire.options(client)
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { close(client); self.slots.signal() }
                    var uid: uid_t = 0, gid: gid_t = 0
                    guard getpeereid(client, &uid, &gid) == 0, Self.authorized(uid),
                          var request = try? ServiceWire.receive(ServiceRequest.self, fd: client) else { return }
                    var pid: Int32 = 0
                    var size = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 {
                        request.authenticatedPID = pid
                        request.authenticatedGUILogin = GUISessionProbe.peer(fd: client, uid: uid, pid: pid)
                    }
                    // Policy state remains confined to the helper's main queue.
                    let reply = DispatchQueue.main.sync { handle(request, uid) }
                    try? ServiceWire.send(reply, fd: client)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }
    public func stop() {
        if let source { source.cancel(); self.source = nil } else if listener >= 0 { close(listener) }
        if listener >= 0 { unlink(path); listener = -1 }
    }
    deinit { stop() }

    private static func authorized(_ uid: uid_t) -> Bool {
        if uid == 0 || (geteuid() != 0 && uid == geteuid()) { return true }
        guard geteuid() == 0 else { return false }
        // Socket permissions enforce group access too; verify supplementary membership explicitly.
        return membershipLock.withLock {
            guard let account = getpwuid(uid) else { return false }
            let name = String(cString: account.pointee.pw_name), primary = account.pointee.pw_gid
            var count: Int32 = 128
            var groups = [Int32](repeating: 0, count: Int(count))
            guard getgrouplist(name, Int32(bitPattern: primary), &groups, &count) >= 0 else { return false }
            let admin = getgrnam("admin")?.pointee.gr_gid ?? 80
            return groups.prefix(Int(count)).contains(Int32(bitPattern: admin))
        }
    }
    private static let membershipLock = NSLock()
}
