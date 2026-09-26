import XCTest
@testable import TetherCore

/// Sleep as a last resort when a closed Mac overheats on power with nothing showing it is at a
/// desk, such as in a bag with a power bank.
final class OverheatSleepTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func sleeps(on: Bool = true, ac: Bool = true, lid: Bool = true, external: Bool = false,
                        criticalFor: TimeInterval? = nil, hotFor: TimeInterval? = nil) -> Bool {
        ACThermalPolicy.shouldSleep(clamshellOn: on, onAC: ac, lidClosed: lid, externalDisplay: external,
                                    criticalSince: criticalFor.map { now.addingTimeInterval(-$0) },
                                    hotSince: hotFor.map { now.addingTimeInterval(-$0) }, now: now)
    }

    func testTwoMinutesOfCriticalPressure() {
        XCTAssertFalse(sleeps(criticalFor: 119))
        XCTAssertTrue(sleeps(criticalFor: 120))
    }

    func testAMinuteOfAHotBattery() {
        XCTAssertFalse(sleeps(hotFor: 59))
        XCTAssertTrue(sleeps(hotFor: 60))
    }

    func testNotAtADeskWithADisplayOrWithTheLidOpen() {
        XCTAssertFalse(sleeps(external: true, criticalFor: 600))
        XCTAssertFalse(sleeps(lid: false, criticalFor: 600))
    }

    func testOnlyInClamshellModeOnPower() {
        // On battery the battery hold's own, stricter limits apply.
        XCTAssertFalse(sleeps(ac: false, criticalFor: 600))
        XCTAssertFalse(sleeps(on: false, criticalFor: 600))
        XCTAssertFalse(sleeps())
    }

    func testHotterThanEveryBatteryHoldLimit() {
        XCTAssertGreaterThan(ACThermalPolicy.hotBattery, SafetyPolicy.openLid.hardTemperature - 0.1)
        XCTAssertGreaterThan(ACThermalPolicy.hotBattery, SafetyPolicy.closedLid.hardTemperature)
    }

    func testReportedAfterWake() throws {
        var status = Status(updatedAt: 1, version: "2.0.0", enabled: true, power: .ac, lidClosed: true,
                            sleepDisabled: true, lastEvent: .overheatSleep, lastEventAt: 1)
        status.overheatSleepAt = 1_800_000_000
        let decoded = try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded.overheatSleepAt, 1_800_000_000)
        XCTAssertEqual(decoded.lastEvent, .overheatSleep)
        let old = #"{"updatedAt":1,"version":"1.9.0","enabled":true,"power":"ac","lidClosed":false,"sleepDisabled":true}"#
        XCTAssertNil(try JSONDecoder().decode(Status.self, from: Data(old.utf8)).overheatSleepAt)
    }

    func testEventHasWordsInBothLanguages() {
        let saved = Localization.current
        defer { Localization.current = saved }
        Localization.current = .english
        XCTAssertTrue(EventKind.overheatSleep.displayText.contains("sleep"))
        Localization.current = .korean
        XCTAssertTrue(EventKind.overheatSleep.displayText.contains("잠재움"))
        XCTAssertFalse(EventKind.overheatSleep.logText.isEmpty)
    }
}

final class TetherStateTests: XCTestCase {
    private func state(supported: Bool = true, installed: Bool = true, responding: Bool = true, enabled: Bool = true,
                       holding: Bool = false, heatGuard: Bool = false, thermal: Int = 0,
                       sleepDisabled: Bool = true) -> TetherState {
        TetherState.resolve(supportedMac: supported, helperInstalled: installed, helperResponding: responding,
                            enabled: enabled, holdingOnBattery: holding, heatGuard: heatGuard, thermal: thermal,
                            sleepDisabled: sleepDisabled)
    }

    func testProblemsComeFirst() {
        XCTAssertEqual(state(supported: false, installed: false), .unsupported)
        XCTAssertEqual(state(installed: false, responding: false), .helperMissing)
        XCTAssertEqual(state(responding: false, enabled: false), .helperDown)
    }

    func testTheSwitchBeatsThePowerSituation() {
        XCTAssertEqual(state(enabled: false, holding: true, heatGuard: true), .off)
    }

    func testPowerSituations() {
        XCTAssertEqual(state(holding: true, heatGuard: true), .holdingOnBattery)
        XCTAssertEqual(state(heatGuard: true, thermal: 2), .heatGuard(critical: false))
        XCTAssertEqual(state(heatGuard: true, thermal: 3), .heatGuard(critical: true))
        XCTAssertEqual(state(), .clamshellOn)
        XCTAssertEqual(state(sleepDisabled: false), .clamshellOff)
        // The heat guard only matters while clamshell mode keeps the Mac awake.
        XCTAssertEqual(state(heatGuard: true, sleepDisabled: false), .clamshellOff)
    }
}

