import Darwin
import Foundation

/// Only process metadata is collected: no argv, environment, model names or conversation data.
public struct PowerProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let started: UInt64
    public let executable: String?
    public init(pid: Int32, started: UInt64, executable: String?) {
        self.pid = pid; self.started = started; self.executable = executable
    }

    public static func read(_ pid: Int32) -> Self? {
        guard let started = startTime(pid) else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is (4 * MAXPATHLEN), which Swift cannot import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let size = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = size > 0 ? URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path : nil
        guard startTime(pid) == started else { return nil }
        return Self(pid: pid, started: started, executable: path)
    }

    private static func startTime(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}

public struct PowerRunningApp: Equatable, Sendable {
    public let pid: Int32
    public let started: UInt64
    public let name: String
    public let bundlePath: String
    public init(pid: Int32, started: UInt64, name: String, bundlePath: String) {
        self.pid = pid; self.started = started; self.name = name; self.bundlePath = bundlePath
    }
}

public enum PowerRequestOwnership {
    /// An Electron helper inside the running app bundle is attributable. A shell ancestor,
    /// generic "Electron" name, caffeinate target or neighbouring path is not proof.
    public static func app(for process: PowerProcessIdentity, among apps: [PowerRunningApp]) -> PowerRunningApp? {
        if let direct = apps.first(where: { $0.pid == process.pid && $0.started == process.started }) { return direct }
        guard let path = process.executable, path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { return nil }
        let matches = apps.filter {
            $0.pid != process.pid && $0.bundlePath.hasPrefix("/") && $0.bundlePath.hasSuffix(".app") &&
            URL(fileURLWithPath: $0.bundlePath).standardizedFileURL.path == $0.bundlePath &&
            path.hasPrefix($0.bundlePath + "/Contents/")
        }
        guard let outer = matches.min(by: { $0.bundlePath.count < $1.bundlePath.count }),
              matches.filter({ $0.bundlePath == outer.bundlePath }).count == 1 else { return nil }
        return outer
    }
}
