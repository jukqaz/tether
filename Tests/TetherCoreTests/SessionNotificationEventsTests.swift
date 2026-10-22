import XCTest
@testable import TetherCore

final class SessionNotificationEventsTests: XCTestCase {
    private let on = SessionNotificationEvents.Choices(thermal: true, battery: true)
    private let off = SessionNotificationEvents.Choices(thermal: false, battery: false)
    private func sample(manual: Bool = false, automatic: Bool = false) -> UserSessionStatus {
        .init(power: .battery, thermal: 0, batteryPercent: 80, limits: nil, enabled: true,
            automaticEnabled: automatic, automaticActive: automatic, powerCondition: .any, automaticMinutes: 3,
            batteryHoldUntil: automatic ? Date(timeIntervalSince1970: 500) : nil, pendingBatteryMinutes: nil,
            manualActive: manual, holding: manual || automatic, until: nil, blockReason: nil, error: nil,
            canStart: true, manualBatteryRemaining: 7200, manualEndReason: nil, manualMaximumMinutes: 120,
            canStartBatteryHold: true, batteryRemaining: 180, manualStartedAt: manual ? 100 : nil,
            manualContinuousDeadline: manual ? 280 : nil)
    }
    func testStartupDoesNotReplayExistingProtection() {
        for reason in [String?.none, "thermal", "battery", "sensor"] {
            var events = SessionNotificationEvents(), state = sample(manual: true, automatic: true)
            state.blockReason = reason
            XCTAssertTrue(events.observe(state, choices: on, now: 220).isEmpty)
            XCTAssertTrue(events.observe(state, choices: on, now: 221).isEmpty)
        }
    }
    func testManualAndAutomaticNearExpiryAndCompletionRemainSilentWithoutChangingInputs() {
        for reason in [ManualSessionEnd.time, .batteryBudget, .cancelled, .powerDisconnected, .sessionEnded, .observationUnavailable] {
            var events = SessionNotificationEvents(), state = sample(manual: true, automatic: true)
            _ = events.observe(state, choices: on, now: 100)
            state.batteryRemaining = 60
            XCTAssertTrue(events.observe(state, choices: on, now: 220).isEmpty)
            state.manualContinuousDeadline = 270
            state.until = Date(timeIntervalSince1970: .infinity)
            XCTAssertTrue(events.observe(state, choices: on, now: 221).isEmpty)
            state.manualActive = false; state.manualEndReason = reason; state.automaticActive = false; state.holding = false
            let before = state
            XCTAssertTrue(events.observe(state, choices: on, now: 280).isEmpty)
            XCTAssertTrue(events.observe(state, choices: on, now: 281).isEmpty)
            XCTAssertEqual(state, before)
        }
    }
    func testTimeAndBudgetBlocksDoNotBecomeBatteryProtectionAlerts() {
        for reason in ["time", "budget"] {
            var events = SessionNotificationEvents(), state = sample(manual: true, automatic: true)
            _ = events.observe(state, choices: on, now: 100)
            state.manualActive = false; state.automaticActive = false; state.holding = false; state.blockReason = reason
            XCTAssertTrue(events.observe(state, choices: on, now: 280).isEmpty)
        }
    }
    func testProtectionIsOneAllowlistedEventWithIndependentChoices() {
        for reason in ["thermal", "battery", "sensor"] {
            var events = SessionNotificationEvents(), state = sample(manual: true)
            _ = events.observe(state, choices: on, now: 100)
            state.manualActive = false; state.holding = false; state.blockReason = reason; state.manualEndReason = .protection
            XCTAssertEqual(events.observe(state, choices: on, now: 101), [.protection(reason)])
            XCTAssertTrue(events.observe(state, choices: on, now: 102).isEmpty)
        }
        for reason in ["thermal", "sensor", "battery"] {
            var events = SessionNotificationEvents(), state = sample(manual: true)
            _ = events.observe(state, choices: on, now: 100)
            state.manualActive = false; state.blockReason = reason
            let choices = SessionNotificationEvents.Choices(thermal: reason == "battery", battery: reason != "battery")
            XCTAssertTrue(events.observe(state, choices: choices, now: 101).isEmpty)
            XCTAssertTrue(events.observe(state, choices: on, now: 102).isEmpty)
        }
    }
    func testIdleProtectionAndUnknownReasonsAreNotReportedAsStoppedWork() {
        for reason in ["thermal", "battery", "sensor", "secret diagnostic"] {
            var events = SessionNotificationEvents(), state = sample()
            _ = events.observe(state, choices: on, now: 100)
            state.blockReason = reason
            XCTAssertTrue(events.observe(state, choices: on, now: 101).isEmpty)
        }
    }
    func testDisabledProtectionIsConsumedAndEnablingCannotReplayIt() {
        var events = SessionNotificationEvents(), state = sample(manual: true)
        _ = events.observe(state, choices: off, now: 100)
        state.blockReason = "thermal"; state.manualActive = false; state.holding = false
        XCTAssertTrue(events.observe(state, choices: off, now: 101).isEmpty)
        XCTAssertTrue(events.observe(state, choices: on, now: 102).isEmpty)
    }
    func testMalformedObservationDoesNotConsumeAValidProtectionEvent() {
        var events = SessionNotificationEvents(), state = sample(manual: true)
        _ = events.observe(state, choices: on, now: 100)
        state.blockReason = "thermal"; state.manualActive = false; state.holding = false
        for now in [Double.nan, .infinity, -1] {
            XCTAssertTrue(events.observe(state, choices: on, now: now).isEmpty)
        }
        XCTAssertEqual(events.observe(state, choices: on, now: 101), [.protection("thermal")])
    }
}