final class LowPowerPolicyTests: XCTestCase {
    func testOnlyDuringAHoldOnBatteryAndOnlyIfAllowed() {
        XCTAssertTrue(LowPowerPolicy.wantsOnBattery(holdingOnBattery: true, allowed: nil), "on by default")
        XCTAssertTrue(LowPowerPolicy.wantsOnBattery(holdingOnBattery: true, allowed: true))
        XCTAssertFalse(LowPowerPolicy.wantsOnBattery(holdingOnBattery: true, allowed: false))
        XCTAssertFalse(LowPowerPolicy.wantsOnBattery(holdingOnBattery: false, allowed: true))
    }

    func testRestoresOnlyWhatTetherChanged() {
        XCTAssertTrue(LowPowerPolicy.shouldRestore(current: 1, saved: 0))
        // The user switched it off meanwhile, or it was already on before Tether: leave it.
        XCTAssertFalse(LowPowerPolicy.shouldRestore(current: 0, saved: 0))
        XCTAssertFalse(LowPowerPolicy.shouldRestore(current: 1, saved: 1))
        XCTAssertFalse(LowPowerPolicy.shouldRestore(current: nil, saved: 0))
    }

    func testOlderControlFilesKeepLowPowerModeOn() throws {
        let old = #"{"enabled": true, "batteryHoldUntil": 1800000000}"#
        let control = try JSONDecoder().decode(Control.self, from: Data(old.utf8))
        XCTAssertNil(control.holdLowPower)
        XCTAssertTrue(LowPowerPolicy.wantsOnBattery(holdingOnBattery: true, allowed: control.holdLowPower))
    }
}

/// A charger that can't keep up counts as AC; the battery must not run flat with the lid closed.
final class WeakChargerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func readings(_ percent: Int, current: Int?) -> SafetyReadings {
        SafetyReadings(temperature: 32, thermal: 0, batteryPercent: percent, current: current)
    }

    func testRunningDownNeedsTheFloorAndADrain() {
        func down(_ percent: Int, _ current: Int?, ac: Bool = true, lid: Bool = true, on: Bool = true) -> Bool {
            WeakChargerPolicy.isRunningDown(readings(percent, current: current), onAC: ac, lidClosed: lid, clamshellOn: on, floor: 20)
        }
        XCTAssertTrue(down(20, -800))
        XCTAssertFalse(down(21, -800), "above the floor")
        XCTAssertFalse(down(15, 0), "a charge limit holding at 0 mA isn't draining")
        XCTAssertFalse(down(15, -50), "noise")
        XCTAssertFalse(down(15, nil), "unknown current")
        XCTAssertFalse(down(15, -800, ac: false), "on battery the hold's limits apply")
        XCTAssertFalse(down(15, -800, lid: false))
        XCTAssertFalse(down(15, -800, on: false))
    }

    func testSleepsAfterAMinuteWithNoDisplay() {
        XCTAssertFalse(WeakChargerPolicy.shouldSleep(externalDisplay: false, drainingSince: now.addingTimeInterval(-59), now: now))
        XCTAssertTrue(WeakChargerPolicy.shouldSleep(externalDisplay: false, drainingSince: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(WeakChargerPolicy.shouldSleep(externalDisplay: true, drainingSince: now.addingTimeInterval(-600), now: now))
        XCTAssertFalse(WeakChargerPolicy.shouldSleep(externalDisplay: false, drainingSince: nil, now: now))
    }

    func testReportedAfterWake() throws {
        var status = Status(updatedAt: 1, version: "2.0.0", enabled: true, power: .ac, lidClosed: true,
                            sleepDisabled: true, lastEvent: .weakChargerSleep, lastEventAt: 1)
        status.weakChargerSleepAt = 1_800_000_000
        let decoded = try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded.weakChargerSleepAt, 1_800_000_000)
    }
}

final class HoldStartTests: XCTestCase {
    func testAHoldNeedsMoreThanTheFloor() {
        XCTAssertTrue(SafetyPolicy.canStartHold(batteryPercent: 21))
        XCTAssertFalse(SafetyPolicy.canStartHold(batteryPercent: 20))
        XCTAssertFalse(SafetyPolicy.canStartHold(batteryPercent: 35, user: UserLimits(batteryFloor: 40)))
        XCTAssertTrue(SafetyPolicy.canStartHold(batteryPercent: nil), "no reading: the helper's own check still applies")
    }
}

