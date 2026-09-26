import XCTest
@testable import TetherCore

final class UserLimitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDefaultsWhenNothingChosen() {
        XCTAssertEqual(SafetyPolicy.limits(lidClosed: true, user: nil), SafetyPolicy.closedLid)
        XCTAssertEqual(SafetyPolicy.limits(lidClosed: false, user: UserLimits()), SafetyPolicy.openLid)
        XCTAssertEqual(SafetyPolicy.floor(nil), SafetyPolicy.batteryFloor)
        XCTAssertEqual(SafetyPolicy.maxHold(nil), SafetyPolicy.maxHold)
        XCTAssertTrue(UserLimits().isDefault)
    }

    func testStricterTemperatureMovesTheEarlyLimitWithIt() {
        let l = SafetyPolicy.limits(lidClosed: true, user: UserLimits(closedLidMaxTemperature: 40))
        XCTAssertEqual(l.hardTemperature, 40)
        XCTAssertEqual(l.earlyTemperature, 37)
        XCTAssertEqual(SafetyPolicy.limits(lidClosed: false, user: UserLimits(openLidMaxTemperature: 42)).hardTemperature, 42)
    }

    /// A hand-edited control file must not loosen anything.
    func testLooserValuesAreIgnored() {
        let loose = UserLimits(batteryFloor: 5, closedLidMaxTemperature: 60, openLidMaxTemperature: 70, maxHoldHours: 24)
        XCTAssertEqual(SafetyPolicy.limits(lidClosed: true, user: loose), SafetyPolicy.closedLid)
        XCTAssertEqual(SafetyPolicy.limits(lidClosed: false, user: loose), SafetyPolicy.openLid)
        XCTAssertEqual(SafetyPolicy.floor(loose), SafetyPolicy.batteryFloor)
        XCTAssertEqual(SafetyPolicy.maxHold(loose), SafetyPolicy.maxHold)
    }

    func testNonsenseValuesAreBounded() {
        let extreme = UserLimits(batteryFloor: 99, closedLidMaxTemperature: 0, maxHoldHours: 0.01)
        XCTAssertEqual(SafetyPolicy.floor(extreme), SafetyPolicy.highestFloor)
        XCTAssertEqual(SafetyPolicy.limits(lidClosed: true, user: extreme).hardTemperature, SafetyPolicy.lowestTemperature)
        XCTAssertEqual(SafetyPolicy.maxHold(extreme), 1800)
    }

    func testVerdictUsesTheChosenLimits() {
        let user = UserLimits(batteryFloor: 40, closedLidMaxTemperature: 40)
        let far = now.addingTimeInterval(3600)
        let warm = SafetyReadings(temperature: 40.2, thermal: 0, batteryPercent: 80)
        XCTAssertNil(SafetyPolicy.verdict(warm, lidClosed: true, now: now, holdUntil: far, warmSince: nil))
        XCTAssertEqual(SafetyPolicy.verdict(warm, lidClosed: true, now: now, holdUntil: far, warmSince: nil, user: user), .heat)
        let low = SafetyReadings(temperature: 30, thermal: 0, batteryPercent: 39)
        XCTAssertNil(SafetyPolicy.verdict(low, lidClosed: true, now: now, holdUntil: far, warmSince: nil))
        XCTAssertEqual(SafetyPolicy.verdict(low, lidClosed: true, now: now, holdUntil: far, warmSince: nil, user: user), .battery)
    }

    func testHoldDeadlineHonoursTheChosenMaximum() {
        let seen = now.timeIntervalSince1970
        let state = HelperState(holdValue: seen + 4 * 3600, holdSeenAt: seen)
        let capped = state.holdDeadline(requested: seen + 4 * 3600, now: now, maxHold: 3600)
        XCTAssertEqual(capped?.timeIntervalSince1970, seen + 3600)
        let loose = state.holdDeadline(requested: seen + 4 * 3600, now: now, maxHold: 10 * 3600)
        XCTAssertEqual(loose?.timeIntervalSince1970, seen + 4 * 3600)
    }
}

