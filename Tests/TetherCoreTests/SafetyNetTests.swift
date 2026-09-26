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
