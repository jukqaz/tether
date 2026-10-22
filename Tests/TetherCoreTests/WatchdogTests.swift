import XCTest

/// The real script is sourced with shell functions intercepting every power command. These
/// tests never install a helper, change pmset or put the developer's Mac to sleep.
final class WatchdogTests: XCTestCase {
    private struct Result {
        var status: Int32
        var calls: [String]
        var log: String
    }

    private func runWatchdog(power: String = "Battery", afterPower: String = "Battery", lid: String = "Yes",
                     capabilities: String = "15", disabled: String = "Yes", fresh: Bool = false,
                     clearFails: Bool = false, sleepFails: Bool = false, recovered: Bool = false,
                     statusAge: TimeInterval? = nil) throws -> Result {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/tether-watchdog.sh")
        let status = folder.appendingPathComponent("status.json")
        if fresh || statusAge != nil {
            try Data("{}".utf8).write(to: status)
            if let statusAge {
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-statusAge)], ofItemAtPath: status.path)
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"""
        pmset() {
          case "$*" in
            '-g batt')
              if [ -f "$FIXTURE_DIR/cleared" ]; then source="$AFTER_POWER"; else source="$BEFORE_POWER"; fi
              printf "Now drawing from '%s Power'\n" "$source" ;;
            '-a disablesleep 0')
              printf '%s\n' "$*" >> "$FIXTURE_DIR/calls"
              [ "$CLEAR_FAILS" = 1 ] && return 1
              : > "$FIXTURE_DIR/cleared"
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
        process.environment = ["FIXTURE_DIR": folder.path, "WATCHDOG_SCRIPT": script.path,
                               "TETHER_STATUS": status.path, "TETHER_LOG": folder.appendingPathComponent("log").path,
                               "BEFORE_POWER": power, "AFTER_POWER": afterPower, "LID": lid,
                               "CAPABILITIES": capabilities, "DISABLED": disabled, "CLEAR_FAILS": clearFails ? "1" : "0",
                               "SLEEP_FAILS": sleepFails ? "1" : "0", "RECOVERED": recovered ? "1" : "0"]
        try process.run()
        process.waitUntilExit()
        let calls = (try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
        let log = (try? String(contentsOf: folder.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        return Result(status: process.terminationStatus, calls: calls.split(separator: "\n").map(String.init), log: log)
    }

    func testSilentHelperClosedLidFullWakeRequestsSleep() throws {
        let result = try runWatchdog()
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.calls, ["-a disablesleep 0", "sleepnow"])
        XCTAssertTrue(result.log.contains("sleep requested"))
        XCTAssertTrue(result.log.contains("actual sleep must be confirmed"))
    }

    func testHealthyHelperAndNormalSleepAndACAreUntouched() throws {
        for result in [try runWatchdog(fresh: true), try runWatchdog(disabled: "No"), try runWatchdog(power: "AC")] {
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.calls, [])
        }
    }

    func testOpenLidAndDarkWakeOnlyRestoreSleepSetting() throws {
        for result in [try runWatchdog(lid: "No"), try runWatchdog(capabilities: "13"), try runWatchdog(capabilities: "unknown")] {
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.calls, ["-a disablesleep 0"])
        }
    }

    func testReconnectedChargerOrRecoveredHelperPreventsSleepRequest() throws {
        for result in [try runWatchdog(afterPower: "AC"), try runWatchdog(recovered: true)] {
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.calls, ["-a disablesleep 0"])
        }
    }

    func testFailedClearDoesNotClaimSuccessOrRequestSleep() throws {
        let result = try runWatchdog(clearFails: true)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.calls, ["-a disablesleep 0"])
        XCTAssertTrue(result.log.contains("could not restore sleep"))
        XCTAssertFalse(result.log.contains("sleep turned back on"))
    }

    func testFailedSleepRequestIsReported() throws {
        let result = try runWatchdog(sleepFails: true)
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.log.contains("sleep request failed"))
        XCTAssertFalse(result.log.contains("sleep requested"))
    }

    func testStaleOrFutureDatedHeartbeatDoesNotBlockRecovery() throws {
        for age: TimeInterval in [240, -600] {
            let result = try runWatchdog(statusAge: age)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.calls, ["-a disablesleep 0", "sleepnow"])
        }
    }
}
