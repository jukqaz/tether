import Foundation
import TetherCore

/// Removing an orphaned helper once the app is gone.
extension Helper {
    /// An app dragged to the Trash leaves this root helper behind, which would go on preventing
    /// sleep on power with nothing dimming the screen. Once the app has been gone for the grace
    /// period, restore normal sleep and remove the helper. Returns true when retiring.
    func retireIfAppIsGone() -> Bool {
        let path = control.appPath
        let exists = path.map { FileManager.default.fileExists(atPath: $0) } ?? true
        guard appPresence.shouldRetire(path: path, exists: exists, now: Date()), let path else { return false }
        log("Tether.app has been gone for \(Int(AppPresence.grace / 60)) minutes (\(path)): restoring normal sleep and removing the helper")
        if currentSnapshot().sleepDisabled { pmset(["-a", "disablesleep", "0"]) }
        manageLowPower(on: false)
        manageACLowPower(on: false, readings: currentReadings())
        if dryRun {
            log("[dry-run] would remove the helper, its files and login items, then boot out")
            appPresence = AppPresence()
            return true
        }
        let fm = FileManager.default
        Shell.run("/bin/launchctl", ["bootout", "system/\(TetherPaths.watchdogLabel)"])
        for file in [TetherPaths.helperPlistPath, TetherPaths.helperPath, TetherPaths.watchdogPlistPath,
                     TetherPaths.watchdogPath, TetherPaths.supportDirectory] {
            try? fm.removeItem(atPath: file)
        }
        // The `tether` links and per-user login items that pointed into the app.
        var links = ["/usr/local/bin/tether"]
        var agents: [String] = []
        for user in (try? fm.contentsOfDirectory(atPath: "/Users")) ?? [] {
            links.append("/Users/\(user)/.local/bin/tether")
            agents.append("/Users/\(user)/Library/LaunchAgents/local.tether.app.plist")
        }
        for link in links where (try? fm.destinationOfSymbolicLink(atPath: link))?.hasSuffix("Tether.app/Contents/Helpers/tether") == true {
            try? fm.removeItem(atPath: link)
        }
        for agent in agents where (NSDictionary(contentsOfFile: agent)?["ProgramArguments"] as? [String])?.first == path {
            try? fm.removeItem(atPath: agent)
        }
        log("helper removed")
        // launchd stops this job (SIGTERM, handled by `stop`); exit in case it has not yet.
        Shell.run("/bin/launchctl", ["bootout", "system/\(TetherPaths.helperLabel)"])
        exit(0)
    }
}
