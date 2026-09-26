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

final class KeyComboTests: XCTestCase {
    func testDisplayUsesApplesModifierOrder() {
        let all = KeyCombo.command | KeyCombo.shift | KeyCombo.option | KeyCombo.control
        XCTAssertEqual(KeyCombo(keyCode: 0x01, modifiers: all).display, "⌃⌥⇧⌘S")
        XCTAssertEqual(KeyCombo(keyCode: 0x60, modifiers: KeyCombo.command).display, "⌘F5")
        XCTAssertEqual(KeyCombo(keyCode: 0x31, modifiers: KeyCombo.option).display, "⌥Space")
    }

    func testNeedsCommandOptionOrControl() {
        XCTAssertFalse(KeyCombo(keyCode: 0x01, modifiers: 0).isValid)
        XCTAssertFalse(KeyCombo(keyCode: 0x01, modifiers: KeyCombo.shift).isValid)
        XCTAssertTrue(KeyCombo(keyCode: 0x01, modifiers: KeyCombo.control | KeyCombo.shift).isValid)
    }

    func testLabelsComeFromTheUSLayout() {
        XCTAssertEqual(KeyCombo.keyName(0x01), "S")
        XCTAssertEqual(KeyCombo.keyName(0x2C), "/")
        XCTAssertNil(KeyCombo.keyName(0xFF))
        XCTAssertEqual(KeyCombo(keyCode: 0xFF, modifiers: KeyCombo.command, key: "Ä").key, "Ä")
    }
}

final class ControlCompatibilityTests: XCTestCase {
    /// Files written before limits and the heat guard existed still load, with defaults.
    func testOldControlFileLoads() throws {
        let json = #"{"enabled": true, "batteryHoldUntil": 1790395061.7}"#
        let control = try JSONDecoder().decode(Control.self, from: Data(json.utf8))
        XCTAssertNil(control.limits)
        XCTAssertNil(control.heatGuard)
        XCTAssertEqual(control.batteryHoldUntil, 1790395061.7)
    }

    func testRoundTrip() throws {
        let control = Control(enabled: false, limits: UserLimits(batteryFloor: 30, maxHoldHours: 2),
                              heatGuard: HeatGuardSettings(enabled: true, level: 1))
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
