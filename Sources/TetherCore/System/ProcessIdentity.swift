import Darwin
import Foundation

/// PID alone is not a process identity. Failed inspection is distinct from confirmed exit.
public struct ProcessIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    public var uid: UInt32
    public var started: UInt64
    public var executable: String

    public static func capture(pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is a compound C macro not imported by Swift.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return Self(pid: pid, uid: info.pbi_uid,
                    started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                    executable: String(cString: path))
    }

    public static func exited(pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == -1, errno == ESRCH { return true }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status == SZOMB
    }

    public func matchesLifetime(_ other: Self) -> Bool {
        pid == other.pid && uid == other.uid && started == other.started
    }

    public static func sameExecutable(_ left: String, _ right: String) -> Bool {
        var a = stat(), b = stat()
        return stat(left, &a) == 0 && stat(right, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
}
