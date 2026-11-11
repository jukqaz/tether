import Foundation
import XCTest
@testable import TetherCore

final class DisplaySessionSettingsTests: XCTestCase {
    func testDisplayAwakeDefaultsToOff() {
        XCTAssertFalse(IdleSessionSettings().keepDisplayAwake)
    }

    func testMissingDisplayKeyPreservesEveryExistingChoice() throws {
        var original = IdleSessionSettings()
        original.automaticEnabled = true
        original.powerCondition = .any
        original.automaticHoldMinutes = 45
        original.manualBatteryContinuationMinutes = 30
        original.allowClosedLid = true
        original.disconnectAction = .followOS
        original.lastManualDurationSeconds = nil
        original.limits = UserLimits(batteryFloor: 35)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        encoded.removeValue(forKey: "keepDisplayAwake")
        let decoded = try JSONDecoder().decode(IdleSessionSettings.self,
            from: JSONSerialization.data(withJSONObject: encoded))

        XCTAssertFalse(decoded.keepDisplayAwake)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.isSupported)
    }

    func testLegacyMigrationDefaultsDisplayOffAndKeepsSavedPowerAndLidChoices() throws {
        var original = IdleSessionSettings()
        original.version = 4
        original.automaticEnabled = true
        original.powerCondition = .battery
        original.automaticHoldMinutes = 45
        original.manualBatteryContinuationMinutes = 30
        original.allowClosedLid = true
        original.disconnectAction = .followOS
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        encoded.removeValue(forKey: "keepDisplayAwake")
        let decoded = try JSONDecoder().decode(IdleSessionSettings.self,
            from: JSONSerialization.data(withJSONObject: encoded))
        let migrated = try XCTUnwrap(decoded.migratedToCurrentVersion)

        XCTAssertFalse(migrated.keepDisplayAwake)
        XCTAssertEqual(migrated.version, IdleSessionSettings.currentVersion)
        XCTAssertFalse(migrated.automaticEnabled)
        XCTAssertEqual(migrated.condition, .ac)
        XCTAssertEqual(migrated.powerCondition, .battery, "The retired saved choice remains migration evidence")
        XCTAssertEqual(migrated.automaticMinutes, 45)
        XCTAssertNil(migrated.manualBatteryContinuationMinutes)
        XCTAssertTrue(migrated.allowClosedLid)
        XCTAssertEqual(migrated.disconnectAction, .followOS)
    }

    func testDisplayChoiceRoundTripsWithoutChangingOtherChoices() throws {
        for enabled in [false, true] {
            var original = IdleSessionSettings()
            original.keepDisplayAwake = enabled
            original.automaticEnabled = true
            original.powerCondition = .any
            original.manualBatteryContinuationMinutes = 30
            original.allowClosedLid = true
            let decoded = try JSONDecoder().decode(IdleSessionSettings.self, from: JSONEncoder().encode(original))

            XCTAssertEqual(decoded, original)
            XCTAssertEqual(decoded.keepDisplayAwake, enabled)
        }
    }
}
