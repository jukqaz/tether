import Foundation
import TetherCore

/// pmset, the status file, events and the log.
extension Helper {
    func restorePowerMode(_ setting: PowerModeSetting, saved: Int, onBattery: Bool) -> Bool {
        withRecoveryLock { restorePowerModeLocked(setting, saved: saved, onBattery: onBattery) } ?? false
    }

    private func restorePowerModeLocked(_ setting: PowerModeSetting, saved: Int, onBattery: Bool) -> Bool {
        guard let arguments = setting.arguments(onBattery: onBattery, value: saved) else {
            lastApplyError = "lowPowerUnreadable"; return false
        }
        guard pmset(arguments) else { return false }
        guard currentPowerMode(onBattery: onBattery)?.value == saved else {
            lastApplyError = "powerVerificationFailed"
            log("power mode restoration was not confirmed; recovery state retained")
            return false
        }
        return true
    }

    @discardableResult
    func pmset(_ arguments: [String]) -> Bool {
        withRecoveryLock { pmsetLocked(arguments) } ?? false
    }

    private func pmsetLocked(_ arguments: [String]) -> Bool {
        writerTerminationConfirmed = true
        let needsGUI = arguments == ["-a", "disablesleep", "1"] || arguments == ["sleepnow"] || arguments == ["displaysleepnow"]
        if needsGUI, enforcesGUIAuthority, !guiControlConfirmed {
            lastApplyError = "guiSessionUnavailable"
            log("power request withheld: GUI authority unavailable")
            return false
        }
        log("command request: pmset \(arguments.joined(separator: " "))\(dryRun ? " [dry-run]" : "")")
        if dryRun {
            if fake["commandFailure"] as? Bool == true { lastApplyError = "pmsetFailed"; log("command result: simulated failure"); return false }
            if fake["commandNoEffect"] as? Bool == true {
                log("command result: simulated acceptance without applying the setting")
                return true
            }
            if arguments.count == 3, arguments[1] == "disablesleep" {
                simulatedSleepDisabled = arguments[2] == "1"
            }
            if arguments.count == 3, PowerModeSetting.Key(rawValue: arguments[1]) != nil,
               let value = Int(arguments[2]) { simulatedPowerModes[arguments[0] == "-b"] = value }
            log("command result: simulated success (no hardware change)")
            return true
        }
        guard let lock = activeRecoveryLock,
              let result = PowerWriterJournal.run("/usr/bin/pmset", arguments: arguments, lock: lock,
                    journalPath: writerJournalPath, boot: currentBootID, timeout: 2,
                    intentEpoch: epoch, intentRevision: revision,
                    gateExecutable: ProcessIdentity.capture(pid: getpid())?.executable,
                    guiOwner: needsGUI ? state.guiOwner : nil) else {
            writerTerminationConfirmed = false
            lastApplyError = "powerWriterUnresolved"
            log("power command journal/termination could not be confirmed; recovery records retained")
            return false
        }
        writerTerminationConfirmed = result.terminationConfirmed
        if !result.terminationConfirmed {
            lastApplyError = "powerWriterUnresolved"
            log("power writer termination unconfirmed; subsequent OS writes deferred")
            return false
        }
        if result.status != 0 {
            lastApplyError = result.status == PowerWriterGUIAuthority.denied ? "guiSessionUnavailable"
                : result.status == 124 ? "pmsetTimeout" : "pmsetFailed"
            log("error: pmset \(arguments.joined(separator: " ")) exited \(result.status): \(result.output)")
        }
        if result.status == 0 { log("command result: accepted (physical sleep not confirmed)") }
        return result.status == 0
    }

