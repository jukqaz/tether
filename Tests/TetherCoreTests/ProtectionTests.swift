import XCTest
@testable import TetherCore

final class ProtectionTests: XCTestCase {
    private let cool = SafetyReadings(temperature: 30, thermal: 0, batteryPercent: 80)
    private let battery = Snapshot(power: .battery, lidClosed: true, sleepDisabled: false)
    private let ac = Snapshot(power: .ac, lidClosed: true, sleepDisabled: false)

    func testLegacyProfilesMigrateWithoutBroadeningPowerBehavior() throws {
        for profile in ["tasks", "travel", "presentation", "remote"] {
            let json = "{\"schemaVersion\":1,\"enabled\":true,\"profile\":\"\(profile)\",\"batteryHoldUntil\":9999999999}"
            let control = try JSONDecoder().decode(Control.self, from: Data(json.utf8))
            XCTAssertFalse(control.enabled); XCTAssertNil(control.batteryHoldUntil)
            XCTAssertEqual(control.condition, .ac)
            let encoded = String(decoding: try JSONEncoder().encode(control), as: UTF8.self)
            XCTAssertFalse(encoded.contains("profile"))
        }
        let paused = try JSONDecoder().decode(Control.self, from: Data(#"{"enabled":true,"paused":true}"#.utf8))
        XCTAssertFalse(paused.enabled)
    }
    func testOldLatchAndBudgetSurviveWithoutRestoringJobs() throws {
        let json = #"{"sessions":[{"garbage":true}],"events":[],"blockReason":"heat","batteryBudgetStart":42,"budgetBoot":"boot"}"#
        var state = try JSONDecoder().decode(ProtectionState.self, from: Data(json.utf8))
        state.restart(boot: "boot")
        XCTAssertEqual(state.blockReason, "heat"); XCTAssertEqual(state.batteryBudgetStart, 42)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("sessions"))
    }
    func testBatteryBudgetSurvivesRestartAndRequiresACToReset() {
        var state = ProtectionState()
        state.prepareBatteryBudget(power: .battery, needed: true, clock: 100, boot: "fixture-boot")
        state.restart(boot: "fixture-boot")
        state.prepareBatteryBudget(power: .battery, needed: true, clock: 1000, boot: "fixture-boot")
        XCTAssertEqual(state.batteryRemaining(clock: 1000, user: nil), 13500)
        state.prepareBatteryBudget(power: .ac, needed: false, clock: 1100, boot: "fixture-boot")
        XCTAssertEqual(state.batteryRemaining(clock: 1100, user: nil), 13400)
        state.confirmPowerReturn()
        XCTAssertEqual(state.batteryRemaining(clock: 1100, user: nil), 14400)
    }
    func testSafetyStopRequiresKnownPublicThermalAndChargeEvenOnAC() {
        var state = ProtectionState(); state.block("heat")
        XCTAssertFalse(state.clearBlock(snapshot: ac, readings: .init(temperature: 42, thermal: 2, batteryPercent: 80), user: nil))
        XCTAssertFalse(state.clearBlock(snapshot: ac, readings: .init(temperature: nil, thermal: -1, batteryPercent: 80), user: nil))
        XCTAssertFalse(state.clearBlock(snapshot: ac, readings: .init(temperature: 30, thermal: 0, batteryPercent: 20), user: nil))
        XCTAssertEqual(state.blockReason, "heat")
        XCTAssertTrue(state.clearBlock(snapshot: ac, readings: cool, user: nil))
        XCTAssertNil(state.blockReason)
    }
    func testTimeStopCannotBeClearedOnBattery() {
        var state = ProtectionState(); state.block("time")
        XCTAssertFalse(state.clearBlock(snapshot: battery, readings: cool, user: nil))
        XCTAssertTrue(state.clearBlock(snapshot: ac, readings: cool, user: nil))
    }

    func testExplicitBatteryResumeNeedsWarningClearButACIgnoresThatWarning() throws {
        for warning in [Bool?.some(true), nil] {
            var state = ProtectionState(); state.block("battery")
            let readings = SafetyReadings(temperature: nil, thermal: 0, batteryPercent: 80, lowPowerWarning: warning)
            XCTAssertFalse(state.clearBlock(snapshot: battery, readings: readings, user: nil))
            XCTAssertEqual(state.blockReason, "battery")
            state = try JSONDecoder().decode(ProtectionState.self, from: JSONEncoder().encode(state))
            state.restart(boot: "warning-fixture")
            XCTAssertEqual(state.blockReason, "battery", "Restart or cooling cannot resume work")
            XCTAssertTrue(state.clearBlock(snapshot: ac, readings: readings, user: nil))
            XCTAssertNil(state.blockReason)
        }
        var state = ProtectionState(); state.block("battery")
        XCTAssertEqual(state.blockReason, "battery", "A clear observation alone does not clear the persisted latch")
        XCTAssertTrue(state.clearBlock(snapshot: battery, readings: cool, user: nil))
    }
    func testLegacyWarmthTimersDoNotReturnAfterPolicyUpgrade() throws {
        let raw = Data(#"{"warmSince":100,"warmLid":true,"blockReason":"thermal"}"#.utf8)
        var state = try JSONDecoder().decode(ProtectionState.self, from: raw)
        state.restart()
        XCTAssertEqual(state.blockReason, "thermal")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("warmSince"))
    }
    func testPowerConditionsForBothLidStatesAndManualOff() {
        for closed in [true, false] {
            for power in [PowerSource.ac, .battery] {
                let s = Snapshot(power: power, lidClosed: closed, sleepDisabled: false)
                for condition in PowerCondition.allCases {
                    let expected = power == .ac ? condition.includesAC : true
                    XCTAssertEqual(Policy.wantsClamshell(s, enabled: true, sleepNowPending: false, batteryHold: true, condition: condition), expected)
                    XCTAssertFalse(Policy.wantsClamshell(s, enabled: false, sleepNowPending: false, batteryHold: true, condition: condition))
                }
            }
        }
        XCTAssertFalse(Policy.wantsClamshell(battery, enabled: true, sleepNowPending: false, condition: .battery), "automatic mode still needs a bounded timer")
    }
    func testAutomaticHoldStartsOnlyOnPowerEdgeAndNeverAfterCancelOrRestart() {
        var gate = AutomaticHoldGate()
        XCTAssertTrue(gate.entering(eligible: true))
        XCTAssertFalse(gate.entering(eligible: true))
        gate.reset(eligible: true)
        XCTAssertFalse(gate.entering(eligible: true))
        XCTAssertFalse(gate.entering(eligible: false))
        XCTAssertTrue(gate.entering(eligible: true))
    }
    func testDarkWakeNeverEnablesOverrideOrSleepsDisplay() {
        let s = Snapshot(power: .ac, lidClosed: true, sleepDisabled: false, fullWake: false)
        XCTAssertEqual(Policy.actions(for: s, triggers: [.power], enabled: true, sleepNowPending: false), [])
    }
}
