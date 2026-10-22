import Darwin
import Foundation

/// A power operation checks GUI authority again at the native exec boundary.
/// Cleanup can proceed after logout; new holds and display/system sleep cannot.
public enum PowerWriterGUIAuthority {
    public static let denied: Int32 = 77

    public static func requiresCheck(arguments: [String], effectiveUID: UInt32,
                                     owner: GUISessionOwner?) -> Bool {
        let operation = [["-a", "disablesleep", "1"], ["sleepnow"], ["displaysleepnow"]].contains(arguments)
        // Nonroot legacy fixtures can only run a fixed target inside a validated tmp
        // directory. An attached GUI owner opts those native fixtures into this check.
        return operation && (effectiveUID == 0 || owner != nil)
    }

    public static func permits(arguments: [String], effectiveUID: UInt32, owner: GUISessionOwner?,
                               state: HelperState?, process: ProcessIdentity?, boot: String,
                               observation: GUISessionObservation, now: Double = ContinuousTime.now,
                               power: PowerSource? = nil, thermal: Int? = nil,
                               fullWake: Bool? = nil, batteryPercent: Int? = nil) -> Bool {
        guard requiresCheck(arguments: arguments, effectiveUID: effectiveUID, owner: owner) else { return true }
        guard let owner, let state, state.guiOwner == owner,
              (state.controllerUID ?? state.appUID) == owner.login.uid,
              state.appUID == owner.login.uid, state.appPID == owner.process.pid,
              state.appStarted == owner.process.started, owner.matches(process: process, boot: boot),
              observation.login == owner.login, observation.consoleUID == owner.login.uid else { return false }
        if state.userSessionCoordinated == true,
           arguments == ["-a", "disablesleep", "1"] || arguments == ["displaysleepnow"] {
            guard state.coordinatedStopPending != true, let lease = state.workSessionLease,
                  lease.isValid(now: now), !lease.reasons.isEmpty, let power,
                  power != .unknown, power == lease.power, fullWake == true,
                  thermal.map({ (0..<2).contains($0) }) == true,
                  power != .battery || SafetyPolicy.canStartHold(batteryPercent: batteryPercent,
                    user: lease.configuration.limits) else { return false }
            if lease.executionVersion == 3 {
                guard state.lidProtection == nil, state.savedBatteryLowPower == nil, state.savedACLowPower == nil,
                      let permit = lease.lidPermit, permit.powerScopes.contains(power),
                      state.lidEndReceipt.map({ $0.sessionID != lease.sessionID ||
                          (lease.endConsumptionID == $0.id && lease.sequence > $0.sequence) }) ?? true else { return false }
                if power == .battery {
                    guard let receipt = state.batteryPermitReceipts?.first(where: {
                        $0.sessionID == lease.sessionID && $0.permitID == permit.batteryPermitID && $0.bootID == boot
                    }), receipt.isValid(boot: boot), now < receipt.deadline else { return false }
                }
            }
        }
        return true
    }

    /// Read one checked FD, so an atomic file replacement cannot bypass ownership/mode
    /// checks. The containing directory belongs to the native executor's UID.
    public static func controllerState(support: String) -> HelperState? {
        var folder = stat()
        guard lstat(support, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR,
              folder.st_uid == geteuid(), folder.st_mode & 0o022 == 0,
              let bytes = JSONFile.readBytes(from: URL(fileURLWithPath: support)
                .appendingPathComponent("helper-state.json").path,
                expectedOwner: geteuid(), expectedPermissions: 0o600) else { return nil }
        return try? JSONDecoder().decode(HelperState.self, from: bytes)
    }

    public static func nativePermits(arguments: [String], owner: GUISessionOwner?,
                                    support: String, boot: String, intentEpoch: String? = nil) -> Bool {
        // The existing journal intent distinguishes watchdog recovery from an
        // explicit user sleep. Recheck before launch and again immediately before exec.
        if requiresCheck(arguments: arguments, effectiveUID: geteuid(), owner: owner) {
            let process = owner.flatMap { ProcessIdentity.capture(pid: $0.process.pid) }
            let login = owner.flatMap { GUISessionProbe.graphical($0.login) }
            guard permits(arguments: arguments, effectiveUID: geteuid(), owner: owner,
                state: controllerState(support: support), process: process, boot: boot,
                observation: GUISessionObservation(login: login, consoleUID: SystemProbe.consoleUserID),
                power: SystemProbe.powerSource(), thermal: ProcessInfo.processInfo.thermalState.rawValue,
                fullWake: SystemProbe.observedFullWake, batteryPercent: SystemProbe.batteryPercent()) else { return false }
        }
        // File/GUI verification can wait. Read automatic-sleep conditions last so
        // that a change during that wait does not inherit the earlier permission.
        return arguments != ["sleepnow"] || intentEpoch != "recovery"
            || permitsAutomaticRecovery(support: support)
    }

    private struct RecoveryObservation: Decodable {
        var power: PowerSource
        var lidClosed: Bool?
        var sleepDisabled: Bool?
        var fullWake: Bool?
        var foreignKeepAwake: Bool?
    }

    private static func permitsAutomaticRecovery(support: String) -> Bool {
        if geteuid() != 0 {
            // Only the existing isolated mock-writer boundary can supply test
            // sensors. Root never reads these files or accepts environment overrides.
            guard PowerRecoveryCommand.writerExecutable(support: support) != nil,
                  let data = JSONFile.readBytes(from: URL(fileURLWithPath: support)
                    .appendingPathComponent("recovery-sleep.json").path,
                    expectedOwner: geteuid(), expectedPermissions: 0o600),
                  let value = try? JSONDecoder().decode(RecoveryObservation.self, from: data) else { return false }
            return SleepRequestPolicy.allowsAutomaticRecovery(snapshot: Snapshot(power: value.power,
                lidClosed: value.lidClosed, sleepDisabled: value.sleepDisabled, fullWake: value.fullWake),
                foreignKeepAwake: value.foreignKeepAwake)
        }
        // The GUI's general assertion can remain healthy while its root helper is
        // silent. Recovery releases only the lid override; it cannot ignore that
        // independent request just because the same app owns the GUI connection.
        let foreign = SystemProbe.closedLidSleepBlockerSnapshot(excluding: [getpid()]).map { !$0.isEmpty }
        return SleepRequestPolicy.allowsAutomaticRecovery(snapshot: SystemProbe.snapshot(), foreignKeepAwake: foreign)
    }
}
