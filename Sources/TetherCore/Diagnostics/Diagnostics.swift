import Foundation

/// A Markdown report for troubleshooting, written for people and AI assistants alike: it opens
/// with how Tether is meant to behave, then the state, settings, records and logs to check that
/// against. Names that identify the user or the Mac are masked.
public enum Diagnostics {
    /// Builds the report. `since` limits the logs (e.g. the start of a `--record` session);
    /// otherwise the last `hours` are included. Runs `pmset` and `log`, so it takes a few seconds.
    public static func report(appVersion: String?, since: Date? = nil, hours: Double = 24) -> String {
        let now = Date()
        let from = since ?? now.addingTimeInterval(-hours * 3600)
        let status = JSONFile.read(Status.self, from: TetherPaths.statusPath)
        let control = JSONFile.read(Control.self, from: TetherPaths.controlPath)
        let usage = JSONFile.read(Usage.self, from: TetherPaths.usagePath)
        let snapshot = SystemProbe.snapshot()
        let readings = SystemProbe.safetyReadings()
        let lowPower = SystemProbe.lowPowerModes()
        let installed = FileManager.default.fileExists(atPath: TetherPaths.helperPlistPath)
        let responding = status.map { now.timeIntervalSince1970 - $0.updatedAt < 90 } ?? false

        var out: [String] = []
        out.append("# Tether diagnostic report")
        out.append("")
        out.append("Generated \(stamp(now)) · app \(appVersion ?? "unknown") · helper \(status?.version ?? "not running")"
                   + " · macOS \(osVersion()) · \(model())")
        out.append("Logs from \(stamp(from))\(since == nil ? " (last \(String(format: "%g", hours)) h)" : " (recording)").")
        out.append("")
        out.append("## Checks")
        out.append("")
        for check in HealthChecks.run(now: now, language: .english) {
            out.append("- [\(check.result.rawValue.uppercased())] \(check.name): \(check.detail)")
        }
        out.append("")
        out.append(expectations)

        out.append("## State now")
        out.append("")
        out.append("| | |")
        out.append("|---|---|")
        let rows: [(String, String)] = [
            ("supported Mac (battery and lid)", yes(SystemProbe.isSupportedMac)),
            ("helper installed / responding", "\(yes(installed)) / \(yes(responding))"),
            ("Tether enabled", control.map { yes($0.enabled) } ?? "? (no control file)"),
            ("power", snapshot.power.rawValue),
            ("lid", snapshot.lidClosed ? "closed" : "open"),
            ("SleepDisabled (clamshell)", yes(snapshot.sleepDisabled)),
            ("full wake", yes(snapshot.fullWake)),
            ("external display keeps a closed Mac awake", yes(snapshot.externalDisplay)),
            ("battery", readings.batteryPercent.map { "\($0)%" } ?? "?"),
            ("battery temperature", readings.temperature.map { String(format: "%.1f °C", $0) } ?? "unreadable"),
            ("thermal pressure", "\(readings.thermal) (\(thermalName(readings.thermal)))"),
            ("Low Power Mode battery / AC", "\(lowPower.battery.map(String.init) ?? "?") / \(lowPower.ac.map(String.init) ?? "?")"),
            ("battery hold until", status?.batteryHoldUntil.map { stamp(Date(timeIntervalSince1970: $0)) } ?? "none"),
            ("battery hold source", control?.holdSource ?? "-"),
            ("heat guard active", yes(status?.heatGuard == true)),
            ("last event", status?.lastEvent.map { "\($0.rawValue) at \(status?.lastEventAt.map { stamp(Date(timeIntervalSince1970: $0)) } ?? "?")" } ?? "-"),
            ("last hold end", status?.lastHoldEnd.map { "\($0.rawValue) at \(status?.lastHoldEndAt.map { stamp(Date(timeIntervalSince1970: $0)) } ?? "?")" } ?? "-"),
            ("app path reported to the helper", control?.appPath ?? "-"),
        ]
        for (key, value) in rows { out.append("| \(key) | \(value) |") }
        out.append("")

        out.append("## Limits in force")
        out.append("")
        let closed = SafetyPolicy.limits(lidClosed: true, user: control?.limits)
        let open = SafetyPolicy.limits(lidClosed: false, user: control?.limits)
        let heat = control?.heatGuard ?? .standard
        out.append("- Battery hold, lid closed: end at \(Int(closed.hardTemperature)) °C at once, or after 60 s at "
                   + "\(Int(closed.earlyTemperature ?? 0)) °C or thermal ≥ 2; thermal 3 at once.")
        out.append("- Battery hold, lid open: end at \(Int(open.hardTemperature)) °C or thermal 3.")
        out.append("- Battery floor \(SafetyPolicy.floor(control?.limits))%, longest hold \(SafetyPolicy.maxHold(control?.limits) / 3600) h.")
        out.append("- Low Power Mode during battery holds: \(control?.holdLowPower == false ? "off" : "on").")
        out.append("- Heat guard: \(heat.enabled ? "on, Low Power Mode from thermal \(heat.threshold)" : "off"); "
                   + "overheat sleep (no external display, critical 2 min or battery ≥ \(Int(ACThermalPolicy.hotBattery)) °C 1 min) is always on.")
        out.append("")

        out.append("## Settings (control.json)")
        out.append("")
        out.append("```json")
        out.append(control.flatMap(prettyJSON) ?? "(missing)")
        out.append("```")
        out.append("")

        let blockers = SystemProbe.sleepBlockers()
        out.append("## Power assertions (who keeps the Mac or display awake)")
        out.append("")
        if blockers.isEmpty {
            out.append("None besides powerd.")
        } else {
            for b in blockers { out.append("- \(b.process) (pid \(b.pid)): \(b.kind.rawValue) · \(b.reason)") }
        }
        out.append("")

        if let usage {
            out.append("## Recent sleeps (Tether's sleep log)")
            out.append("")
            if usage.sleeps.recent.isEmpty {
                out.append("None recorded yet (sleeps on battery of 30 min or more).")
            } else {
                out.append("| slept | duration | charge | per hour | sleep reason | by Tether | wake type / reason | dark wakes |")
                out.append("|---|---|---|---|---|---|---|---|")
            }
            for r in usage.sleeps.recent.suffix(12) {
                let charge = "\(r.percentBefore.map(String.init) ?? "?")→\(r.percentAfter.map(String.init) ?? "?")%"
                    + (r.onBatteryBefore && r.onBatteryAfter == true ? "" : " (power)")
                out.append("| \(stamp(Date(timeIntervalSince1970: r.sleptAt))) | \(Int((r.duration ?? 0) / 60)) min | \(charge) | "
                           + "\(r.drainPerHour.map { String(format: "%.1f%%", $0) } ?? "-") | \(r.sleepReason ?? "?") | \(yes(r.byTether)) | "
                           + "\(r.wakeType ?? "?") / \(r.wakeReason ?? "?") | \(r.darkWakes) |")
            }
            out.append("")
            out.append("## Recent lid sessions")
            out.append("")
            if usage.recentSessions.isEmpty { out.append("None yet (lid closed while awake for 5 min or more).") }
            for s in usage.recentSessions.suffix(8) {
                out.append("- \(stamp(Date(timeIntervalSince1970: s.start))): \(Int(s.duration / 60)) min, peak "
                           + "\(s.maxTemperature.map { String(format: "%.1f °C", $0) } ?? "?"), thermal \(s.maxThermal), charge "
                           + "\(s.batteryStart.map(String.init) ?? "?")→\(s.batteryEnd.map(String.init) ?? "?")%, low power \(yes(s.lowPower)), "
                           + "battery \(yes(s.onBattery))")
            }
            out.append("")
            out.append("## Last 7 days")
            out.append("")
            out.append("| day | lid closed awake | forced sleeps | holds | heat guards | closed peak / usual °C | open peak °C |")
            out.append("|---|---|---|---|---|---|---|")
            for d in usage.stats.week(now: now) {
                out.append("| \(d.day) | \(Int(d.lidClosedSeconds / 60)) min | \(d.forcedSleeps) | \(d.batteryHolds) | \(d.heatGuards) | "
                           + "\(d.closedTemps?.max.map { String(format: "%.1f", $0) } ?? "-") / \(d.closedTemps?.percentile(0.5).map { String(format: "%.0f", $0) } ?? "-") | "
                           + "\(d.openTemps?.max.map { String(format: "%.1f", $0) } ?? "-") |")
            }
            out.append("")
        }

        out.append("## Helper log")
        out.append("")
        out.append("```")
        out.append(helperLog(since: from).joined(separator: "\n"))
        out.append("```")
        out.append("")
        out.append("## macOS power log (sleep, wake and Tether assertions)")
        out.append("")
        out.append("```")
        out.append(powerLog(since: from).joined(separator: "\n"))
        out.append("```")
        out.append("")
        out.append("## App log")
        out.append("")
        out.append("```")
        out.append(appLog(since: from))
        out.append("```")
        return redact(out.joined(separator: "\n"))
    }

