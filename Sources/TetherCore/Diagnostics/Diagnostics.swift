import Foundation

/// A Markdown report for troubleshooting, written for people and AI assistants alike: it opens
/// with how Tether is meant to behave, then the state, settings, records and logs to check that
/// against. Names that identify the user or the Mac are masked.
public enum Diagnostics {
    /// Builds the report. `since` limits the logs (e.g. the start of a `--record` session);
    /// otherwise the last `hours` are included. Runs `pmset` and `log`, so it takes a few seconds.
    public static func report(appVersion: String?, since: Date? = nil, hours: Double = 24, includeProcessNames: Bool = false,
                              userSession: UserSessionReply? = nil, userSessionRequested: Bool = false,
                              capabilities: MacCapabilities? = nil, remoteContext: RemoteInteropContext? = nil,
                              commonActivity: UserSessionActivity? = nil) -> String {
        let hours = DiagnosticRecording.reportHours(hours)
        let simulated = TetherPaths.serviceSocket != TetherPaths.productionSocket
        let capabilities = capabilities ?? (simulated ? nil : SystemProbe.capabilities)
        let directory = simulated ? URL(fileURLWithPath: TetherPaths.serviceSocket).deletingLastPathComponent().path : TetherPaths.supportDirectory
        let live = try? ServiceClient().perform(ServiceRequest(.snapshot))
        var status = live?.status ?? JSONFile.read(Status.self, from: directory + "/status.json")
        if let live { status?.protection = live.protection }
        let control = live?.control ?? JSONFile.read(Control.self, from: directory + "/control.json")
        let usage = JSONFile.read(Usage.self, from: directory + "/usage.json")
        var snapshot = simulated ? Snapshot(power: status?.power ?? .unknown, lidClosed: status?.observedLidClosed,
                                           sleepDisabled: status?.observedSleepDisabled, fullWake: status?.fullWake,
                                           externalDisplay: status?.externalDisplay ?? false) : SystemProbe.snapshot()
        if simulated { snapshot.displayTopology = status?.displayTopology ?? .unknown }
        let readings = simulated ? SafetyReadings(temperature: status?.batteryTemperature, thermal: status?.thermal ?? 0,
                                                  batteryPercent: status?.batteryPercent) : SystemProbe.safetyReadings()
        let lowPower: (battery: Int?, ac: Int?) = simulated ? (nil, nil) : SystemProbe.lowPowerModes()
        let installed = !simulated && FileManager.default.fileExists(atPath: TetherPaths.helperPlistPath)
        let responding = live != nil
        let checks = simulated ? [] : HealthChecks.run(language: .english, userSession: userSession,
            userSessionRequested: userSessionRequested, capabilities: capabilities)
        let now = Date()
        let from = min(now, max(now.addingTimeInterval(-72 * 3600), since ?? now.addingTimeInterval(-hours * 3600)))

        var out: [String] = []
        out.append("# Tether diagnostic report")
        out.append("")
        out.append("Generated \(stamp(now)) · app \(appVersion ?? "unknown") build \(TetherPaths.build) · helper \(status?.version ?? "not running") build \(status?.build.map(String.init) ?? "unknown")"
                   + " · macOS \(osVersion()) · \(model())")
        out.append("Logs from \(stamp(from))\(since == nil ? " (last \(String(format: "%g", hours)) h)" : " (recording)").")
        out.append("Scope: \(simulated ? "SIMULATED dry-run; no live power/display/other-app evidence" : "live read-only observation"). Logs are bounded by retention and report limits; gaps are possible.")
        out.append("")
        out.append("## Checks")
        out.append("")
        for check in checks {
            out.append("- [\(check.result.rawValue.uppercased())] \(check.name): \(check.detail)")
        }
        out.append("")
        out.append(expectations(userSessionRequested: userSessionRequested))
        if userSessionRequested {
            out.append(commonSessionReport(userSession, now: now))
            if let commonActivity { out.append(commonActivity.report(since: from)) }
            else if let entries = userSession?.commonActivity { out.append(UserSessionActivity.report(entries: entries, since: from)) }
            else { out.append("Common activity buffer not supplied by this caller; missing events are not proof of inactivity.\n") }
        }
        if let remoteContext {
            out.append("## Remote observations (separate from power checks)")
            out.append("")
            out.append("Captured metadata and per-metric availability; no current remote connection, unlocked screen, frame delivery or input success is implied.")
            out.append(contentsOf: remoteContext.reportLines().map { "- " + $0 })
            out.append("")
        }

        out.append(userSessionRequested ? "## Helper and OS evidence (separate from common work)" : "## State now")
        out.append("")
        out.append("| | |")
        out.append("|---|---|")
        let rows: [(String, String)] = [
            ("supported Apple Silicon / macOS platform", simulated ? "simulated" : yes(SystemProbe.isSupportedMac)),
            ("helper installed / responding", "\(yes(installed)) / \(yes(responding))"),
            ("state source", live == nil ? "saved file only; live connection unverified" : "authenticated service reply"),
            ("observations fresh", yes(HealthChecks.fresh(status?.updatedAt, now: now))),
            (userSessionRequested ? "legacy helper enabled (not the common choice)" : "Tether enabled", control.map { yes($0.enabled) } ?? "? (no control file)"),
            ("power", snapshot.power.rawValue),
            ("battery", readings.batteryPercent.map { "\($0)%" } ?? "?"),
            ("battery temperature", readings.temperature.map { String(format: "%.1f °C", $0) } ?? "unreadable"),
            ("thermal pressure", "\(readings.thermal) (\(thermalName(readings.thermal)))"),
            ("Low Power Mode battery / AC", "\(lowPower.battery.map(String.init) ?? "?") / \(lowPower.ac.map(String.init) ?? "?")"),
            ("battery hold until", status?.batteryHoldUntil.map { stamp(Date(timeIntervalSince1970: $0)) } ?? "none"),
            ("battery hold source", safeHoldSource(control?.holdSource)),
            ("display topology", snapshot.displayTopology.rawValue),
            ("display sleeping (observed)", status?.displaySleeping.map(yes) ?? "unknown"),
            ("app connected", status?.appConnected.map(yes) ?? "unknown"),
            ("protection stop", status?.protection?.blockReason ?? "none reported"),
            ("last apply error", status?.protection?.lastError ?? "none reported"),
            ("detailed logging", control.map { yes($0.debugLoggingActive) } ?? "unknown"),
            ("heat guard active", yes(status?.heatGuard == true)),
            ("last event", status?.lastEvent.map { "\($0.rawValue) at \(status?.lastEventAt.map { stamp(Date(timeIntervalSince1970: $0)) } ?? "?")" } ?? "-"),
            ("last hold end", status?.lastHoldEnd.map { "\($0.rawValue) at \(status?.lastHoldEndAt.map { stamp(Date(timeIntervalSince1970: $0)) } ?? "?")" } ?? "-"),
        ]
        for (key, value) in rows { out.append("| \(key) | \(value) |") }
        for (key, value) in osObservationRows(snapshot, capabilities: capabilities, simulated: simulated) {
            out.append("| \(key) | \(value) |")
        }
        out.append("")

        if !simulated {
        let displayReport = DisplayProbe.inspect()
        out.append("## Display connection evidence")
        out.append("")
        out.append(displayReport.summary)
        out.append(displayReport.guidance)
        for display in displayReport.displays {
            out.append("- \(display.name): \(display.detail). \(display.evidence)")
        }
        if let issue = displayReport.issue { out.append(issue) }
        out.append("")
        }

        out.append("## Limits in force")
        out.append("")
        out.append("- Stop Tether's hold at macOS serious or critical thermal pressure. Explicit resume after nominal/fair and sufficient reserve.")
        out.append("- " + batteryLimitSummary(userSession: userSession, userSessionRequested: userSessionRequested,
            capabilities: capabilities, legacyLimits: control?.limits, now: now))
        out.append("- Battery Celsius is diagnostic only. Energy modes, fans and native external-display clamshell are managed by macOS.")
        if let recovery = status?.displayRecovery {
            out.append("- Display recovery: \(recovery.phase.rawValue), \(recovery.requests)/\(recovery.maximumRequests) requests. OS sleep observations do not measure panel power.")
        }
        out.append("")

        out.append("## Settings (control.json)")
        out.append("")
        out.append("```json")
        var reportControl = control
        reportControl?.appPath = nil
        if let source = reportControl?.holdSource { reportControl?.holdSource = safeHoldSource(source) }
        out.append(reportControl.flatMap(prettyJSON) ?? "(missing)")
        out.append("```")
        out.append("")

        let activity = simulated ? nil : SystemProbe.powerActivitySnapshot()
        let blockers = activity?.blockers
        out.append("## Power assertions (who keeps the Mac or display awake)")
        out.append("")
        out.append(simulated ? "Not collected in dry-run." : assertionSummary(blockers, includeProcessNames: includeProcessNames))
        out.append("")
        out.append("## macOS idle settings and user activity (read only)")
        out.append("")
        out.append(simulated ? "Not collected in dry-run." : powerInfluenceSummary(
            preferences: PowerSleepPreferences.read(), signals: activity?.signals, includeProcessNames: includeProcessNames))
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
                           + "\(r.wakeType ?? "?") / \(r.wakeReason ?? "?") | \(r.darkWakeSummary) |")
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
            out.append("| day | lid closed awake | sleep request attempts | holds | heat guards | closed peak / usual °C | open peak °C |")
            out.append("|---|---|---|---|---|---|---|")
            for d in usage.stats.week(now: now) {
                out.append("| \(d.day) | \(Int(d.lidClosedSeconds / 60)) min | \(d.sleepRequestAttempts) | \(d.batteryHolds) | \(d.heatGuards) | "
                           + "\(d.closedTemps?.max.map { String(format: "%.1f", $0) } ?? "-") / \(d.closedTemps?.percentile(0.5).map { String(format: "%.0f", $0) } ?? "-") | "
                           + "\(d.openTemps?.max.map { String(format: "%.1f", $0) } ?? "-") |")
            }
            out.append("")
            out.append("Sleep-request attempts include refused calls and do not establish completed physical sleep. Legacy totals stored as forcedSleeps are retained.")
            out.append("")
        }

        out.append("## Helper log")
        out.append("")
        out.append("```")
        out.append(helperLog(since: from, path: simulated ? directory + "/helper.log" : TetherPaths.helperLog).joined(separator: "\n"))
        out.append("```")
        out.append("")
        out.append("## macOS power log (sleep, wake and display events)")
        out.append("")
        out.append("```")
        out.append(simulated ? "Not collected in dry-run." : powerLog(since: from).joined(separator: "\n"))
        out.append("```")
        out.append("")
        out.append("## App log")
        out.append("")
        out.append("```")
        out.append(simulated ? "Not collected in dry-run." : appLog(since: from))
        out.append("```")
        return redact(out.joined(separator: "\n"))
    }

    // MARK: Pieces

    static func osObservationRows(_ snapshot: Snapshot, capabilities: MacCapabilities?, simulated: Bool) -> [(String, String)] {
        [
            ("lid", capabilities?.hardware == .desktop ? "not applicable (desktop)"
                : snapshot.observedLidClosed.map { $0 ? "closed" : "open" } ?? "unknown"),
            ("SleepDisabled (clamshell)", snapshot.observedSleepDisabled.map(yes) ?? "unknown"),
            ("full wake", snapshot.observedFullWake.map(yes) ?? (simulated ? "unknown (not captured in dry-run status)" : "unknown")),
            ("additional display observed", snapshot.displayTopology == .unknown ? "unknown" : yes(snapshot.externalDisplay))
        ]
    }

    static func batteryLimitSummary(userSession: UserSessionReply?, userSessionRequested: Bool,
                                   capabilities: MacCapabilities?, legacyLimits: UserLimits?, now: Date) -> String {
        if userSessionRequested {
            guard capabilities?.internalBattery != false else { return "Battery limits: not applicable (no internal battery)." }
            guard capabilities?.internalBattery == true else { return "Battery limits: battery capability unverified; no applied-limit verdict." }
            guard let status = HealthChecks.currentCommonStatus(userSession, now: now) else {
                return "Common battery limits unavailable; helper settings and defaults do not substitute for a current common reply."
            }
            return batteryLimitSummary(status.limits)
        }
        return batteryLimitSummary(legacyLimits)
    }

    private static func batteryLimitSummary(_ limits: UserLimits?) -> String {
        "Battery floor \(SafetyPolicy.floor(limits))%, longest hold \(SafetyPolicy.maxHold(limits) / 3600) h. These are usage allowances, not hardware damage thresholds."
    }

    static func expectations(userSessionRequested: Bool) -> String {
        let display = userSessionRequested
            ? "The display-keeping choice defaults to off. When selected, the app holds an idle display-sleep request for all displays only during a valid work session, releasing it at session end or protection stop. Choice, active request and request error are reported separately. It does not change manual lock or macOS password requirements; closed-lid and screen-saver locking need separate verification."
            : "The helper requests native display sleep under a closed lid with no external display. Request success is not proof that the display or system slept; compare observed state and power logs."
        return """
    ## How Tether should behave (compare the logs against this)

    - Power condition: AC only (default), battery only, or both. Manual off remains off.
    - Common work: the app coordinator owns general idle-sleep requests; a desktop does not require a lid helper. Automatic power conditions, direct battery reservations and manual sessions have separate user intent.
    - Battery: use a bounded timer and shared continuous-time budget with OS thermal and charge protection. The optional manual session is unlimited only on AC and at most 2 hours on battery. Temporary sessions are not replayed after restart.
    - Protection: a safety stop persists until explicit resume with safe readings. The watchdog clears a stale override on AC or battery.
    - Display: \(display)
    - New sessions never change energy modes. A legacy saved mode is restored only when its journal and current value agree; intervening user changes are retained.

    """
    }

    static func commonSessionReport(_ reply: UserSessionReply?, now: Date) -> String {
        var out = ["## Common work session", "", "Source: app coordinator snapshot; no saved helper setting substitutes for this state."]
        guard let status = HealthChecks.currentCommonStatus(reply, now: now), let reply else {
            out.append("Current common state unavailable: missing, failed, incompatible or stale reply. Actual work, Sleep/Wake and remote readiness are unverified.")
            return out.joined(separator: "\n") + "\n"
        }
        out.append("Captured \(stamp(Date(timeIntervalSince1970: reply.observedAt))) · epoch \(reply.epoch) · revision \(reply.revision)")
        out += ["", "| | |", "|---|---|"]
        let rows: [(String, String)] = [
            ("user enabled", yes(status.enabled)), ("automatic setting / active reason", "\(yes(status.automaticEnabled)) / \(yes(status.automaticActive))"),
            ("automatic power condition", status.powerCondition.rawValue), ("manual active", yes(status.manualActive)),
            ("own idle request active (app observation)", yes(status.holding)), ("power", status.power.rawValue),
            ("display keeping selected", status.keepDisplayAwake.map(yes) ?? "unknown (not reported)"),
            ("own display request active (app observation)", status.displayHolding.map(yes) ?? "unknown (not reported)"),
            ("display request error", status.displayError ?? "none reported"),
            ("battery reservation minutes", status.pendingBatteryMinutes.map(String.init) ?? "none"),
            ("battery continuation deadline", status.batteryHoldUntil.map(stamp) ?? "none"),
            ("effective deadline", status.until.map(stamp) ?? "none"), ("protection stop", status.blockReason ?? "none reported"),
            ("native request error", status.error ?? "none reported"), ("lid support (app observation)", reply.lidSupport.rawValue),
            ("helper connected", reply.helperConnected.map(yes) ?? "not required or unverified")
        ]
        for (key, value) in rows { out.append("| \(key) | \(value) |") }
        out.append("Display choice and native request activation are separate. Unknown display fields are not a confirmed off state. Request activation does not prove physical lid retention, display sleep, panel power, absence of locking, or remote frames/input.")
        return out.joined(separator: "\n") + "\n"
    }

    /// Includes rotated files. Markers remain searchable; truncation is disclosed explicitly.
    static func helperLog(since: Date, path: String = TetherPaths.helperLog) -> [String] {
        let text = LogArchive.read(path: path)
        guard !text.isEmpty else { return ["(helper logs missing, empty or unreadable)"] }
        let lines = linesSince(text, since: since, format: "yyyy-MM-dd HH:mm:ss", width: 19)
        let markers = lines.filter { $0.contains("diagnostic marker ") }.suffix(30)
        let header = ["(current + up to 3 archives; showing latest \(min(lines.count, 1200)) of \(lines.count) matching lines)"]
        return header + (markers.isEmpty ? [] : ["Markers in this window:"] + Array(markers))
            + (lines.isEmpty ? ["(nothing retained in this window)"] : Array(lines.suffix(1200)))
    }

    public static func assertionSummary(_ blockers: [SleepBlocker]?, includeProcessNames: Bool) -> String {
        guard let blockers else { return "Request query failed; this does not mean there are no active requests." }
        guard !blockers.isEmpty else { return "None besides powerd at collection time." }
        let pids = Array(Set(blockers.map(\.pid))).sorted()
        return blockers.map { blocker in
            let label = includeProcessNames ? blocker.process.replacingOccurrences(of: "\n", with: " ") : "Process \((pids.firstIndex(of: blocker.pid) ?? 0) + 1)"
            let purpose = blocker.purpose.map { " · \($0.rawValue) request" } ?? ""
            return "- \(label) (pid \(blocker.pid)): \(blocker.kind.rawValue)\(purpose)"
        }.joined(separator: "\n") + "\nAssertion names/payloads omitted."
    }

    public static func powerInfluenceSummary(preferences: PowerSleepPreferences, signals: [PowerActivitySignal]?,
                                             includeProcessNames: Bool) -> String {
        func minutes(_ value: Int?) -> String { value.map { $0 == 0 ? "disabled (0)" : "\($0) min" } ?? "unavailable" }
        var lines: [String] = []
        for (name, setting) in [("AC", preferences.ac), ("Battery", preferences.battery)] {
            lines.append("- \(name): idle system sleep \(minutes(setting?.systemMinutes)); display sleep \(minutes(setting?.displayMinutes)); terminal keep-awake \(setting?.terminalKeepsAwake.map(yes) ?? "unavailable").")
        }
        if let signals {
            if signals.isEmpty { lines.append("No user-activity or internal display-delay request observed at collection time.") }
            for signal in signals {
                let owner = includeProcessNames ? signal.process.replacingOccurrences(of: "\n", with: " ") : "pid \(signal.pid)"
                let input = signal.sourcePID.map { " · OS input-process hint pid \($0)" } ?? ""
                lines.append("- \(owner): \(signal.kind.rawValue)\(input).")
            }
        } else { lines.append("User-activity query unavailable; absence of input is not established.") }
        lines.append("Saved idle settings and reported activity do not establish actual Sleep, remote authentication, or the writer of a shared setting. They do not extend Tether's lid permission or battery deadline. Raw assertion payloads omitted.")
        return lines.joined(separator: "\n")
    }

    private static func safeHoldSource(_ source: String?) -> String {
        guard let source else { return "-" }
        return ["app", "cli", "url", "automatic"].contains(source) ? source : "legacy/custom (omitted)"
    }

    static func powerLog(since: Date) -> [String] {
        let result = Shell.run("/usr/bin/pmset", ["-g", "log"])
        guard result.status == 0 else { return ["(power log query failed: \(result.status))"] }
        let text = result.output
        let keep = linesSince(text, since: since, format: "yyyy-MM-dd HH:mm:ss Z", width: 25)
            .filter(isInterestingPowerLine)
            .map { $0.replacingOccurrences(of: "\t", with: "  ").trimmingCharacters(in: .whitespaces) }
        return keep.isEmpty ? ["(no retained sleep, wake or display entries in this window)"] : Array(keep.suffix(300))
    }

    /// Keep sleep/wake/display evidence. Current assertions are summarized separately
    /// without exporting their free-form names or payloads.
    public static func isInterestingPowerLine(_ line: String) -> Bool {
        let head = line.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
        let kind = head.count > 26 ? String(head.dropFirst(26)).trimmingCharacters(in: .whitespaces) : ""
        if ["Sleep", "Wake", "DarkWake", "Failure", "Wake Requests", "Kernel Client Acks"].contains(kind) { return true }
        // Assertion descriptions may contain document names or LLM task text, even when
        // they mention Tether. Current requests are exported separately without payloads.
        if kind == "Assertions" { return false }
        return line.contains("Tether") || line.contains("local.tether") || line.contains("Display is turned")
    }

    static func appLog(since: Date) -> String {
        let minutes = max(1, Int(Date().timeIntervalSince(since) / 60) + 1)
        let result = Shell.run("/usr/bin/log", ["show", "--style", "compact", "--last", "\(minutes)m",
                                                "--predicate", "subsystem == \"\(TetherPaths.logSubsystem)\""])
        guard result.status == 0 else { return "(app log query failed: \(result.status))" }
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
        // Older apps logged complete deep links. Drop their arguments from exported history.
        var s = text.replacingOccurrences(of: #"tether://[^\s]+"#, with: "tether://<command omitted>", options: .regularExpression)
        s = s.replacingOccurrences(of: home, with: "~")
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
