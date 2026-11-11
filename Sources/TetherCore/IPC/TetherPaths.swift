import Foundation

public enum TetherPaths {
    public static let version = "2026.11.1"
    public static let build = 60
    public static let supportDirectory = "/Library/Application Support/Tether"
    public static let controlPath = supportDirectory + "/control.json"
    public static let productionSocket = supportDirectory + "/service.sock"
    /// An explicit override connects a development CLI/UI to an unprivileged dry-run helper.
    public static var serviceSocket: String { ProcessInfo.processInfo.environment["TETHER_SERVICE_SOCKET"] ?? productionSocket }
    public static let statusPath = supportDirectory + "/status.json"
    /// Root-only bookkeeping that must survive a helper restart.
    public static let helperStatePath = supportDirectory + "/helper-state.json"
    /// Usage stats and lid sessions, written by the helper, world-readable.
    public static let usagePath = supportDirectory + "/usage.json"
    public static let helperLabel = "local.tether.helper"
    public static let helperPath = "/Library/PrivilegedHelperTools/local.tether.helper"
    public static let helperPlistPath = "/Library/LaunchDaemons/local.tether.helper.plist"
    /// A shell script launchd runs every 30 seconds: if the helper has gone silent while sleep is
    /// disabled on either power source, it turns sleep back on. Independent of the helper binary.
    public static let watchdogLabel = "local.tether.watchdog"
    public static let watchdogPath = "/Library/PrivilegedHelperTools/local.tether.watchdog"
    public static let recoveryLockLibraryPath = "/Library/PrivilegedHelperTools/local.tether.recovery-lock"
    public static let recoveryExecutorPath = "/Library/PrivilegedHelperTools/local.tether.power-recovery"
    public static let watchdogPlistPath = "/Library/LaunchDaemons/local.tether.watchdog.plist"
    /// Orphan retirement removes every installed system artifact after restoring power.
    /// The shared recovery lock lives beside the support folder; its inode must survive.
    public static let orphanedSystemArtifactPaths = [
        helperPlistPath, helperPath, watchdogPlistPath, watchdogPath,
        recoveryLockLibraryPath, recoveryExecutorPath, supportDirectory,
    ]
    /// Darwin notification the app posts after writing the control file.
    public static let controlChanged = "local.tether.control"
    /// Darwin notification the helper posts after writing the status file.
    public static let statusChanged = "local.tether.status"
    public static let watchdogStatusPath = supportDirectory + "/watchdog-status.json"
    public static let helperLog = "/Library/Logs/Tether/helper.log"
    /// The menu bar app's bundle identifier; its preferences hold choices the `tether` command
    /// follows too (the language).
    public static let bundleID = "io.github.jukqaz.tether"
    /// Unified-log subsystem the menu bar app writes to (`log show --predicate 'subsystem == …'`).
    public static let logSubsystem = bundleID
}