    // MARK: Pieces

    static let expectations = """
    ## How Tether should behave (compare the logs against this)

    - On power: the helper sets `SleepDisabled` (log: "power connected: clamshell on"). The Mac stays awake with the lid closed and the app keeps the display from sleeping, so nothing locks; with no external display it dims the built-in screen instead.
    - Unplugged: the helper clears `SleepDisabled` ("power disconnected: clamshell off"). If the lid is already closed it asks for sleep ("lid already closed: sleeping"; powerd then waits about 5 s, `darkwakelinger`).
    - Battery hold: clamshell stays on on battery until the time is up or a safety limit ends it ("battery hold ended: …"), then a closed Mac sleeps. Holds never survive a helper restart.
    - Heat guard: on power with the lid closed, thermal pressure at the threshold turns AC Low Power Mode on; it is restored after 2 cool minutes or when the lid opens.
    - Safety net on power with the lid closed and no external display: critical heat for 2 min, a battery at 45 °C for 1 min, or a battery at the floor still draining for 1 min (a charger that can't keep up) puts the Mac to sleep ("putting the Mac to sleep").
    - Dark wakes: clamshell mode is only turned on in a full wake, so a Mac put to sleep on power goes back to sleep after Power Nap wakes.
    - The switch: off (control.json "enabled": false) lasts until power is connected again, when the helper turns it back on ("clamshell mode switched back on").
    - "Sleep now" is cancelled by any input during powerd's pre-sleep window; the app waits for input to settle first.
    - Idle-sleep assertions from other apps (see "Power assertions") do not stop lid-close sleep or Tether's own sleep, but keep an open Mac awake on battery.
    - Desktop Macs (no battery or lid): Tether changes nothing.
    - Sleep log: "per hour" above 3% means something kept waking the Mac; see wake reasons and dark wakes.

    """

