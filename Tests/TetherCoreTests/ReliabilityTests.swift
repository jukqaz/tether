import XCTest
@testable import TetherCore

final class ReliabilityTests: XCTestCase {
    func testPowerModesPreserveHighPowerAndLegacyFormats() {
        let output = "Battery Power:\n lowpowermode 1\nAC Power:\n powermode 2\n"
        XCTAssertEqual(SystemProbe.lowPowerMode(in: output, section: "Battery Power"), 1)
        XCTAssertEqual(SystemProbe.lowPowerMode(in: output, section: "AC Power"), 2)
        let saved = SystemProbe.powerModeSetting(in: output, section: "AC Power")!
        XCTAssertEqual(saved.arguments(onBattery: false, value: 1), ["-c", "powermode", "1"])
        XCTAssertEqual(saved.arguments(onBattery: false, value: saved.value), ["-c", "powermode", "2"])
        XCTAssertTrue(LowPowerPolicy.shouldRestore(current: 1, saved: 2))
        XCTAssertFalse(LowPowerPolicy.shouldRestore(current: 0, saved: 2))
        XCTAssertNil(PowerModeSetting(key: .lowpowermode, value: 0).arguments(onBattery: false, value: 2))
        for value in [-1, 3, 999] {
            XCTAssertNil(SystemProbe.powerModeSetting(in: "AC Power:\n powermode \(value)\n", section: "AC Power"))
        }
    }
    func testNativeClamshellNeverAddsAnOverrideOrSleepsOnOrdinaryTransitions() {
        for condition in PowerCondition.allCases {
            for enabled in [true, false] {
                for closed in [true, false] {
                    for holding in [true, false] {
                        for flag in [true, false] {
                            var snapshot = Snapshot(power: .ac, lidClosed: closed, sleepDisabled: flag, externalDisplay: true)
                            snapshot.nativeDisplayVerified = true
                            let actions = Policy.actions(for: snapshot, triggers: [.settings, .power, .lid],
                                enabled: enabled, sleepNowPending: false, batteryHold: holding, condition: condition)
                            XCTAssertEqual(actions, flag ? [.setSleepDisabled(false)] : [])
                        }
                    }
                }
            }
        }
    }

    func testUnplugDisplayReturnsToTetherAndExplicitSleepStillWorks() {
        let headless = Snapshot(power: .ac, lidClosed: true, sleepDisabled: false)
        XCTAssertEqual(Policy.actions(for: headless, triggers: [.power], enabled: true, sleepNowPending: false), [.setSleepDisabled(true)])
        let native = Snapshot(power: .ac, lidClosed: true, sleepDisabled: false, externalDisplay: true)
        XCTAssertEqual(Policy.actions(for: native, triggers: [.sleepNow], enabled: true, sleepNowPending: true), [.sleepSystem])
        let battery = Snapshot(power: .battery, lidClosed: true, sleepDisabled: false, externalDisplay: true)
        XCTAssertEqual(Policy.actions(for: battery, triggers: [.power], enabled: true, sleepNowPending: false, batteryHold: true), [.setSleepDisabled(true)])
        XCTAssertEqual(Policy.actions(for: battery, triggers: [.power], enabled: true, sleepNowPending: false), [.sleepSystem])
    }

    func testPendingReservationValidationAndOldSettingsCompatibility() throws {
        var c = try JSONDecoder().decode(Control.self, from: Data(#"{"schemaVersion":2,"enabled":false,"limits":{"batteryFloor":40}}"#.utf8))
        XCTAssertNil(c.pendingHoldMinutes); XCTAssertFalse(c.enabled)
        XCTAssertEqual(c.limits?.batteryFloor, 40)
        c.pendingHoldMinutes = 30
        XCTAssertTrue(c.isSupported)
        XCTAssertEqual(try JSONDecoder().decode(Control.self, from: JSONEncoder().encode(c)), c)
        c.batteryHoldUntil = 123; XCTAssertFalse(c.isSupported)
        c.batteryHoldUntil = nil
        for value in [-1, 0, 241, Int.max] { c.pendingHoldMinutes = value; XCTAssertFalse(c.isSupported) }
    }

    func testBatteryBudgetCannotBeRenewedByShortSessionOrHelperRestart() {
        var state = ProtectionState()
        state.prepareBatteryBudget(power: .battery, needed: true, clock: 100, boot: "fixture-boot")
        state.prepareBatteryBudget(power: .battery, needed: false, clock: 200, boot: "fixture-boot")
        state.restart(boot: "fixture-boot")
        state.prepareBatteryBudget(power: .battery, needed: true, clock: 1000, boot: "fixture-boot")
        XCTAssertEqual(state.batteryRemaining(clock: 1000, user: UserLimits(maxHoldHours: 0.5)), 900)
        state.block("budget")
        let cool = SafetyReadings(temperature: 30, thermal: 0, batteryPercent: 80)
        XCTAssertFalse(state.clearBlock(snapshot: Snapshot(power: .battery, lidClosed: false, sleepDisabled: false), readings: cool, user: nil))
        XCTAssertTrue(state.clearBlock(snapshot: Snapshot(power: .ac, lidClosed: false, sleepDisabled: false), readings: cool, user: nil))
    }

    func testBoundedProcessCapturesOutputAndExitCode() {
        let result = Shell.run("/bin/sh", ["-c", "printf expected; printf error >&2; exit 7"], timeout: 1)
        XCTAssertEqual(result.status, 7); XCTAssertEqual(result.output, "expectederror")
        XCTAssertTrue(result.terminationConfirmed); XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitStatus, 7)
    }

    func testHungProcessCannotBlockCallerIndefinitely() {
        let start = ContinuousTime.now
        let result = Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        XCTAssertEqual(result.status, 124)
        XCTAssertTrue(result.timedOut); XCTAssertTrue(result.terminationConfirmed)
        XCTAssertEqual(result.exitStatus, SIGKILL)
        XCTAssertTrue(ProcessIdentity.exited(pid: result.processID!))
        XCTAssertLessThan(ContinuousTime.now - start, 2)
    }

    func testLargeOutputIsDrainedWithoutUnboundedMemoryOrPipeDeadlock() {
        let result = Shell.run("/usr/bin/yes", ["tether"], timeout: 0.1, maxOutputBytes: 1024)
        XCTAssertEqual(result.status, 124)
        XCTAssertLessThanOrEqual(result.output.utf8.count, 1100)
    }
}
