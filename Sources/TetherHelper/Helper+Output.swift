import Foundation
import TetherCore

/// pmset, the status file, events and the log.
extension Helper {
    func pmset(_ arguments: [String]) {
        if dryRun {
            log("[dry-run] pmset \(arguments.joined(separator: " "))")
            return
        }
        let result = Shell.run("/usr/bin/pmset", arguments)
        if result.status != 0 {
            log("error: pmset \(arguments.joined(separator: " ")) exited \(result.status): \(result.output)")
        }
    }

    func writeStatus(readings r: SafetyReadings) {
        let s = currentSnapshot()
        let hold = holdWasActive
            ? state.holdDeadline(requested: control.batteryHoldUntil, now: Date(),
                                 maxHold: SafetyPolicy.maxHold(limits))?.timeIntervalSince1970
            : nil
        var status = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
                            enabled: control.enabled, power: s.power, lidClosed: s.lidClosed,
                            sleepDisabled: s.sleepDisabled, lastEvent: lastEvent, lastEventAt: lastEventAt,
                            batteryHoldUntil: hold, batteryTemperature: r.temperature, thermal: r.thermal,
                            batteryPercent: r.batteryPercent)
        status.lastHoldEnd = lastHoldEnd
        status.lastHoldEndAt = lastHoldEndAt
        status.batteryHoldSince = hold == nil ? nil : state.holdSeenAt
        status.heatGuard = state.savedACLowPower != nil
        status.thermalAlertAt = thermalAlertAt
        status.overheatSleepAt = overheatSleepAt
        status.weakChargerSleepAt = weakChargerSleepAt
        if JSONFile.write(status, to: statusPath, permissions: 0o644) {
            DarwinNotification.post(TetherPaths.statusChanged)
        }
    }

    func note(_ event: EventKind) {
        lastEvent = event
        lastEventAt = Date().timeIntervalSince1970
        if event != .started { log(event.logText) }
    }

    static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func log(_ message: String) {
        print("\(Self.stampFormat.string(from: Date())) \(message)")
    }

    /// launchd appends to the log forever, and detailed logging adds a line per check: start over
    /// past 2 MB. (main.swift does the same at 1 MB when the helper starts.)
    func trimLogIfNeeded() {
        var info = stat()
        guard fstat(STDOUT_FILENO, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 2_000_000 else { return }
        ftruncate(STDOUT_FILENO, 0)
        log("log trimmed at 2 MB")
    }
}
