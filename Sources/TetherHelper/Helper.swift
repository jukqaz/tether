import Foundation
import IOKit
import IOKit.pwr_mgt
import TetherCore

/// Root LaunchDaemon that owns the rule: AC power turns clamshell mode on, anything else
/// turns it off, and a lid that is already closed when that happens is put to sleep. The
/// decisions live here; events, the battery hold, the heat guard, usage records, readings and
/// output are in the `Helper+…` files.
final class Helper {
    let dryRun: Bool
    let controlPath: String
    let statusPath: String

    var control = Control()
    var seenSleepNowRequest: Double?
    var sleepNowUntil = Date.distantPast
    var sleepRetryActive = false
    var pendingTriggers: Set<Trigger> = []
    var pendingWork: DispatchWorkItem?
    var lastEvent: EventKind?
    var lastEventAt: Double?
    var lastLidClosed: Bool?
    /// The power source at the previous check, to notice a new connection.
    var lastPower: PowerSource?
    var sleepAttempt = 0
    /// What the next forced sleep is logged as: a "sleep now" request, or overheating.
    var sleepNowReason = EventKind.sleepNow

    // Battery hold
    let statePath: String
    var state = HelperState()
    var holdWasActive = false
    var holdingOnBattery = false
    var warmSince: Date?
    var warmLidClosed: Bool?
    var fastTimer: DispatchSourceTimer?
    var thermalObserver: DarwinNotification?
    var lastHoldEnd: HoldEnd?
    var lastHoldEndAt: Double?

    // AC heat guard
    var coolSince: Date?
    var criticalSince: Date?
    var criticalAlerted = false
    var thermalAlertAt: Double?
    var hotSince: Date?
    var overheatSleepAt: Double?
    var drainingSince: Date?
    var weakChargerSleepAt: Double?

    // Usage stats and lid sessions
    let usagePath: String
    var usage = Usage()
    var usageSavedAt = Date.distantPast

    // Sleep log
    var lastSleepRequestAt = Date.distantPast
    var justWoke = false

    /// Tracks whether the menu bar app still exists (see `retireIfAppIsGone`).
    var appPresence = AppPresence()

    var rootPort: io_connect_t = 0
    var powerNotifyPort: IONotificationPortRef?
    var powerNotifier: io_object_t = 0
    var interestPort: IONotificationPortRef?
    var clamshellNotifier: io_object_t = 0
    var timer: DispatchSourceTimer?
    var termSource: DispatchSourceSignal?
    var controlObserver: DarwinNotification?

    let fakePath: String?
    /// A laptop with a lid and a battery. On a desktop "always on AC" would mean never sleeping,
    /// so there the helper only reports and never touches sleep settings.
    let supported = SystemProbe.isSupportedMac

    init(dryRun: Bool, controlPath: String, statusPath: String, fakePath: String? = nil) {
        self.dryRun = dryRun
        self.controlPath = controlPath
        self.statusPath = statusPath
        self.fakePath = fakePath
        let folder = URL(fileURLWithPath: statusPath).deletingLastPathComponent()
        statePath = folder.appendingPathComponent("helper-state.json").path
        usagePath = folder.appendingPathComponent("usage.json").path
    }

