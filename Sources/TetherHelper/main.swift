import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import TetherCore

// Function-like IOKit macros are not imported into Swift; values from IOMessage.h and IOPM.h.
private let kMessageCanSystemSleep: UInt32 = 0xE000_0270
private let kMessageSystemWillSleep: UInt32 = 0xE000_0280
private let kMessageSystemHasPoweredOn: UInt32 = 0xE000_0300
private let kMessageClamshellStateChange: UInt32 = 0xE003_4100

/// Root LaunchDaemon that owns the rule: AC power turns clamshell mode on, anything else
/// turns it off, and a lid that is already closed when that happens is put to sleep.
final class Helper {
    private let dryRun: Bool
    private let controlPath: String
    private let statusPath: String

    private var control = Control()
    private var seenSleepNowRequest: Double?
    private var sleepNowUntil = Date.distantPast
    private var sleepRetryActive = false
    private var pendingTriggers: Set<Trigger> = []
    private var pendingWork: DispatchWorkItem?
    private var lastEvent: EventKind?
    private var lastEventAt: Double?
    private var lastLidClosed: Bool?
    private var sleepAttempt = 0

    // Battery hold
    private let statePath: String
    private var state = HelperState()
    private var holdWasActive = false
    private var holdingOnBattery = false
    private var warmSince: Date?
    private var warmLidClosed: Bool?
    private var fastTimer: DispatchSourceTimer?
    private var thermalObserver: DarwinNotification?
    private var lastHoldEnd: HoldEnd?
    private var lastHoldEndAt: Double?

    // AC heat guard
    private var coolSince: Date?
    private var criticalSince: Date?
    private var criticalAlerted = false
    private var thermalAlertAt: Double?

    // Usage stats and lid sessions
    private let usagePath: String
    private var usage = Usage()

    // Sleep log
    private var lastSleepRequestAt = Date.distantPast
    private var justWoke = false

    private var rootPort: io_connect_t = 0
    private var powerNotifyPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var interestPort: IONotificationPortRef?
    private var clamshellNotifier: io_object_t = 0
    private var timer: DispatchSourceTimer?
    private var termSource: DispatchSourceSignal?
    private var controlObserver: DarwinNotification?

    private let fakePath: String?
    /// A laptop with a lid and a battery. On a desktop "always on AC" would mean never sleeping,
    /// so there the helper only reports and never touches sleep settings.
    private let supported = SystemProbe.isSupportedMac

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

        // Tighter checks while a battery hold keeps a closed Mac awake.
        let fast = DispatchSource.makeTimerSource(queue: .main)
        fast.schedule(deadline: .now() + 10, repeating: 10)
        fast.setEventHandler { [weak self] in
            if self?.holdingOnBattery == true { self?.schedule(.timer) }
        }
        fast.resume()
        fastTimer = fast