    func writeStatus(readings r: SafetyReadings) {
        let s = currentSnapshot()
        var hold = holdWasActive
            ? state.holdDeadline(requested: control.batteryHoldUntil, now: Date(),
                                 maxHold: SafetyPolicy.maxHold(limits))?.timeIntervalSince1970
            : nil
        if let wall = hold, let continuous = state.holdContinuousDeadline {
            hold = min(wall, Date().timeIntervalSince1970 + max(0, continuous - ContinuousTime.now))
        }
        if let wall = hold, s.power == .battery {
            hold = min(wall, Date().timeIntervalSince1970 + protection.batteryRemaining(clock: ContinuousTime.now, user: limits))
        }
        var status = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
                            enabled: control.enabled, power: s.power, lidClosed: s.lidClosed,
                            sleepDisabled: s.sleepDisabled, lastEvent: lastEvent, lastEventAt: lastEventAt,
                            batteryHoldUntil: hold, batteryTemperature: r.temperature, thermal: r.thermal,
                            batteryPercent: r.batteryPercent)
        status.build = TetherPaths.build
        status.lidObservationAvailable = s.observedLidClosed != nil
        status.sleepOverrideObservationAvailable = s.observedSleepDisabled != nil
        status.systemPowerObservationAvailable = systemPowerObservationAvailable
        status.fullWake = s.observedFullWake
        status.lastHoldEnd = lastHoldEnd
        status.lastHoldEndAt = lastHoldEndAt
        status.batteryHoldSince = hold == nil ? nil : state.holdSeenAt
        status.heatGuard = state.savedACLowPower != nil
        status.thermalAlertAt = thermalAlertAt
        status.overheatSleepAt = overheatSleepAt
        status.weakChargerSleepAt = weakChargerSleepAt
        status.displaySleeping = currentDisplaySleeping()
        status.displayRecovery = DisplayRecoveryStatus(
            phase: displayGate.phase,
            requests: displayGate.requestCount)
        status.externalDisplay = s.externalDisplay
        status.displayTopology = s.displayTopology
        status.nativeDisplayVerified = s.nativeDisplayVerified
        status.ownsOverride = ownsOverride
        status.appConnected = !sessionSuspended
        status.appPID = state.appPID
        status.guiSessionAuthority = enforcesGUIAuthority ? guiAuthority.status : nil
        status.powerReturnConfirmed = powerGate.confirmedAC
        status.sleepDeferralReason = sleepDeferralReason
        status.manualSession = manualSessionStatus(s)
        status.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
        status.workSession = workLeaseGate.current
        if state.userSessionCoordinated == true {
            let manual = coordinatedReasons.contains(.manual)
            var cap = limits ?? UserLimits(); cap.maxHoldHours = min(7200, SafetyPolicy.maxHold(limits)) / 3600
            status.manualSession = ManualSessionStatus(active: manual, holding: manual && ownsOverride && s.observedSleepDisabled == true,
                until: workLeaseGate.current?.manualDeadline.map { Date().timeIntervalSince1970 + max(0, $0 - manualClock) },
                batteryRemaining: (state.manualBatteryBudget ?? ProtectionState()).batteryRemaining(clock: manualClock, user: cap),
                endReason: nil)
        }
        status.protection = protectionStatus()
        latestStatus = status
        let observation = "power=\(s.power.rawValue) lid=\(s.observedLidClosed.map { $0 ? "closed" : "open" } ?? "unknown") fullWake=\(s.observedFullWake.map(String.init) ?? "unknown") enabled=\(control.enabled) appConnected=\(status.appConnected == true) condition=\(control.condition.rawValue) sleepDisabled=\(s.observedSleepDisabled.map(String.init) ?? "unknown") owned=\(ownsOverride) display=\(s.displayTopology.rawValue) displaySleeping=\(status.displaySleeping.map(String.init) ?? "unknown") hold=\(hold != nil) thermal=\(r.thermal) block=\(protection.blockReason ?? "none") error=\(lastApplyError ?? "none")"
        let displayObservation = observation + " systemPowerObservation=\(systemPowerObservationAvailable) nativeDisplay=\(s.nativeDisplayVerified) displayRecovery=\(status.displayRecovery!.phase.rawValue) displayRequests=\(displayGate.requestCount) sleepDeferral=\(sleepDeferralReason ?? "none") manual=\(manualSession.active) guiAuthority=\(status.guiSessionAuthority?.rawValue ?? "fixture")"
        if displayObservation != loggedObservation {
            loggedObservation = displayObservation
            log("observed: \(displayObservation)")
        }
        if JSONFile.write(status, to: statusPath, permissions: 0o644) {
            DarwinNotification.post(TetherPaths.statusChanged)
        } else { lastApplyError = "statusWriteFailed" }
    }

    func note(_ event: EventKind) {
        lastEvent = event
        lastEventAt = Date().timeIntervalSince1970
        if event != .started { log(event.logText) }
    }

    static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func log(_ message: String) {
        print("\(Self.stampFormat.string(from: Date())) \(message)")
    }

    /// Retain three bounded previous files, without replacing launchd's open descriptor.
    func trimLogIfNeeded() {
        switch LogArchive.rotate(descriptor: STDOUT_FILENO, path: logPath) {
        case .unchanged: break
        case .rotated: logArchiveFailed = false; log("log archived; up to 3 previous files retained")
        case .failed:
            if !logArchiveFailed { log("log archive failed; current log preserved") }
            logArchiveFailed = true
        }
    }
}
