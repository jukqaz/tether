import XCTest
import TetherCore

/// The real script reads intercepted sensors and calls the native recovery executor with
/// an isolated mock writer. No helper installation, real pmset write or physical sleep occurs.
// v3 contract: watchdog crash recovery is restoration only; it must not invent
// a disconnect incident or invoke Sleep. Real disconnect Sleep is helper-journalled.
final class WatchdogTests: XCTestCase {
    private struct Result {
        var status: Int32
        var calls: [String]
        var log: String
        var receipt: WatchdogReceipt?
        var ownership: PowerOwnership?
    }

    private func runWatchdog(power: String = "Battery", afterPower: String = "Battery", lid: String = "Yes",
                     capabilities: String = "15", disabled: String = "Yes", fresh: Bool = false,
                     clearFails: Bool = false, sleepFails: Bool = false, recovered: Bool = false,
                     statusAge: TimeInterval? = nil, owned: Bool = true, oldBoot: Bool = false, receiptUnavailable: Bool = false,
                     freshOwnership: Bool = false, reacquired: Bool = false,
                     locked: Bool = false, unsafeLock: Bool = false, noEffect: Bool = false,
                     executorUnavailable: Bool = false, foreignKeepAwake: Bool? = false,
                     recoveryObservationUnavailable: Bool = false) throws -> Result {
        let folder = URL(fileURLWithPath: "/tmp/tether-recovery-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/tether-watchdog.sh")
        let executor = Bundle(for: WatchdogTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("TetherRecoveryCLI")
        _ = try XCTUnwrap(FileManager.default.isExecutableFile(atPath: executor.path) ? executor : nil,
            "Build TetherRecoveryCLI before running watchdog integration tests")
        let mockDirectory = folder.appendingPathComponent("mock")
        try FileManager.default.createDirectory(at: mockDirectory, withIntermediateDirectories: true)
        let mockWriter = mockDirectory.appendingPathComponent("pmset")
        try Data(#"""
        #!/usr/bin/python3
        import os,sys
        from pathlib import Path
        folder=Path(os.environ['FIXTURE_DIR'])
        arguments=sys.argv[1:]
        with (folder/'calls').open('a') as file: file.write(' '.join(arguments)+'\n')
        if arguments==['-a','disablesleep','0']:
            if os.environ['CLEAR_FAILS']=='1': sys.exit(1)
            if os.environ['NO_EFFECT']=='1': sys.exit(0)
            (folder/'cleared').touch()
            if os.environ['REACQUIRED']=='1': Path(os.environ['TETHER_OWNERSHIP']).write_bytes((folder/'replacement.json').read_bytes())
            if os.environ['RECOVERED']=='1': Path(os.environ['TETHER_STATUS']).write_text('{}')
            sys.exit(0)
        if arguments==['sleepnow']: sys.exit(1 if os.environ['SLEEP_FAILS']=='1' else 0)
        sys.exit(99)
        """#.utf8).write(to: mockWriter)
        XCTAssertEqual(chmod(mockWriter.path, 0o755), 0)
        // The native executor reads a checked fixture only for this nonroot,
        // isolated mock writer. Production root uses current OS observations.
        if !recoveryObservationUnavailable {
            var observation: [String: Any] = ["power": afterPower == "AC" ? "ac" : afterPower == "Battery" ? "battery" : "unknown",
                                               "sleepDisabled": false]
            if ["Yes", "No"].contains(lid) { observation["lidClosed"] = lid == "Yes" }
            if let value = Int(capabilities) { observation["fullWake"] = value & 2 != 0 }
            if let foreignKeepAwake { observation["foreignKeepAwake"] = foreignKeepAwake }
            let observationPath = folder.appendingPathComponent("recovery-sleep.json")
            try JSONSerialization.data(withJSONObject: observation).write(to: observationPath)
            XCTAssertEqual(chmod(observationPath.path, 0o600), 0)
        }
        let status = folder.appendingPathComponent("status.json")
        if fresh || statusAge != nil {
            try Data("{}".utf8).write(to: status)
            if let statusAge {
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-statusAge)], ofItemAtPath: status.path)
            }
        }
        let boot = "865C2538-011A-403F-93ED-655758E09A67"
        var journal = PowerOwnership()
        if owned { journal.acquire(boot: boot) }
        if oldBoot { journal.boot = "previous-boot" }
        let ownership = folder.appendingPathComponent("power-ownership.json")
        try JSONEncoder().encode(journal).write(to: ownership)
        if !freshOwnership { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: ownership.path) }
        var replacement = journal; replacement.appliedAt = (journal.appliedAt ?? 0) + 1
        try JSONEncoder().encode(replacement).write(to: folder.appendingPathComponent("replacement.json"))
        let lockPath = RecoveryLock.path(supportDirectory: folder.path)
        let heldLock = locked ? try RecoveryLock.acquire(at: lockPath) : nil
        defer { withExtendedLifetime(heldLock) {} }
        if unsafeLock {
            FileManager.default.createFile(atPath: lockPath, contents: nil)
            XCTAssertEqual(chmod(lockPath, 0o666), 0)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"""
        sysctl() {
          [ "$*" = '-n kern.bootsessionuuid' ] || exit 99
          printf '%s\n' "$FIXTURE_BOOT"
        }
        pmset() {
          case "$*" in
            '-g batt')
              if [ -f "$FIXTURE_DIR/cleared" ]; then source="$AFTER_POWER"; else source="$BEFORE_POWER"; fi
              printf "Now drawing from '%s Power'\n" "$source" ;;
            '-a disablesleep 0')
              printf '%s\n' "$*" >> "$FIXTURE_DIR/calls"
              [ "$CLEAR_FAILS" = 1 ] && return 1
              [ "$NO_EFFECT" = 1 ] && return 0
              : > "$FIXTURE_DIR/cleared"
              [ "$REACQUIRED" = 1 ] && cp "$FIXTURE_DIR/replacement.json" "$TETHER_OWNERSHIP"
              [ "$RECOVERED" = 1 ] && printf '{}' > "$TETHER_STATUS"
              return 0 ;;
            sleepnow)
              printf '%s\n' "$*" >> "$FIXTURE_DIR/calls"
              [ "$SLEEP_FAILS" != 1 ] ;;
            *) exit 99 ;;
          esac
        }
        ioreg() {
          if [ -f "$FIXTURE_DIR/cleared" ]; then flag=No; else flag="$DISABLED"; fi
          printf '"SleepDisabled" = %s\n"AppleClamshellState" = %s\n"System Capabilities" = %s\n' "$flag" "$LID" "$CAPABILITIES"
        }
        . "$WATCHDOG_SCRIPT"
        """#]
        process.environment = ["FIXTURE_DIR": folder.path, "WATCHDOG_SCRIPT": script.path, "FIXTURE_BOOT": boot,
                               "TETHER_RECOVERY_TEST_ROOT": folder.path,
                               "TETHER_RECOVERY_EXECUTOR": executorUnavailable ? folder.appendingPathComponent("missing-executor").path : executor.path,
                               "RECOVERY_HELPER": folder.appendingPathComponent("missing-helper").path,
                               "TETHER_RECOVERY_LOCK_LIBRARY": script.deletingLastPathComponent().appendingPathComponent("tether-recovery-lock.sh").path,
                               "TETHER_WATCHDOG_STATUS": folder.appendingPathComponent(receiptUnavailable ? "missing/watchdog-status.json" : "watchdog-status.json").path,
                               "TETHER_OWNERSHIP": ownership.path, "TETHER_STATUS": status.path, "TETHER_LOG": folder.appendingPathComponent("log").path,
                               "BEFORE_POWER": power, "AFTER_POWER": afterPower, "LID": lid,
                               "CAPABILITIES": capabilities, "DISABLED": disabled, "CLEAR_FAILS": clearFails ? "1" : "0",
                               "SLEEP_FAILS": sleepFails ? "1" : "0", "RECOVERED": recovered ? "1" : "0",
                               "REACQUIRED": reacquired ? "1" : "0", "NO_EFFECT": noEffect ? "1" : "0"]
        try process.run()
        process.waitUntilExit()
        let calls = (try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
        let log = (try? String(contentsOf: folder.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        return Result(status: process.terminationStatus, calls: calls.split(separator: "\n").map(String.init), log: log,
                      receipt: JSONFile.read(WatchdogReceipt.self, from: folder.appendingPathComponent("watchdog-status.json").path),
                      ownership: JSONFile.read(PowerOwnership.self, from: ownership.path))
    }

    func testReceiptWriteFailureNeverPreventsRecovery() throws {
        let result = try runWatchdog(receiptUnavailable: true)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.calls, ["-a disablesleep 0"])
        XCTAssertNil(result.receipt)
    }

    func testUnavailableNativeExecutorsReportFailureWithoutConsumingOwnership() throws {
        let result = try runWatchdog(executorUnavailable: true)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.calls, [])
        XCTAssertTrue(result.ownership?.owned == true)
        XCTAssertEqual(result.receipt?.exitStatus, 1)
        XCTAssertTrue(result.log.contains("could not restore sleep"))
    }

    func testActiveNativeTransactionDefersWatchdogWithoutConsumingJournal() throws {
        let result = try runWatchdog(locked: true)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.calls, [])
        XCTAssertTrue(result.ownership?.owned == true)
    }

    func testUnsafeLockRefusesRecoveryAndPreservesJournal() throws {
        let result = try runWatchdog(unsafeLock: true)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.calls, [])
        XCTAssertTrue(result.ownership?.owned == true)
    }

    func testAcceptedRestoreWithoutOSEffectRetainsOwnershipAndNeverSleeps() throws {
        let result = try runWatchdog(noEffect: true)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.calls, ["-a disablesleep 0"])
        XCTAssertTrue(result.ownership?.owned == true)
        XCTAssertTrue(result.log.contains("not confirmed"))
    }

    func testUnownedAndPreviousBootOverridesRemainUntouched() throws {
        XCTAssertEqual(try runWatchdog(owned: false).calls, [])
        XCTAssertEqual(try runWatchdog(oldBoot: true).calls, [])
    }

    func testSilentHelperClosedLidFullWakeOnlyRestoresOwnOverride() throws {
        let result = try runWatchdog()
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.calls, ["-a disablesleep 0"])
        XCTAssertFalse(result.log.contains("sleep requested"))
        XCTAssertTrue(result.log.contains("crash recovery only"))
        XCTAssertEqual(result.receipt?.exitStatus, 0)
        XCTAssertEqual(result.receipt?.boot, "865C2538-011A-403F-93ED-655758E09A67")
    }

    func testForeignWorkOrUnavailableObservationRestoresOnlyOurOverride() throws {
        for result in [try runWatchdog(foreignKeepAwake: true),
                       try runWatchdog(foreignKeepAwake: nil),
                       try runWatchdog(recoveryObservationUnavailable: true),
                       try runWatchdog(lid: "unknown")] {
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.calls, ["-a disablesleep 0"])
            XCTAssertNil(result.ownership)
            XCTAssertTrue(result.log.contains("crash recovery only"))
            XCTAssertFalse(result.log.contains("sleep requested"))
        }
    }

    func testHealthyHelperAndNormalSleepAndACAreUntouched() throws {
        for result in [try runWatchdog(fresh: true), try runWatchdog(disabled: "No")] {
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.calls, [])
            XCTAssertEqual(result.receipt?.exitStatus, 0)
        }
    }

    func testOpenLidAndDarkWakeOnlyRestoreSleepSetting() throws {
        for result in [try runWatchdog(lid: "No"), try runWatchdog(capabilities: "13"), try runWatchdog(capabilities: "unknown")] {
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.calls, ["-a disablesleep 0"])
        }
    }

    func testReconnectedChargerOrRecoveredHelperPreventsSleepRequest() throws {
        for result in [try runWatchdog(recovered: true), try runWatchdog(afterPower: "AC"), try runWatchdog(afterPower: "Unknown")] {
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.calls, ["-a disablesleep 0"])
        }
    }

    func testAlreadyReleasedFlagConsumesOnlyStaleOwnership() throws {
        let stale = try runWatchdog(disabled: "No")
        XCTAssertEqual(stale.calls, [])
        XCTAssertNil(stale.ownership)
        let healthy = try runWatchdog(disabled: "No", fresh: true)
        XCTAssertTrue(healthy.ownership?.owned == true)
    }

    func testRestartingHelperGetsTimeToPublishFirstStatus() throws {
        let result = try runWatchdog(freshOwnership: true)
        XCTAssertEqual(result.calls, [])
        XCTAssertTrue(result.ownership?.owned == true)
    }

    func testReacquiredOwnershipDuringRecoveryIsNotDeletedOrSlept() throws {
        let result = try runWatchdog(reacquired: true)
        XCTAssertEqual(result.calls, ["-a disablesleep 0"])
        XCTAssertTrue(result.ownership?.owned == true)
        XCTAssertTrue(result.log.contains("preserving the new session"))
    }

    func testACFailureReleasesOverrideWithoutInterruptingNativeClamshell() throws {
        let result = try runWatchdog(power: "AC", afterPower: "AC")
        XCTAssertEqual(result.calls, ["-a disablesleep 0"])
    }

    func testFailedClearDoesNotClaimSuccessOrRequestSleep() throws {
        let result = try runWatchdog(clearFails: true)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.calls, ["-a disablesleep 0"])
        XCTAssertTrue(result.log.contains("could not restore sleep"))
        XCTAssertFalse(result.log.contains("sleep turned back on"))
        XCTAssertEqual(result.receipt?.exitStatus, 1)
    }

    func testCrashRecoveryDoesNotAttemptSleepEvenWhenSleepWouldFail() throws {
        let result = try runWatchdog(sleepFails: true)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.calls, ["-a disablesleep 0"])
        XCTAssertTrue(result.log.contains("crash recovery only"))
        XCTAssertFalse(result.log.contains("sleep request failed"))
    }

    func testStaleOrFutureDatedHeartbeatDoesNotBlockRecovery() throws {
        for age: TimeInterval in [91, 240, -600] {
            let result = try runWatchdog(statusAge: age)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.calls, ["-a disablesleep 0"])
        }
    }
}