    func start() {
        log("started v\(TetherPaths.version)\(dryRun ? " (dry-run)" : "")")
        note(.started)
        if !supported {
            log("no built-in battery or lid: this Mac is not a laptop, so Tether leaves sleep settings alone")
        }
        // A battery hold depends on these; an unreadable sensor makes every hold end at once.
        let readings = SystemProbe.safetyReadings()
        if let t = readings.temperature {
            log(String(format: "sensors: battery %.1f°C, thermal %d, charge %@%%", t, readings.thermal,
                       readings.batteryPercent.map(String.init) ?? "?"))
        } else {
            log("warning: battery temperature unreadable; battery holds will end immediately")
        }
        state = JSONFile.read(HelperState.self, from: statePath) ?? HelperState()
        usage = JSONFile.read(Usage.self, from: usagePath) ?? Usage()
        // Seed the lid state so only real opens/closes get logged. The clamshell message also
        // fires when AppleClamshellCausesSleep flips on a power change, with the lid unchanged.
        lastLidClosed = currentSnapshot().lidClosed
        lastPower = currentSnapshot().power
        loadControl(initial: true)
        watchPowerSource()
        watchSystemPower()
        watchClamshell()
        controlObserver = DarwinNotification(observing: TetherPaths.controlChanged) { [weak self] in
            self?.schedule(.settings)
        }
        // OSThermalNotification: fires when macOS thermal pressure changes.
        thermalObserver = DarwinNotification(observing: "com.apple.system.thermalpressurelevel") { [weak self] in
            self?.schedule(.thermal)
        }

        // Tighter checks while a battery hold keeps a closed Mac awake, or while it overheats on power.
        let fast = DispatchSource.makeTimerSource(queue: .main)
        fast.schedule(deadline: .now() + 10, repeating: 10)
        fast.setEventHandler { [weak self] in
            guard let self else { return }
            if self.holdingOnBattery || self.criticalSince != nil || self.hotSince != nil || self.drainingSince != nil {
                self.schedule(.timer)
            }
        }
        fast.resume()
        fastTimer = fast

        // Safety net in case a notification is ever missed.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.trimLogIfNeeded()
            self?.schedule(.timer)
        }
        timer.resume()
        self.timer = timer

        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in self?.stop() }
        term.resume()
        termSource = term

        schedule(.start)
    }

    /// Plugging in fires several notifications; fold a burst into one pass.
    func schedule(_ trigger: Trigger) {
        pendingTriggers.insert(trigger)
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    func evaluate() {
        var triggers = pendingTriggers
        pendingTriggers = []
        if loadControl(initial: false) { triggers.insert(.sleepNow) }

        if retireIfAppIsGone() { return }
        let snapshot = currentSnapshot()
        let readings = currentReadings()
        guard supported else {
            writeStatus(readings: readings)
            return
        }
        if triggers.contains(.lid), snapshot.lidClosed != lastLidClosed {
            lastLidClosed = snapshot.lidClosed
            // Log only: clamshell mode itself does nothing on a lid change.
            log("lid \(snapshot.lidClosed ? "closed" : "opened") on \(snapshot.power.rawValue)"
                + (snapshot.sleepDisabled ? ", clamshell holds" : ""))
        }
        if Policy.resumesOnPower(enabled: control.enabled, previous: lastPower, current: snapshot.power),
           ControlStore.update(path: controlPath, { $0.enabled = true }) {
            control.enabled = true
            log("power connected: clamshell mode switched back on")
        }
        if snapshot.power != .unknown { lastPower = snapshot.power }
        let holdActive = updateBatteryHold(snapshot, readings: readings)
        let actions = Policy.actions(for: snapshot, triggers: triggers, enabled: control.enabled,
                                     sleepNowPending: Date() < sleepNowUntil, batteryHold: holdActive)
        if control.debugLog == true {
            log(String(format: "check [%@]: power=%@ lid=%@ sleepDisabled=%d fullWake=%d external=%d battery=%@%% %@ thermal=%d enabled=%d hold=%d -> %@",
                       triggers.map(\.rawValue).sorted().joined(separator: ","), snapshot.power.rawValue,
                       snapshot.lidClosed ? "closed" : "open", snapshot.sleepDisabled ? 1 : 0, snapshot.fullWake ? 1 : 0,
                       snapshot.externalDisplay ? 1 : 0, readings.batteryPercent.map(String.init) ?? "?",
                       readings.temperature.map { String(format: "%.1fC", $0) } ?? "temp?", readings.thermal,
                       control.enabled ? 1 : 0, holdActive ? 1 : 0,
                       actions.isEmpty ? "no action" : actions.map { "\($0)" }.joined(separator: ", ")))
        }
        for action in actions { perform(action, snapshot: snapshot, triggers: triggers) }

        // Whether clamshell mode is on once this pass's actions have landed.
        let clamshellOn = actions.contains(.setSleepDisabled(true))
            || (snapshot.sleepDisabled && !actions.contains(.setSleepDisabled(false)))
        updateHeatGuard(snapshot, clamshellOn: clamshellOn, readings: readings)
        updateSafetyNet(snapshot, clamshellOn: clamshellOn, readings: readings)
        updateUsage(snapshot, clamshellOn: clamshellOn, readings: readings)
        writeStatus(readings: readings)
    }

    /// Returns true when the file carries a new "sleep now" request.
    @discardableResult
    func loadControl(initial: Bool) -> Bool {
        guard let loaded = JSONFile.read(Control.self, from: controlPath) else { return false }
        if initial || loaded.limits != control.limits || loaded.heatGuard != control.heatGuard
            || loaded.holdLowPower != control.holdLowPower {
            logSettings(loaded)
        }
        if loaded.debugLog != control.debugLog || (initial && loaded.debugLog == true) {
            log("detailed logging \(loaded.debugLog == true ? "on" : "off")")
        }
        control = loaded
        if let hold = loaded.batteryHoldUntil, hold != state.holdValue {
            state.holdValue = hold
            state.holdSeenAt = Date().timeIntervalSince1970
            saveState()
            if !initial { log("battery hold armed") }
        }
        // A hold never survives a helper restart or reboot: ending it is the safe side.
        if initial, let hold = loaded.batteryHoldUntil, hold != state.consumedHold {
            state.consumedHold = hold
            saveState()
        }
        guard let request = loaded.sleepNowRequest, request != seenSleepNowRequest else { return false }
        seenSleepNowRequest = request
        // A request left in the file across a restart is stale.
        guard !initial, Date().timeIntervalSince1970 - request < 60 else { return false }
        sleepNowUntil = Date().addingTimeInterval(20)
        if holdWasActive { endHold(.cancelled, readings: nil) }
        return true
    }

    /// The limits in force, after clamping to the defaults (they can only be stricter).
    func logSettings(_ c: Control) {
        let closed = SafetyPolicy.limits(lidClosed: true, user: c.limits)
        let open = SafetyPolicy.limits(lidClosed: false, user: c.limits)
        let guardSettings = c.heatGuard ?? .standard
        log(String(format: "limits: floor %d%%, lid closed %.0f°C (early %.0f°C), lid open %.0f°C, max %.1f h; Low Power Mode during holds %@, when hot on power %@",
                   SafetyPolicy.floor(c.limits), closed.hardTemperature, closed.earlyTemperature ?? 0,
                   open.hardTemperature, SafetyPolicy.maxHold(c.limits) / 3600,
                   c.holdLowPower == false ? "off" : "on",
                   guardSettings.enabled ? "from thermal \(guardSettings.threshold)" : "off"))
    }

    func perform(_ action: Action, snapshot: Snapshot, triggers: Set<Trigger>) {
        switch action {
        case .setSleepDisabled(true):
            note(.clamshellOn)
            pmset(["-a", "disablesleep", "1"])
        case .setSleepDisabled(false):
            if snapshot.power == .battery {
                note(.clamshellOffPower)
            } else {
                note(control.enabled ? .clamshellOffSleepNow : .clamshellOffDisabled)
            }
            pmset(["-a", "disablesleep", "0"])
        case .sleepSystem:
            guard !sleepRetryActive else { return }
            let event = triggers.contains(.sleepNow) ? sleepNowReason : .lidSleep
            sleepNowReason = .sleepNow
            note(event)
            if event == .overheatSleep || event == .weakChargerSleep { logReadings(currentReadings()) }
            usage.stats.recordForcedSleep(now: Date())
            lastSleepRequestAt = Date()
            sleepRetryActive = true
            sleepAttempt = 0
            requestSleep(attemptsLeft: 20)
        }
    }

    /// The kernel refuses sleep until powerd has passed it the cleared flag, so retry briefly.
    func requestSleep(attemptsLeft: Int) {
        if dryRun {
            log("[dry-run] IOPMSleepSystem")
            sleepRetryActive = false
            return
        }
        sleepAttempt += 1
        let pm = IOPMFindPowerManagement(kIOMainPortDefault)
        let result: IOReturn = pm != 0 ? IOPMSleepSystem(pm) : -1
        if pm != 0 { IOServiceClose(pm) }
        if result == kIOReturnSuccess {
            if sleepAttempt > 1 { log("sleep accepted on attempt \(sleepAttempt)") }
            sleepRetryActive = false
            return
        }
        guard attemptsLeft > 1 else {
            note(.sleepRefused)
            pmset(["sleepnow"])
            sleepRetryActive = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.sleepRetryActive else { return }
            // Stop once the reason is gone: lid opened, power back, request expired.
            let pending = Date() < self.sleepNowUntil
            let stillWanted = Policy.actions(for: currentSnapshot(), triggers: pending ? [.sleepNow] : [],
                                             enabled: self.control.enabled, sleepNowPending: pending,
                                             batteryHold: self.holdWasActive)
                .contains(.sleepSystem)
            if stillWanted {
                self.requestSleep(attemptsLeft: attemptsLeft - 1)
            } else {
                self.sleepRetryActive = false
            }
        }
    }

    func stop() {
        // An unmanaged SleepDisabled would keep a closed Mac awake on battery.
        if currentSnapshot().sleepDisabled {
            note(.stopping)
            pmset(["-a", "disablesleep", "0"])
        }
        manageLowPower(on: false)
        manageACLowPower(on: false, readings: currentReadings())
        JSONFile.write(usage, to: usagePath, permissions: 0o644)
        log("stopped")
        exit(0)
    }
}