    /// The helper's log lines from `since` on (at most the last 400), plus the line before, so
    /// the state going in is visible.
    static func helperLog(since: Date) -> [String] {
        guard let text = try? String(contentsOfFile: TetherPaths.helperLog, encoding: .utf8) else {
            return ["(no helper log at \(TetherPaths.helperLog))"]
        }
        let lines = linesSince(text, since: since, format: "yyyy-MM-dd HH:mm:ss", width: 19).suffix(400)
        return lines.isEmpty ? ["(nothing logged in this window)"] : Array(lines)
    }

    static func powerLog(since: Date) -> [String] {
        let text = Shell.run("/usr/bin/pmset", ["-g", "log"]).output
        let keep = linesSince(text, since: since, format: "yyyy-MM-dd HH:mm:ss Z", width: 25)
            .filter(isInterestingPowerLine)
            .map { $0.replacingOccurrences(of: "\t", with: "  ").trimmingCharacters(in: .whitespaces) }
        return keep.isEmpty ? ["(no sleep, wake or Tether entries in this window)"] : Array(keep.suffix(300))
    }

    /// `pmset -g log` lines are "<25-char timestamp> <kind, padded>\t<message>". Keep sleep and
    /// wake events and Tether's own entries; drop other apps' assertion churn and the periodic
    /// "Summary" repeats of assertions already listed.
    public static func isInterestingPowerLine(_ line: String) -> Bool {
        let head = line.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
        let kind = head.count > 26 ? String(head.dropFirst(26)).trimmingCharacters(in: .whitespaces) : ""
        if ["Sleep", "Wake", "DarkWake", "Failure", "Wake Requests", "Kernel Client Acks"].contains(kind) { return true }
        if kind == "Assertions" && line.contains(") Summary ") { return false }
        return line.contains("Tether") || line.contains("local.tether") || line.contains("Display is turned")
    }

    static func appLog(since: Date) -> String {
        let minutes = max(1, Int(Date().timeIntervalSince(since) / 60) + 1)
        let result = Shell.run("/usr/bin/log", ["show", "--style", "compact", "--last", "\(minutes)m",
                                                "--predicate", "subsystem == \"\(TetherPaths.logSubsystem)\""])
        let lines = result.output.split(separator: "\n").filter { !$0.hasPrefix("Timestamp") }.suffix(300)
        return lines.isEmpty ? "(no app log entries)" : lines.joined(separator: "\n")
    }

    /// Lines whose leading timestamp (in `format`) is at or after `since`; undated lines follow
    /// the dated line before them.
    public static func linesSince(_ text: String, since: Date, format: String, width: Int) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        var keep = false
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.count >= width, let date = formatter.date(from: String(line.prefix(width))) {
                keep = date >= since
            }
            if keep { out.append(String(line)) }
        }
        return out
    }

    /// Masks the user's name, home folder and the Mac's name.
    public static func redact(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName(),
                              fullName: String = NSFullUserName(), host: String = ProcessInfo.processInfo.hostName) -> String {
        var s = text.replacingOccurrences(of: home, with: "~")
        s = s.replacingOccurrences(of: "/Users/\(user)", with: "/Users/<user>")
        let hostShort = host.components(separatedBy: ".").first ?? host
        for (value, mask) in [(fullName, "<name>"), (hostShort, "<host>"), (user, "<user>")] where value.count >= 3 {
            s = s.replacingOccurrences(of: value, with: mask)
        }
        return s
    }

    private static func prettyJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.string(from: date)
    }

    private static func yes(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func thermalName(_ level: Int) -> String {
        ["nominal", "fair", "serious", "critical"][min(3, max(0, level))]
    }

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let build = Shell.run("/usr/bin/sw_vers", ["-buildVersion"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(build))"
    }

    private static func model() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
