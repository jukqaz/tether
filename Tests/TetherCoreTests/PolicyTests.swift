import XCTest
@testable import TetherCore

final class PolicyTests: XCTestCase {
    private func actions(_ power: PowerSource, lid: Bool, sd: Bool, full: Bool = true, ext: Bool = false,
                         triggers: Set<Trigger> = [.power], enabled: Bool = true,
                         pending: Bool = false) -> [Action] {
        Policy.actions(for: Snapshot(power: power, lidClosed: lid, sleepDisabled: sd,
                                     fullWake: full, externalDisplay: ext),
                       triggers: triggers, enabled: enabled, sleepNowPending: pending)
    }

    // Power connected: clamshell on, whatever the lid is doing.
    func testPluggedInLidOpenTurnsClamshellOn() {
        XCTAssertEqual(actions(.ac, lid: false, sd: false), [.setSleepDisabled(true)])
    }

    func testPluggedInWhileLidClosedTurnsClamshellOn() {
        XCTAssertEqual(actions(.ac, lid: true, sd: false), [.setSleepDisabled(true)])
    }

    func testAlreadyOnDoesNothing() {
        XCTAssertEqual(actions(.ac, lid: true, sd: true, triggers: [.timer]), [])
    }

    // Clamshell mode leaves the session alone: no display sleep, which would lock this Mac.
    func testClosingLidOnACKeepsTheSessionAsIs() {
        XCTAssertEqual(actions(.ac, lid: true, sd: true, triggers: [.lid]), [])
    }

    func testClosingLidOnACWithExternalDisplayKeepsTheSessionAsIs() {
        XCTAssertEqual(actions(.ac, lid: true, sd: true, ext: true, triggers: [.lid]), [])
    }

    // Power disconnected: clamshell off, whatever the lid is doing.
    func testUnpluggedLidOpenTurnsClamshellOff() {
        XCTAssertEqual(actions(.battery, lid: false, sd: true), [.setSleepDisabled(false)])
    }

    func testUnpluggedWithLidClosedSleepsRightAway() {
        XCTAssertEqual(actions(.battery, lid: true, sd: true), [.setSleepDisabled(false), .sleepSystem])
    }

    func testUnpluggedWithLidClosedSleepsEvenWithExternalDisplay() {
        XCTAssertEqual(actions(.battery, lid: true, sd: true, ext: true),
                       [.setSleepDisabled(false), .sleepSystem])
    }

    func testBatteryLidClosedButStillAwakeIsPutToSleep() {
        XCTAssertEqual(actions(.battery, lid: true, sd: false, triggers: [.timer]), [.sleepSystem])
    }

    // Closing the lid on battery is macOS's own clamshell sleep; Tether stays out of the way.
    func testClosingLidOnBatteryIsLeftToMacOS() {
        XCTAssertEqual(actions(.battery, lid: true, sd: false, triggers: [.lid]), [])
    }

    // ...unless the flag is still set, e.g. the lid closes before the unplug was handled.
    func testClosingLidWhileFlagStillSetIsForced() {
        XCTAssertEqual(actions(.battery, lid: true, sd: true, triggers: [.lid]),
                       [.setSleepDisabled(false), .sleepSystem])
    }

    func testDarkWakeOnBatteryIsLeftAlone() {
        XCTAssertEqual(actions(.battery, lid: true, sd: false, full: false, triggers: [.wake]), [])
    }

    func testUnpluggedDuringDarkWakeOnlyClearsTheFlag() {
        XCTAssertEqual(actions(.battery, lid: true, sd: true, full: false), [.setSleepDisabled(false)])
    }

    func testBatteryLidOpenIsNormalUse() {
        XCTAssertEqual(actions(.battery, lid: false, sd: false, triggers: [.timer]), [])
    }

    func testUnknownPowerSourceWaits() {
        XCTAssertEqual(actions(.unknown, lid: true, sd: true, triggers: [.start]), [])
    }

    // Tether turned off: back to plain macOS behaviour.
    func testTurningTetherOffOnACClearsTheFlag() {
        XCTAssertEqual(actions(.ac, lid: false, sd: true, triggers: [.settings], enabled: false),
                       [.setSleepDisabled(false)])
    }

    func testTurningTetherOffWithLidClosedSleeps() {
        XCTAssertEqual(actions(.ac, lid: true, sd: true, triggers: [.settings], enabled: false),
                       [.setSleepDisabled(false), .sleepSystem])
    }

    func testTurningTetherOffKeepsNativeClamshellWithExternalDisplay() {
        XCTAssertEqual(actions(.ac, lid: true, sd: true, ext: true, triggers: [.settings], enabled: false),
                       [.setSleepDisabled(false)])
    }

    // Sleep now: works on AC even though Apple menu > Sleep is blocked there.
    func testSleepNowOnAC() {
        XCTAssertEqual(actions(.ac, lid: false, sd: true, triggers: [.sleepNow], pending: true),
                       [.setSleepDisabled(false), .sleepSystem])
    }

    func testSleepNowWindowDoesNotReenableClamshell() {
        XCTAssertEqual(actions(.ac, lid: false, sd: false, triggers: [.timer], pending: true), [])
    }
}
