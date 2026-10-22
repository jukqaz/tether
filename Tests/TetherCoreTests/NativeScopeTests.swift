import XCTest
@testable import TetherCore

/// The final product contract: macOS owns energy modes and temperature management;
/// Tether bounds its own keep-awake session using OS pressure, charge and time.
final class NativeScopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMissingOptionalTemperatureDoesNotMakePublicReadingsInvalid() {
        let readings = SafetyReadings(temperature: nil, thermal: 0, batteryPercent: 80)
        XCTAssertTrue(readings.isValid)
        XCTAssertNil(SafetyPolicy.verdict(readings, lidClosed: true, now: now,
            holdUntil: now.addingTimeInterval(60), warmSince: nil))
    }

    func testInvalidOptionalTemperatureCannotBreakStatusJSON() throws {
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            let readings = SafetyReadings(temperature: invalid, thermal: 0, batteryPercent: 80)
            XCTAssertNil(readings.temperature)
            let status = Status(updatedAt: 1, version: TetherPaths.version, enabled: true, power: .ac,
                lidClosed: true, sleepDisabled: true, lastEvent: nil, lastEventAt: nil,
                batteryTemperature: readings.temperature)
            XCTAssertNoThrow(try JSONEncoder().encode(status))
        }
    }

    func testOSSeriousAndCriticalStopWithoutInventingTemperatureOrDelay() {
        for closed in [false, true] {
            for thermal in [2, 3] {
                XCTAssertEqual(SafetyPolicy.verdict(SafetyReadings(temperature: 25, thermal: thermal, batteryPercent: 80),
                    lidClosed: closed, now: now, holdUntil: now.addingTimeInterval(60), warmSince: nil), .thermal)
            }
        }
        XCTAssertNil(SafetyPolicy.verdict(SafetyReadings(temperature: 80, thermal: 0, batteryPercent: 80),
            lidClosed: true, now: now, holdUntil: now.addingTimeInterval(60), warmSince: now.addingTimeInterval(-100)))
    }

    func testMissingRequiredChargeOrUnknownThermalStillStops() {
        for readings in [SafetyReadings(temperature: 30, thermal: 0, batteryPercent: nil),
                         SafetyReadings(temperature: 30, thermal: -1, batteryPercent: 80),
                         SafetyReadings(temperature: 30, thermal: 4, batteryPercent: 80)] {
            XCTAssertFalse(readings.isValid)
            XCTAssertEqual(SafetyPolicy.verdict(readings, lidClosed: true, now: now,
                holdUntil: now.addingTimeInterval(60), warmSince: nil), .sensor)
        }
    }

    func testExplicitResumeUsesThermalAndReserveNotOptionalCelsius() {
        var protection = ProtectionState(); protection.block("thermal")
        let snapshot = Snapshot(power: .ac, lidClosed: false, sleepDisabled: false)
        XCTAssertFalse(protection.clearBlock(snapshot: snapshot,
            readings: SafetyReadings(temperature: 25, thermal: 2, batteryPercent: 80), user: nil))
        XCTAssertTrue(protection.clearBlock(snapshot: snapshot,
            readings: SafetyReadings(temperature: nil, thermal: 1, batteryPercent: 80), user: nil))
    }

    func testNativeClamshellNeverReceivesTetherProtectionSleep() {
        for thermal in [2, 3] {
            var tracker = SafetyNetTracker()
            var native = Snapshot(power: .ac, lidClosed: true, sleepDisabled: false, externalDisplay: true)
            native.nativeDisplayVerified = true
            let readings = SafetyReadings(temperature: 90, thermal: thermal, batteryPercent: 10, current: -1000)
            XCTAssertNil(tracker.update(native, clamshellOn: true, readings: readings, floor: 20, now: now))
            XCTAssertNil(tracker.update(native, clamshellOn: true, readings: readings, floor: 20, now: now.addingTimeInterval(120)))
        }
    }

    func testSchema2MigrationPreservesUsageAndBacksUpRemovedPolicy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tether-scope-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("control.json")
        let original = Data(#"{"schemaVersion":2,"enabled":true,"powerCondition":"battery","automaticHoldMinutes":30,"limits":{"batteryFloor":40,"maxHoldHours":1,"closedLidMaxTemperature":38},"holdLowPower":true,"heatGuard":{"enabled":true,"level":1},"debugLog":true}"#.utf8)
        try original.write(to: path)
        let report = try XCTUnwrap(SettingsMigration.migrate(controlPath: path.path))
        let migrated = try XCTUnwrap(JSONFile.read(Control.self, from: path.path))
        XCTAssertEqual(migrated.schemaVersion, 4)
        XCTAssertFalse(migrated.enabled, "Changed explicit temperature policy needs a deliberate resume")
        XCTAssertEqual(migrated.condition, .ac)
        XCTAssertEqual(migrated.automaticHoldMinutes, 30)
        XCTAssertEqual(migrated.limits, UserLimits(batteryFloor: 40, maxHoldHours: 1))
        XCTAssertNil(migrated.heatGuard); XCTAssertNil(migrated.holdLowPower)
        XCTAssertEqual(migrated.debugLog, true)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("migrations/\(report.backupName)")), original)
        XCTAssertNil(try SettingsMigration.migrate(controlPath: path.path))
    }
}
