import Darwin
import Foundation
import Security

/// UID identifies an account; this OS-assigned ID identifies one graphical login.
/// Neither an account name nor a client-supplied session identifier is an authority.
public struct GUISessionIdentity: Codable, Equatable, Sendable {
    public let uid: UInt32
    public let sessionID: UInt32
    public init(uid: UInt32, sessionID: UInt32) { self.uid = uid; self.sessionID = sessionID }
    public var isValid: Bool { uid != 0 && uid != UInt32.max && sessionID != 0 && sessionID != UInt32.max }
}

public struct GUISessionOwner: Codable, Equatable, Sendable {
    public let bootID: String
    public let process: ProcessIdentity
    public let login: GUISessionIdentity
    public init(bootID: String, process: ProcessIdentity, login: GUISessionIdentity) {
        self.bootID = bootID; self.process = process; self.login = login
    }
    public func matches(process current: ProcessIdentity?, boot: String) -> Bool {
        guard login.isValid, !boot.isEmpty, boot == bootID, let current,
              current.uid == login.uid, process.matchesLifetime(current) else { return false }
        return ProcessIdentity.sameExecutable(process.executable, current.executable)
    }
}

public struct GUISessionObservation: Equatable, Sendable {
    public let login: GUISessionIdentity?
    public let consoleUID: UInt32?
    public init(login: GUISessionIdentity?, consoleUID: UInt32?) { self.login = login; self.consoleUID = consoleUID }
}

public enum GUISessionAuthorityStatus: String, Codable, Sendable { case confirmed, unavailable, revoked }

/// An unavailable observation can preserve an already-owned request for a bounded interval.
/// It never grants a new request or extends this deadline. Screen lock is deliberately not
/// an input: it does not identify a different graphical login.
public struct GUISessionAuthority: Equatable, Sendable {
    public static let observationTTL: Double = 30
    public private(set) var login: GUISessionIdentity?
    public private(set) var status: GUISessionAuthorityStatus = .unavailable
    public private(set) var confirmedUntil: Double?
    private var lastObservation: Double?
    public init(login: GUISessionIdentity? = nil) { self.login = login }
    public var canAcquire: Bool { status == .confirmed }
    public mutating func bind(_ login: GUISessionIdentity) { self = Self(login: login.isValid ? login : nil) }
    public mutating func observe(_ observation: GUISessionObservation, now: Double) {
        // Neither a failed clock observation nor the old login returning may
        // resurrect revoked authority. Only an explicit fresh bind can do that.
        guard status != .revoked else { return }
        guard now.isFinite, now >= 0, lastObservation.map({ now >= $0 }) ?? true,
              let login, login.isValid else { status = .unavailable; confirmedUntil = nil; return }
        lastObservation = now
        if observation.consoleUID.map({ $0 != login.uid }) == true
            || observation.login.map({ $0 != login }) == true {
            status = .revoked; confirmedUntil = nil; return
        }
        let deadline = now + Self.observationTTL
        if observation.login == login, observation.consoleUID == login.uid,
           deadline.isFinite, deadline > now {
            status = .confirmed; confirmedUntil = deadline
        } else { status = .unavailable }
    }
    public func canPreserveExisting(now: Double) -> Bool {
        guard now.isFinite, now >= 0, lastObservation.map({ now >= $0 }) ?? true,
              status != .revoked, let confirmedUntil else { return false }
        return now < confirmedUntil
    }
    public func expiry(_ desired: Double?, existing: Bool, now: Double) -> Double? {
        guard let desired, canPreserveExisting(now: now), canAcquire || existing,
              let confirmedUntil else { return nil }
        return min(desired, confirmedUntil)
    }
}

public enum GUISessionProbe {
    /// Read-only Security API, including in a root daemon. A network-origin GUI is
    /// accepted when graphics are available; a non-graphical SSH/system login is not.
    public static func graphical(_ login: GUISessionIdentity) -> GUISessionIdentity? {
        guard login.isValid else { return nil }
        var actual: SecuritySessionId = 0
        var attributes = SessionAttributeBits()
        guard SessionGetInfo(login.sessionID, &actual, &attributes) == errSecSuccess,
              actual == login.sessionID, attributes.contains(.sessionHasGraphicAccess),
              !attributes.contains(.sessionIsRoot) else { return nil }
        return login
    }
    public static func caller() -> GUISessionIdentity? {
        var actual: SecuritySessionId = 0
        var attributes = SessionAttributeBits()
        var audit = auditinfo_addr()
        guard SessionGetInfo(callerSecuritySession, &actual, &attributes) == errSecSuccess,
              attributes.contains(.sessionHasGraphicAccess), !attributes.contains(.sessionIsRoot),
              getaudit_addr(&audit, Int32(MemoryLayout.size(ofValue: audit))) == 0,
              audit.ai_auid == getuid(), UInt32(bitPattern: audit.ai_asid) == actual else { return nil }
        let login = GUISessionIdentity(uid: getuid(), sessionID: actual)
        return login.isValid ? login : nil
    }
    public static func callerObservation() -> GUISessionObservation {
        GUISessionObservation(login: caller(), consoleUID: SystemProbe.consoleUserID)
    }
    /// LOCAL_PEERTOKEN belongs to this connected socket; JSON cannot replace it.
    public static func peer(fd: Int32, uid: UInt32, pid: Int32) -> GUISessionIdentity? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout.size(ofValue: token))
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == MemoryLayout.size(ofValue: token), audit_token_to_pid(token) == pid,
              audit_token_to_euid(token) == uid, audit_token_to_ruid(token) == uid,
              audit_token_to_auid(token) == uid else { return nil }
        return graphical(GUISessionIdentity(uid: uid, sessionID: UInt32(bitPattern: audit_token_to_asid(token))))
    }
}