/// The last-resort timers, run on a simulated clock.
final class SafetyNetTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let closedOnPower = Snapshot(power: .ac, lidClosed: true, sleepDisabled: true)

    private func readings(thermal: Int = 0, temperature: Double = 32, percent: Int = 80, current: Int = 0) -> SafetyReadings {
        SafetyReadings(temperature: temperature, thermal: thermal, batteryPercent: percent, current: current)
    }

    private func run(_ tracker: inout SafetyNetTracker, _ s: Snapshot, _ r: SafetyReadings, at seconds: TimeInterval) -> EventKind? {
        tracker.update(s, clamshellOn: true, readings: r, floor: 20, now: start.addingTimeInterval(seconds))
    }

    func testCriticalForTwoMinutesSleeps() {
        var t = SafetyNetTracker()
        XCTAssertNil(run(&t, closedOnPower, readings(thermal: 3), at: 0))
        XCTAssertTrue(t.isWatching)
        XCTAssertNil(run(&t, closedOnPower, readings(thermal: 3), at: 119))
        XCTAssertEqual(run(&t, closedOnPower, readings(thermal: 3), at: 120), .overheatSleep)
        XCTAssertFalse(t.isWatching, "starts over after a sleep")
    }

    func testCoolingDownStartsTheCountAgain() {
        var t = SafetyNetTracker()
        _ = run(&t, closedOnPower, readings(thermal: 3), at: 0)
        _ = run(&t, closedOnPower, readings(thermal: 1), at: 60)
        XCTAssertNil(run(&t, closedOnPower, readings(thermal: 3), at: 100))
        XCTAssertNil(run(&t, closedOnPower, readings(thermal: 3), at: 219))
        XCTAssertEqual(run(&t, closedOnPower, readings(thermal: 3), at: 220), .overheatSleep)
    }

    func testHotBatteryForAMinuteSleeps() {
        var t = SafetyNetTracker()
        XCTAssertNil(run(&t, closedOnPower, readings(temperature: 45.5), at: 0))
        XCTAssertEqual(run(&t, closedOnPower, readings(temperature: 45.5), at: 60), .overheatSleep)
    }

    func testWeakChargerAtTheFloorSleeps() {
        var t = SafetyNetTracker()
        XCTAssertNil(run(&t, closedOnPower, readings(percent: 19, current: -900), at: 0))
        XCTAssertEqual(run(&t, closedOnPower, readings(percent: 19, current: -900), at: 60), .weakChargerSleep)
    }

    func testAnExternalDisplayMeansADeskButStillTimesTheAlert() {
        var t = SafetyNetTracker()
        let desk = Snapshot(power: .ac, lidClosed: true, sleepDisabled: true, externalDisplay: true)
        XCTAssertNil(run(&t, desk, readings(thermal: 3), at: 0))
        XCTAssertNil(run(&t, desk, readings(thermal: 3), at: 600))
        XCTAssertEqual(t.criticalSince, start, "the critical-heat alert still counts")
    }

    func testNothingWithTheLidOpenOrOnBattery() {
        var t = SafetyNetTracker()
        let open = Snapshot(power: .ac, lidClosed: false, sleepDisabled: true)
        let battery = Snapshot(power: .battery, lidClosed: true, sleepDisabled: true)
        XCTAssertNil(run(&t, open, readings(thermal: 3), at: 0))
        XCTAssertNil(run(&t, battery, readings(thermal: 3), at: 600))
        XCTAssertFalse(t.isWatching)
    }
}

final class HoldExtensionTests: XCTestCase {
    func testPlusMinutesExtends() {
        XCTAssertEqual(TetherCommand.parse(["hold", "+30m"]), .extendHold(minutes: 30))
        XCTAssertEqual(TetherCommand.parse(url: URL(string: "tether://hold/+1h")!), .extendHold(minutes: 60))
        XCTAssertNil(TetherCommand.parse(["hold", "+5h"]), "beyond the cap")
    }

    func testTheCapCountsFromTheFirstSighting() {
        // An extension keeps holdSeenAt, so the deadline can't pass 4 h from the start.
        let seen = 1_800_000_000.0
        let state = HelperState(holdValue: seen + 5 * 3600, holdSeenAt: seen)
        let deadline = state.holdDeadline(requested: seen + 5 * 3600, now: Date(timeIntervalSince1970: seen + 3600))
        XCTAssertEqual(deadline?.timeIntervalSince1970, seen + 4 * 3600)
    }
}

final class AppPresencePathTests: XCTestCase {
    func testOnlyATetherAppPathCounts() {
        var presence = AppPresence()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = presence.shouldRetire(path: "/Users/x/Library/LaunchAgents/other", exists: false, now: now)
        XCTAssertFalse(presence.shouldRetire(path: "/Users/x/Library/LaunchAgents/other", exists: false,
                                             now: now.addingTimeInterval(AppPresence.grace + 1)))
        _ = presence.shouldRetire(path: "/Applications/Tether.app/Contents/MacOS/Tether", exists: false, now: now)
        XCTAssertTrue(presence.shouldRetire(path: "/Applications/Tether.app/Contents/MacOS/Tether", exists: false,
                                            now: now.addingTimeInterval(AppPresence.grace + 1)))
    }
}