        // Safety net in case a notification is ever missed.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.schedule(.timer) }
        timer.resume()
        self.timer = timer

        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in self?.stop() }
        term.resume()
        termSource = term

        schedule(.start)
    }

    // MARK: Events

    private func watchPowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue().schedule(.power)
        }, context)?.takeRetainedValue() else {
            log("warning: power source notifications unavailable")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func watchSystemPower() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &powerNotifyPort, { context, _, messageType, argument in
            guard let context else { return }
            Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue()
                .handleSystemPower(UInt32(messageType), argument)
        }, &powerNotifier)
        guard rootPort != 0, let port = powerNotifyPort else {
            log("warning: sleep/wake notifications unavailable")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)
    }

    private func handleSystemPower(_ messageType: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case kMessageCanSystemSleep:
            // Never veto sleep; an unanswered message would delay it by 30 seconds.
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case kMessageSystemWillSleep:
            // Quick reads and one small write, then let it go.
            usage.sleeps.willSleep(at: Date().timeIntervalSince1970, percent: SystemProbe.batteryPercent(),
                                   onBattery: SystemProbe.powerSource() == .battery,
                                   byTether: Date().timeIntervalSince(lastSleepRequestAt) < 90)
            JSONFile.write(usage, to: usagePath, permissions: 0o644)
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case kMessageSystemHasPoweredOn:
            sleepNowUntil = .distantPast
            sleepRetryActive = false
            justWoke = true
            schedule(.wake)
        default:
            break
        }
    }

    private func watchClamshell() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            log("warning: lid notifications unavailable")
            return
        }
        defer { IOObjectRelease(service) }
        interestPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, service, "IOGeneralInterest", { context, _, messageType, _ in
            guard let context, UInt32(messageType) == kMessageClamshellStateChange else { return }
            Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue().schedule(.lid)
        }, context, &clamshellNotifier)
        if result != KERN_SUCCESS { log("warning: lid notifications failed (\(result))") }
    }

    /// Plugging in fires several notifications; fold a burst into one pass.
    func schedule(_ trigger: Trigger) {
        pendingTriggers.insert(trigger)
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: Decisions

    private func evaluate() {
        var triggers = pendingTriggers
        pendingTriggers = []
        if loadControl(initial: false) { triggers.insert(.sleepNow) }

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
        let holdActive = updateBatteryHold(snapshot, readings: readings)
        let actions = Policy.actions(for: snapshot, triggers: triggers, enabled: control.enabled,
                                     sleepNowPending: Date() < sleepNowUntil, batteryHold: holdActive)
        for action in actions { perform(action, snapshot: snapshot, triggers: triggers) }

        // Whether clamshell mode is on once this pass's actions have landed.
        let clamshellOn = actions.contains(.setSleepDisabled(true))
            || (snapshot.sleepDisabled && !actions.contains(.setSleepDisabled(false)))
        updateHeatGuard(snapshot, clamshellOn: clamshellOn, readings: readings)
        updateUsage(snapshot, clamshellOn: clamshellOn, readings: readings)
        writeStatus(readings: readings)
    }

    /// Returns true when the file carries a new "sleep now" request.
    @discardableResult
    private func loadControl(initial: Bool) -> Bool {
        guard let loaded = JSONFile.read(Control.self, from: controlPath) else { return false }
        if initial || loaded.limits != control.limits || loaded.heatGuard != control.heatGuard {
            logSettings(loaded)
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
    private func logSettings(_ c: Control) {
        let closed = SafetyPolicy.limits(lidClosed: true, user: c.limits)
        let open = SafetyPolicy.limits(lidClosed: false, user: c.limits)
        let guardSettings = c.heatGuard ?? .standard
        log(String(format: "limits: floor %d%%, lid closed %.0f°C (early %.0f°C), lid open %.0f°C, max %.1f h; heat guard %@",
                   SafetyPolicy.floor(c.limits), closed.hardTemperature, closed.earlyTemperature ?? 0,
                   open.hardTemperature, SafetyPolicy.maxHold(c.limits) / 3600,
                   guardSettings.enabled ? "from thermal \(guardSettings.threshold)" : "off"))
    }

    // MARK: Battery hold

    /// Applies the hold's safety limits and Low Power Mode; returns whether the hold is active.
    private func updateBatteryHold(_ s: Snapshot, readings: SafetyReadings) -> Bool {
        let now = Date()
        let user = control.limits
        var deadline = control.enabled
            ? state.holdDeadline(requested: control.batteryHoldUntil, now: now, maxHold: SafetyPolicy.maxHold(user))
            : nil
        if deadline == nil, holdWasActive { endHold(.cancelled, readings: nil) }

        if let d = deadline {
            if s.power == .battery {
                // A lid change switches between the open and closed limits: restart the countdown.
                if warmLidClosed != s.lidClosed {
                    warmSince = nil
                    warmLidClosed = s.lidClosed
                }
                if SafetyPolicy.isWarm(readings, lidClosed: s.lidClosed, user: user) {
                    if warmSince == nil { warmSince = now }
                } else {
                    warmSince = nil
                }
                if let end = SafetyPolicy.verdict(readings, lidClosed: s.lidClosed, now: now,
                                                  holdUntil: d, warmSince: warmSince, user: user) {
                    endHold(end, readings: readings)
                    deadline = nil
                }
            } else if now >= d {
                endHold(.time, readings: nil)  // ran out while plugged in: nothing to undo
                deadline = nil
            }
        }

        let active = deadline != nil
        holdWasActive = active
        holdingOnBattery = active && s.power == .battery
        manageLowPower(on: holdingOnBattery)
        return active
    }

    private func endHold(_ reason: HoldEnd, readings: SafetyReadings?) {
        state.consumedHold = state.holdValue
        saveState()
        holdWasActive = false
        warmSince = nil
        lastHoldEnd = reason
        lastHoldEndAt = Date().timeIntervalSince1970
        note(.holdEnded(reason))
        if let readings { logReadings(readings) }
    }

    private func logReadings(_ r: SafetyReadings) {
        log(String(format: "  battery %.1f°C, thermal %d, charge %@%%", r.temperature ?? -1, r.thermal,
                   r.batteryPercent.map(String.init) ?? "?"))
    }

    /// Low Power Mode caps heat and drain while a closed Mac runs on battery.
    private func manageLowPower(on: Bool) {
        if on, state.savedBatteryLowPower == nil {
            let current = SystemProbe.lowPowerMode(section: "Battery Power") ?? 0
            state.savedBatteryLowPower = current
            saveState()
            note(.holdOnBattery)
            usage.stats.recordBatteryHold(now: Date())
            if current != 1 { pmset(["-b", "lowpowermode", "1"]) }
        } else if !on, let saved = state.savedBatteryLowPower {
            if saved != 1 { pmset(["-b", "lowpowermode", String(saved)]) }
            state.savedBatteryLowPower = nil
            saveState()
        }
    }

    // MARK: AC heat guard

    /// Lid closed on AC blocks the hinge vent. Cool the Mac with Low Power Mode instead of
    /// sleeping it, and raise an alert when critical pressure lasts.
    private func updateHeatGuard(_ s: Snapshot, clamshellOn: Bool, readings r: SafetyReadings) {
        let now = Date()
        let settings = control.heatGuard ?? .standard
        if r.thermal < settings.threshold {
            if coolSince == nil { coolSince = now }
        } else {
            coolSince = nil
        }
        if clamshellOn, s.power == .ac, s.lidClosed, r.thermal >= 3 {
            if criticalSince == nil { criticalSince = now }
        } else {
            criticalSince = nil
            criticalAlerted = false
        }
        let want = ACThermalPolicy.wantsLowPower(clamshellOn: clamshellOn, onAC: s.power == .ac,
                                                 lidClosed: s.lidClosed, thermal: r.thermal,
                                                 lowPowerOn: state.savedACLowPower != nil,
                                                 coolSince: coolSince, now: now, settings: settings)
        manageACLowPower(on: want, readings: r)
        if ACThermalPolicy.shouldAlert(criticalSince: criticalSince, alreadyAlerted: criticalAlerted, now: now) {
            criticalAlerted = true
            thermalAlertAt = now.timeIntervalSince1970
            note(.heatCritical)
            logReadings(r)
        }
    }

    private func manageACLowPower(on: Bool, readings: SafetyReadings) {
        if on, state.savedACLowPower == nil {
            let current = SystemProbe.lowPowerMode(section: "AC Power") ?? 0
            state.savedACLowPower = current
            saveState()
            note(.heatGuardOn)
            logReadings(readings)
            usage.stats.recordHeatGuard(now: Date())
            if current != 1 { pmset(["-c", "lowpowermode", "1"]) }
        } else if !on, let saved = state.savedACLowPower {
            if saved != 1 { pmset(["-c", "lowpowermode", String(saved)]) }
            state.savedACLowPower = nil
            saveState()
            note(.heatGuardOff)
        }
    }

    // MARK: Usage

    private func updateUsage(_ s: Snapshot, clamshellOn: Bool, readings r: SafetyReadings) {
        let now = Date()
        let woke = justWoke
        justWoke = false
        if let slept = usage.sleeps.awake(at: now.timeIntervalSince1970, fullWake: s.fullWake, justWoke: woke,
                                           percent: r.batteryPercent, onBattery: s.power == .battery,
                                           sleepReason: SystemProbe.rootDomainString("Last Sleep Reason"),
                                           requestedByTether: SystemProbe.sleepRequestedByPID == Int(getpid()),
                                           wakeType: SystemProbe.rootDomainString("Wake Type"),
                                           wakeReason: SystemProbe.rootDomainString("Wake Reason")) {
            log(String(format: "slept %.0f min, charge %@%% -> %@%%%@, %d dark wakes; asleep by %@, woke by %@ (%@)",
                       (slept.duration ?? 0) / 60, slept.percentBefore.map(String.init) ?? "?",
                       slept.percentAfter.map(String.init) ?? "?",
                       slept.drainPerHour.map { String(format: " (%.1f%%/h)", $0) } ?? "", slept.darkWakes,
                       slept.byTether ? "Tether" : (slept.sleepReason ?? "?"), slept.wakeType ?? "?",
                       slept.wakeReason ?? "?"))
        }
        usage.stats.tick(now: now, sample: UsageSample(lidClosed: s.lidClosed, clamshellOn: clamshellOn,
                                                       holdingOnBattery: holdingOnBattery, temperature: r.temperature,
                                                       thermal: r.thermal, batteryPercent: r.batteryPercent))
        let lowPower = state.savedACLowPower != nil || state.savedBatteryLowPower != nil
        if let session = usage.tracker.update(lidClosed: s.lidClosed, clamshellOn: clamshellOn, readings: r,
                                              onBattery: s.power == .battery, lowPower: lowPower, now: now) {
            usage.add(session)
            log(String(format: "lid session: %.0f min, max %.1f°C, thermal %d, charge %@%% -> %@%%",
                       session.duration / 60, session.maxTemperature ?? -1, session.maxThermal,
                       session.batteryStart.map(String.init) ?? "?", session.batteryEnd.map(String.init) ?? "?"))
        }
        JSONFile.write(usage, to: usagePath, permissions: 0o644)
    }

    private func saveState() {
        JSONFile.write(state, to: statePath, permissions: 0o600)
    }

    // MARK: Readings (fakeable in dry-run, for scenario tests without unplugging)

    /// Dry-run only: JSON with any of power, lid ("closed"/"open"), sleepDisabled, temperature,
    /// thermal, battery. Re-read on every evaluation so a script can walk through a scenario.
    private var fake: [String: Any] {
        guard dryRun, let fakePath, let data = FileManager.default.contents(atPath: fakePath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func currentSnapshot() -> Snapshot {
        var s = SystemProbe.snapshot()
        let f = fake
        if let p = (f["power"] as? String).flatMap(PowerSource.init(rawValue:)) { s.power = p }
        if let lid = f["lid"] as? String { s.lidClosed = lid == "closed" }
        if let sd = f["sleepDisabled"] as? Bool { s.sleepDisabled = sd }
        return s
    }

    private func currentReadings() -> SafetyReadings {
        var r = SystemProbe.safetyReadings()
        let f = fake
        if let t = f["temperature"] as? Double { r.temperature = t }
        if let t = f["thermal"] as? Int { r.thermal = t }
        if let b = f["battery"] as? Int { r.batteryPercent = b }
        return r
    }

    private func perform(_ action: Action, snapshot: Snapshot, triggers: Set<Trigger>) {
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
            note(triggers.contains(.sleepNow) ? .sleepNow : .lidSleep)
            usage.stats.recordForcedSleep(now: Date())
            lastSleepRequestAt = Date()
            sleepRetryActive = true
            sleepAttempt = 0
            requestSleep(attemptsLeft: 20)
        }
    }

    /// The kernel refuses sleep until powerd has passed it the cleared flag, so retry briefly.
    private func requestSleep(attemptsLeft: Int) {
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

    private func stop() {
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

    // MARK: Output

    private func pmset(_ arguments: [String]) {
        if dryRun {
            log("[dry-run] pmset \(arguments.joined(separator: " "))")
            return
        }
        let result = Shell.run("/usr/bin/pmset", arguments)
        if result.status != 0 {
            log("error: pmset \(arguments.joined(separator: " ")) exited \(result.status): \(result.output)")
        }
    }

    private func writeStatus(readings r: SafetyReadings) {
        let s = currentSnapshot()
        let hold = holdWasActive
            ? state.holdDeadline(requested: control.batteryHoldUntil, now: Date(),
                                 maxHold: SafetyPolicy.maxHold(control.limits))?.timeIntervalSince1970
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
        if JSONFile.write(status, to: statusPath, permissions: 0o644) {
            DarwinNotification.post(TetherPaths.statusChanged)
        }
    }

    private func note(_ event: EventKind) {
        lastEvent = event
        lastEventAt = Date().timeIntervalSince1970
        if event != .started { log(event.logText) }
    }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private func log(_ message: String) {
        print("\(Self.stampFormat.string(from: Date())) \(message)")
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
// launchd appends to the log forever; start over once it passes 1 MB.
var logInfo = stat()
if fstat(STDOUT_FILENO, &logInfo) == 0, (logInfo.st_mode & S_IFMT) == S_IFREG, logInfo.st_size > 1_000_000 {
    ftruncate(STDOUT_FILENO, 0)
}
let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

let helper = Helper(dryRun: arguments.contains("--dry-run"),
                    controlPath: option("--control") ?? TetherPaths.controlPath,
                    statusPath: option("--status") ?? TetherPaths.statusPath,
                    fakePath: option("--fake"))
helper.start()
RunLoop.main.run()
