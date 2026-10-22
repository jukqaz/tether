import XCTest
@testable import TetherCore

final class ClosedLidDisplaySettingsTests: XCTestCase {
    func testSchemaSevenUpgradeOnlyAddsDisplayDefaultAndPreservesApprovedChoices() throws {
        var original = IdleSessionSettings()
        original.version = 7
        original.automaticEnabled = true
        original.automaticPowerCondition = .any
        original.manualPowerCondition = .battery
        original.manualBatteryContinuationMinutes = 45
        original.batteryTimeLimit = .fourHours
        original.disconnectPolicy = .continueEligible
        original.disconnectAction = .followOS
        original.allowClosedLid = true
        original.keepDisplayAwake = true
        original.automaticallyResumeAfterProtection = true
        original.startAutomaticOnBatteryDisconnect = true
        original.runtimeMarkers = RuntimeMarkers()
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload.removeValue(forKey: "closedLidDisplayMode")
        let old = try JSONDecoder().decode(IdleSessionSettings.self, from: JSONSerialization.data(withJSONObject: payload))
        let migrated = try XCTUnwrap(old.migratedToCurrentVersion)
        original.version = IdleSessionSettings.currentVersion
        XCTAssertEqual(migrated, original)
        XCTAssertEqual(migrated.closedLidDisplayMode, .off)
    }

    func testDisplayModesRoundTripWithoutStartingWorkOrChangingPowerPolicy() throws {
        for mode in ClosedLidDisplayMode.allCases {
            var saved = IdleSessionSettings()
            saved.closedLidDisplayMode = mode
            let decoded = try JSONDecoder().decode(IdleSessionSettings.self, from: JSONEncoder().encode(saved))
            XCTAssertEqual(decoded, saved)
            let policy = IdleSessionPolicy(settings: decoded)
            XCTAssertFalse(policy.manualActive)
            XCTAssertFalse(policy.automaticActive)
            XCTAssertFalse(policy.decision.generalAssertionRequired)
        }
    }
}
