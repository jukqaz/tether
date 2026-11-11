import XCTest
import TetherCore
@testable import Tether

final class NotifierTests: XCTestCase {
    private final class NoPowerWrites: IdleAssertionBackend {
        var creates = 0
        func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (-1, nil) }
        func renew(id: UInt32, timeout: TimeInterval) -> Int32 { -1 }
        func level(id: UInt32) -> Int? { nil }
        func release(id: UInt32) -> Int32 { -1 }
    }
    private func sample(manual: Bool = false) -> UserSessionStatus {
        .init(power: .ac, thermal: 0, batteryPercent: 80, limits: nil, enabled: true,
            automaticEnabled: true, automaticActive: true, powerCondition: .ac, automaticMinutes: 3,
            batteryHoldUntil: nil, pendingBatteryMinutes: nil, manualActive: manual, holding: true, until: nil,
            blockReason: nil, error: nil, canStart: true, manualBatteryRemaining: 7200, manualEndReason: nil,
            manualMaximumMinutes: 120, canStartBatteryHold: true, batteryRemaining: 180,
            manualStartedAt: manual ? 100 : nil, manualContinuousDeadline: manual ? 280 : nil)
    }
    func testRemovedTimingNoticesStaySilentWithLegacyPreferenceEnabledAndProtectionStillReports() async throws {
        try await MainActor.run {
            let suite = "TetherNotifier.\(UUID())", old = Localization.current
            let defaults = TestMemoryDefaults(domain: suite)
            defer { defaults.removePersistentDomain(forName: suite); Localization.current = old }
            defaults.set(true, forKey: "notifyHoldEnd")
            Localization.current = .english
            var notices: [(String, String)] = []
            let notifier = Notifier(status: nil, defaults: defaults) { notices.append(($0, $1)) }
            let choices = Notifier.Choices(heat: true, battery: true)
            notifier.checkWork(sample(), choices: choices, now: 99)
            var state = sample(manual: true)
            notifier.checkWork(state, choices: choices, now: 220)
            state.manualActive = false; state.manualEndReason = .time
            notifier.checkWork(state, choices: choices, now: 280)
            notifier.checkWork(state, choices: choices, now: 281)
            XCTAssertTrue(notices.isEmpty)
            state.blockReason = "thermal"; state.automaticActive = false; state.holding = false
            notifier.checkWork(state, choices: choices, now: 282)
            notifier.checkWork(state, choices: choices, now: 283)
            XCTAssertEqual(notices.count, 1); XCTAssertTrue(notices[0].0.contains("thermal protection"))
            XCTAssertFalse(notices[0].1.contains("Mac is asleep"))
            XCTAssertNil(defaults.data(forKey: UserSessionController.preferenceKey))
            XCTAssertEqual(defaults.object(forKey: "notifyHoldEnd") as? Bool, true)
        }
    }
    private func legacySample(_ reason: HoldEnd?, at: Double = 100) -> Status {
        var state = Status(updatedAt: at, version: "test", enabled: true, power: .battery, lidClosed: true,
            sleepDisabled: false, lastEvent: nil, lastEventAt: nil,
            batteryHoldUntil: Date().timeIntervalSince1970 + 30)
        state.batteryHoldSince = Date().timeIntervalSince1970 - 150
        state.lastHoldEnd = reason; state.lastHoldEndAt = reason == nil ? nil : at
        return state
    }
    @MainActor
    private func legacyNotifier(defaults: UserDefaults, deliver: @escaping (String, String) -> Void) -> Notifier {
        for key in ["lastNotifiedHoldEnd", "lastNotifiedThermalAlert", "lastNotifiedOverheatSleep", "lastNotifiedWeakChargerSleep"] {
            defaults.set(0, forKey: key)
        }
        return Notifier(status: legacySample(nil, at: 0), defaults: defaults, deliver: deliver)
    }
    func testLegacyStartupConsumesCurrentProtectionEvenWithOlderStoredWatermarks() async throws {
        try await MainActor.run {
            let suite = "TetherNotifier.\(UUID())"
            let defaults = TestMemoryDefaults(domain: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            for key in ["lastNotifiedHoldEnd", "lastNotifiedThermalAlert", "lastNotifiedOverheatSleep", "lastNotifiedWeakChargerSleep"] {
                defaults.set(50, forKey: key)
            }
            var initial = legacySample(.thermal)
            initial.thermalAlertAt = 100; initial.overheatSleepAt = 100; initial.weakChargerSleepAt = 100
            var count = 0
            let notifier = Notifier(status: initial, defaults: defaults) { _, _ in count += 1 }
            notifier.check(status: initial, choices: .init(heat: true, battery: true))
            XCTAssertEqual(count, 0)
            var next = legacySample(.thermal, at: 101)
            next.overheatSleepAt = 101; next.thermalAlertAt = 101; next.weakChargerSleepAt = 100
            notifier.check(status: next, choices: .init(heat: true, battery: true))
            notifier.check(status: next, choices: .init(heat: true, battery: true))
            XCTAssertEqual(count, 1)
        }
    }
    func testLegacyReminderAndTimeExpiryStaySilentRegardlessOfOldPreference() async throws {
        try await MainActor.run {
            for oldChoice in [true, false] {
                let suite = "TetherNotifier.\(UUID())"
                let defaults = TestMemoryDefaults(domain: suite)
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(oldChoice, forKey: "notifyHoldEnd")
                var count = 0
                let notifier = legacyNotifier(defaults: defaults) { _, _ in count += 1 }
                let choices = Notifier.Choices(heat: true, battery: true)
                notifier.check(status: legacySample(nil), choices: choices)
                notifier.check(status: legacySample(.time), choices: choices)
                notifier.check(status: legacySample(.cancelled, at: 101), choices: choices)
                XCTAssertEqual(count, 0)
                XCTAssertEqual(defaults.object(forKey: "notifyHoldEnd") as? Bool, oldChoice)
            }
        }
    }
    func testLegacyProtectionRemainsIndependentAndDisabledEventsAreConsumed() async throws {
        try await MainActor.run {
            for reason in [HoldEnd.heat, .thermal, .sensor, .battery] {
                let suite = "TetherNotifier.\(UUID())"
                let defaults = TestMemoryDefaults(domain: suite)
                defer { defaults.removePersistentDomain(forName: suite) }
                var count = 0
                let notifier = legacyNotifier(defaults: defaults) { _, _ in count += 1 }
                let disabled = Notifier.Choices(heat: reason == .battery, battery: reason != .battery)
                notifier.check(status: legacySample(reason), choices: disabled)
                notifier.check(status: legacySample(reason), choices: .init(heat: true, battery: true))
                XCTAssertEqual(count, 0)
                notifier.check(status: legacySample(reason, at: 101), choices: .init(heat: true, battery: true))
                notifier.check(status: legacySample(reason, at: 101), choices: .init(heat: true, battery: true))
                XCTAssertEqual(count, 1)
            }
        }
    }
    func testLegacyProtectionDecisionDoesNotDuplicateTheHoldEndInTheSameObservation() async throws {
        try await MainActor.run {
            for reason in [HoldEnd.thermal, .battery] {
                let suite = "TetherNotifier.\(UUID())"
                let defaults = TestMemoryDefaults(domain: suite)
                defer { defaults.removePersistentDomain(forName: suite) }
                var count = 0
                let notifier = legacyNotifier(defaults: defaults) { _, _ in count += 1 }
                var status = legacySample(reason)
                if reason == .thermal { status.overheatSleepAt = 100; status.thermalAlertAt = 100 }
                else { status.weakChargerSleepAt = 100 }
                notifier.check(status: status, choices: .init(heat: true, battery: true))
                notifier.check(status: status, choices: .init(heat: true, battery: true))
                XCTAssertEqual(count, 1)
            }
        }
    }
    func testIndependentPreferencesConsumeDisabledEvents() async throws {
        try await MainActor.run {
            let suite = "TetherNotifier.\(UUID())"
            let defaults = TestMemoryDefaults(domain: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            var count = 0
            let notifier = Notifier(status: nil, defaults: defaults) { _, _ in count += 1 }
            var state = sample(manual: true)
            notifier.checkWork(state, choices: .init(heat: false, battery: false), now: 100)
            state.blockReason = "battery"; state.manualActive = false; state.automaticActive = false
            notifier.checkWork(state, choices: .init(heat: true, battery: false), now: 101)
            notifier.checkWork(state, choices: .init(heat: true, battery: true), now: 102)
            XCTAssertEqual(count, 0)
        }
    }
    func testExistingOffPreferencesArePreservedAndNotificationSettingsDoNotChangeWorkPolicy() async throws {
        try await MainActor.run {
            let suite = "TetherNotifier.\(UUID())"
            let defaults = TestMemoryDefaults(domain: suite), backend = NoPowerWrites()
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(false, forKey: "notifyHoldEnd"); defaults.set(false, forKey: "notifyHeat")
            defaults.set(false, forKey: "notifyBatteryProtection")
            let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
            let model = AppModel(preview: true, previewSession: controller, previewDefaults: defaults)
            let before = defaults.data(forKey: UserSessionController.preferenceKey), decision = controller.sessionDecision
            XCTAssertFalse(model.notifyHeat); XCTAssertFalse(model.notifyBatteryProtection)
            XCTAssertEqual(defaults.object(forKey: "notifyHoldEnd") as? Bool, false)
            model.notifyBatteryProtection = true
            XCTAssertTrue(defaults.bool(forKey: "notifyBatteryProtection"))
            XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), before)
            XCTAssertEqual(controller.sessionDecision, decision); XCTAssertEqual(backend.creates, 0)
            XCTAssertTrue(controller.end())
        }
    }
}