final class HeatGuardSettingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func wants(thermal: Int, _ settings: HeatGuardSettings) -> Bool {
        ACThermalPolicy.wantsLowPower(clamshellOn: true, onAC: true, lidClosed: true, thermal: thermal,
                                      lowPowerOn: false, coolSince: now, now: now, settings: settings)
    }

    func testOffNeverTurnsLowPowerOn() {
        XCTAssertFalse(wants(thermal: 3, HeatGuardSettings(enabled: false, level: 2)))
    }

    func testEarlierLevel() {
        XCTAssertTrue(wants(thermal: 1, HeatGuardSettings(enabled: true, level: 1)))
        XCTAssertFalse(wants(thermal: 1, .standard))
        XCTAssertTrue(wants(thermal: 2, .standard))
    }

    func testLevelIsBounded() {
        XCTAssertEqual(HeatGuardSettings(enabled: true, level: 0).threshold, 1)
        XCTAssertEqual(HeatGuardSettings(enabled: true, level: 3).threshold, 2)
    }
}

final class ControlCompatibilityTests: XCTestCase {
    /// Files written before limits and the heat guard existed still load, with defaults.
    func testOldControlFileLoads() throws {
        let json = #"{"enabled": true, "batteryHoldUntil": 1790395061.7}"#
        let control = try JSONDecoder().decode(Control.self, from: Data(json.utf8))
        XCTAssertNil(control.limits)
        XCTAssertNil(control.heatGuard)
        XCTAssertNil(control.autoLimits)
        XCTAssertEqual(control.batteryHoldUntil, 1790395061.7)
    }

    func testRoundTrip() throws {
        var control = Control(enabled: false, limits: UserLimits(batteryFloor: 30, maxHoldHours: 2),
                              heatGuard: HeatGuardSettings(enabled: true, level: 1))
        control.autoLimits = true
        XCTAssertEqual(try JSONDecoder().decode(Control.self, from: JSONEncoder().encode(control)), control)
    }
}

final class VersionTests: XCTestCase {
    func testNumericComparison() {
        XCTAssertTrue(Version.isNewer("2.0.1", than: "2.0.0"))
        XCTAssertTrue(Version.isNewer("2.0.10", than: "2.0.9"))
        XCTAssertTrue(Version.isNewer("2.1", than: "2.0.5"))
        XCTAssertFalse(Version.isNewer("2.0", than: "2.0.0"))
        XCTAssertFalse(Version.isNewer("1.9.9", than: "2.0.0"))
    }
}

final class AppPresenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let path = "/Applications/Tether.app/Contents/MacOS/Tether"

    func testRetiresOnlyAfterTheGracePeriod() {
        var presence = AppPresence()
        XCTAssertFalse(presence.shouldRetire(path: path, exists: false, now: t0))
        XCTAssertFalse(presence.shouldRetire(path: path, exists: false, now: t0.addingTimeInterval(599)))
        XCTAssertTrue(presence.shouldRetire(path: path, exists: false, now: t0.addingTimeInterval(600)))
    }

    func testComingBackResetsTheClock() {
        var presence = AppPresence()
        _ = presence.shouldRetire(path: path, exists: false, now: t0)
        XCTAssertFalse(presence.shouldRetire(path: path, exists: true, now: t0.addingTimeInterval(300)))
        XCTAssertFalse(presence.shouldRetire(path: path, exists: false, now: t0.addingTimeInterval(700)))
    }

    func testUnknownOrTranslocatedPathsNeverCount() {
        var presence = AppPresence()
        XCTAssertFalse(presence.shouldRetire(path: nil, exists: false, now: t0.addingTimeInterval(9999)))
        let translocated = "/private/var/folders/x/AppTranslocation/ABC/d/Tether.app/Contents/MacOS/Tether"
        XCTAssertFalse(presence.shouldRetire(path: translocated, exists: false, now: t0))
        XCTAssertFalse(presence.shouldRetire(path: translocated, exists: false, now: t0.addingTimeInterval(9999)))
    }

    func testHoldSourceWording() {
        Localization.current = .english
        defer { Localization.current = .preferred }
        XCTAssertNil(Texts.holdSource(nil))
        XCTAssertNil(Texts.holdSource("app"))
        XCTAssertEqual(Texts.holdSource("run:make"), "tether run: make")
        XCTAssertEqual(Texts.holdSource("cli"), "from the terminal")
    }
}
