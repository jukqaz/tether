import AppKit
import XCTest
@testable import Tether
import TetherCore

private final class UserAssertionFixture: IdleAssertionBackend {
    var creates = 0
    var renews = 0
    var releases = 0
    var releaseCode: Int32 = 0
    var levelValue: Int? = 255
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (0, 9) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { renews += 1; return 0 }
    func level(id: UInt32) -> Int? { levelValue }
    func release(id: UInt32) -> Int32 { releases += 1; return releaseCode }
}

final class UserSessionControllerTests: XCTestCase {
    func testACManualLeaseDoesNotPreapproveBatteryByDefault() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: base, batteryPercent: 80)
                XCTAssertTrue(subject.start(duration: nil, now: base + 1))
                let lease = try XCTUnwrap(subject.workLease(now: base + 1))
                XCTAssertEqual(lease.reasons, [.manual])
                XCTAssertNil(lease.powerTransition)
            }
        }
    }
    func testActiveACManualKeepsItsCapturedChoiceWhileNextDefaultChanges() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                XCTAssertTrue(subject.start(duration: nil, now: base))
                XCTAssertFalse(subject.setManualBatteryContinuationMinutes(15, now: base + 1))
                let selected = try XCTUnwrap(subject.workLease(now: base + 1))
                XCTAssertNil(selected.configuration.manualBatteryContinuationMinutes)
                XCTAssertNil(selected.powerTransition); XCTAssertNil(subject.settings.manualBatteryContinuationMinutes)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: base + 2, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.status.manualEndReason, .powerDisconnected)
                XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 1)
            }
        }
    }
    func testBatteryStartedManualIsConsumedBySecondUnplugAndNeedsNewExplicitStart() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                XCTAssertTrue(subject.start(duration: 3600, now: base))
                let id = subject.status.manualRequestID
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 1, batteryPercent: 80)
                let lease = try XCTUnwrap(subject.workLease(now: base + 1))
                XCTAssertEqual(lease.manualStartedOnBattery, true)
                XCTAssertNil(lease.powerTransition)
                var gate = WorkSessionLeaseGate()
                XCTAssertTrue(gate.accept(lease, now: base + 1, attaching: true))
                XCTAssertEqual(gate.reasons(now: base + 2, power: .battery), [])
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 2, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.status.manualEndReason, .powerDisconnected)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 3, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive)
                XCTAssertTrue(subject.start(duration: 600, now: base + 4))
                XCTAssertNotEqual(subject.status.manualRequestID, id)
            }
        }
    }
    func testDelayedHelperDisconnectReceiptConsumesACManualWithoutCreatingBatteryCarryover() async throws {
        try await MainActor.run {
            for delay in [20.0, 902] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    XCTAssertFalse(subject.setManualBatteryContinuationMinutes(15, now: base))
                    XCTAssertTrue(subject.start(duration: nil, now: base))
                    let lease = try XCTUnwrap(subject.workLease(now: base + 1))
                    XCTAssertNil(lease.powerTransition)
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.lidEndReceipt = WorkSessionEndReceipt(bootID: "fixture", sessionID: subject.sessionID, sequence: lease.sequence,
                        observedAt: base + 2, kind: .disconnect, action: .followOS)
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + delay, batteryPercent: 80)
                    subject.acceptBridge(bridge, protection: nil, now: base + delay)
                    XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                    XCTAssertNil(subject.status.manualContinuousDeadline); XCTAssertNil(subject.status.pendingBatteryMinutes)
                }
            }
        }
    }
    func testRemovedUnplugChoiceIsRejectedAndRestartDoesNotRestoreTemporarySession() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                XCTAssertFalse(subject.setManualBatteryContinuationMinutes(30, now: base))
                XCTAssertTrue(subject.start(duration: nil, now: base))
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 1, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive); XCTAssertTrue(subject.end())
                let restarted = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = restarted.end() }
                restarted.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 100, batteryPercent: 80)
                XCTAssertNil(restarted.status.manualBatteryContinuationMinutes)
                XCTAssertFalse(restarted.status.manualActive); XCTAssertFalse(restarted.status.holding)
                XCTAssertNil(restarted.status.until); XCTAssertEqual(restarted.status.manualBatteryRemaining, 7200, accuracy: 0.001)
            }
        }
    }

    func testBatteryTimerCannotBeExtendedWhileRootSleepConsumptionIsPending() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: base, batteryPercent: 80)
                XCTAssertTrue(subject.startBatteryHold(minutes: 3, now: base + 1))
                let old = try XCTUnwrap(subject.workLease(now: base + 1))
                var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                subject.acceptBridge(bridge, protection: nil, now: base + 1)
                XCTAssertFalse(subject.canExtendBatteryHold(minutes: 1, now: base + 1))
                let until = subject.status.batteryHoldUntil
                subject.observeSystemSleep(observedAt: base + 2)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: base + 3, batteryPercent: 80)
                XCTAssertFalse(subject.canExtendBatteryHold(minutes: 1, now: base + 3))
                subject.extendBatteryHold(minutes: 1, now: base + 3)
                XCTAssertEqual(subject.status.batteryHoldUntil, until); XCTAssertFalse(subject.status.holding)
                bridge.sleepConsumption = WorkSessionSleepConsumption(bootID: "fixture", sessionID: subject.sessionID,
                    sequence: old.sequence, observedAt: base + 2)
                subject.acceptBridge(bridge, protection: nil, now: base + 3)
                XCTAssertNil(subject.status.batteryHoldUntil); XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.status.batteryRemaining, 3600, accuracy: 1)
            }
        }
    }

    func testOldDuplicateReceiptCannotReviveTemporaryIntentFromASecondSleep() async throws {
        try await MainActor.run {
            for action in ["manual", "reservation", "battery"] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend,
                        guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    let power: PowerSource = action == "battery" ? .battery : .ac
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base, batteryPercent: 80)
                    XCTAssertTrue(subject.start(duration: 600, now: base + 1))
                    let old = try XCTUnwrap(subject.workLease(now: base + 1))
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.sleepConsumption = WorkSessionSleepConsumption(bootID: "fixture", sessionID: subject.sessionID,
                        sequence: old.sequence, observedAt: base + 2)
                    subject.acceptBridge(bridge, protection: nil, now: base + 3)
                    if action == "manual" { XCTAssertTrue(subject.start(duration: 180, now: base + 4)) }
                    else { XCTAssertTrue(subject.startBatteryHold(minutes: 3, now: base + 4)) }
                    // This is a genuinely new boundary, while the previous root
                    // reply/receipt is still in flight or the IOKit event is pending.
                    subject.observeSystemSleep(observedAt: base + 5)
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base + 6, batteryPercent: 80)
                    XCTAssertFalse(subject.status.holding)
                    subject.acceptBridge(bridge, protection: nil, now: base + 6)
                    XCTAssertFalse(subject.status.manualActive); XCTAssertNil(subject.status.pendingBatteryMinutes)
                    XCTAssertNil(subject.status.batteryHoldUntil); XCTAssertFalse(subject.status.holding)
                    XCTAssertEqual(subject.workLease(now: base + 6)?.reasons, [])
                    XCTAssertTrue(subject.status.enabled)
                }
            }
        }
    }

    func testDuplicateReceiptConsumesOnlyIntentBeforeThePendingWorkspaceCapture() async throws {
        try await MainActor.run {
            for action in ["manual", "reservation", "battery"] {
                try withFixture { defaults, backend in
                    var wallOffset = 0.0
                    let wallBase = Date()
                    let subject = UserSessionController(defaults: defaults, backend: backend,
                        guiProbe: nil, environmentProbe: nil, boot: "fixture",
                        wallClock: { wallBase.addingTimeInterval(wallOffset) })
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    let power: PowerSource = action == "battery" ? .battery : .ac
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base, batteryPercent: 80)
                    XCTAssertTrue(subject.start(duration: 600, now: base + 1))
                    let original = try XCTUnwrap(subject.workLease(now: base + 1))
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.sleepConsumption = WorkSessionSleepConsumption(bootID: "fixture", sessionID: subject.sessionID,
                        sequence: original.sequence, observedAt: base + 2)
                    wallOffset = 3; subject.acceptBridge(bridge, protection: nil, now: base + 3)
                    wallOffset = 4
                    if action == "manual" { XCTAssertTrue(subject.start(duration: 180, now: base + 4)) }
                    else { XCTAssertTrue(subject.startBatteryHold(minutes: 3, now: base + 4)) }
                    // A second event was captured at 5, but the user explicitly
                    // replaced the old job at 7 before the main callback arrived.
                    wallOffset = 7
                    if action == "manual" {
                        subject.endManual(); XCTAssertTrue(subject.start(duration: 180, now: base + 7))
                    } else {
                        subject.cancelBatteryHold(); XCTAssertTrue(subject.startBatteryHold(minutes: 3, now: base + 7))
                    }
                    let before = try XCTUnwrap(subject.workLease(now: base + 7))
                    let manualEnd = subject.status.until, batteryEnd = subject.status.batteryHoldUntil
                    subject.observeSystemSleep(observedAt: base + 5)
                    wallOffset = 8
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base + 8, batteryPercent: 80)
                    subject.acceptBridge(bridge, protection: nil, now: base + 8)
                    let after = try XCTUnwrap(subject.workLease(now: base + 8))
                    XCTAssertEqual(after.continuationToken, before.continuationToken)
                    XCTAssertTrue(subject.status.manualActive)
                    XCTAssertNil(subject.status.pendingBatteryMinutes)
                    XCTAssertTrue(subject.status.holding)
                    XCTAssertEqual(subject.status.until, manualEnd); XCTAssertEqual(subject.status.batteryHoldUntil, batteryEnd)
                    if action == "manual" {
                        XCTAssertEqual(subject.status.manualStartedAt, base + 7)
                        XCTAssertEqual(subject.status.manualContinuousDeadline, base + 187)
                    }
                    if action == "battery" {
                        XCTAssertEqual(subject.status.manualContinuousDeadline, base + 187)
                    }
                }
            }
        }
    }

    func testConfirmedRootCoordinationEndConsumesPendingSleepAndPermitsNativeManual() async {
        await MainActor.run {
            for power in [PowerSource.ac, .battery] {
                withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend,
                        guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base, batteryPercent: 80)
                    XCTAssertTrue(subject.start(duration: 600, now: base + 1))
                    subject.acceptBridge(WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil),
                        protection: nil, now: base + 1)
                    subject.observeSystemSleep(observedAt: base + 2)
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base + 3, batteryPercent: 80)
                    XCTAssertFalse(subject.status.holding); XCTAssertFalse(subject.status.canStart)
                    XCTAssertFalse(subject.start(duration: 180, now: base + 3))
                    // Only AppModel's confirmed detach/removal calls this seam.
                    subject.endRootCoordination(now: base + 3)
                    XCTAssertFalse(subject.status.manualActive); XCTAssertTrue(subject.status.canStart)
                    if power == .battery { XCTAssertEqual(subject.status.manualBatteryRemaining, 7200, accuracy: 1) }
                    XCTAssertTrue(subject.start(duration: 180, now: base + 4))
                    let start = subject.status.manualStartedAt
                    XCTAssertTrue(subject.status.holding); XCTAssertEqual(start, base + 4)
                    // Future Workspace sleep now consumes natively and never
                    // waits for the helper that was positively detached.
                    subject.observeSystemSleep(observedAt: base + 5)
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base + 6, batteryPercent: 80)
                    XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                    XCTAssertTrue(subject.start(duration: 180, now: base + 7))
                    if power == .battery { XCTAssertEqual(subject.status.manualBatteryRemaining, 7200, accuracy: 1) }
                }
            }
        }
    }

    func testConfirmedRootCoordinationEndPreservesSavedChoicesProtectionAndConsumedBudgets() async throws {
        try await MainActor.run {
            for reason in ["off", "thermal", "stop", "legacyBudget"] {
                try withFixture { defaults, backend in
                    var settings = IdleSessionSettings(); settings.automaticEnabled = true
                    settings.legacyRootConfigurationPending = false
                    defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
                    let subject = UserSessionController(defaults: defaults, backend: backend,
                        guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    if reason == "off" { XCTAssertTrue(subject.setEnabled(false)) }
                    var oldBudget = ProtectionState()
                    oldBudget.prepareBatteryBudget(power: .battery, needed: true, clock: base - 14400, boot: "fixture")
                    let bridge = WorkSessionBridge(coordinated: true, automaticBudget: oldBudget,
                        manualBudget: oldBudget, stopRequested: reason == "stop")
                    let protection = reason == "thermal" ? ProtectionStatus(reason: "thermal", error: nil, dryRun: true) : nil
                    subject.endRootCoordination(confirmedBridge: bridge, protection: protection, now: base + 1)
                    if reason == "legacyBudget" { XCTAssertTrue(subject.status.holding) }
                    else { XCTAssertFalse(subject.status.holding) }
                    if reason == "thermal" { XCTAssertEqual(subject.runtimeMarkers.protectionReason, "thermal") }
                    if reason == "off" || reason == "stop" { XCTAssertEqual(subject.runtimeMarkers.pauseReason, .userStop) }
                    let saved = try JSONDecoder().decode(IdleSessionSettings.self,
                        from: XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey)))
                    XCTAssertNil(saved.manualBatteryBudget); XCTAssertNil(saved.automaticBatteryBudget)
                    XCTAssertTrue(saved.automaticEnabled)
                }
            }
        }
    }

    func testConfirmedCoordinationEndUsesRootReceiptWithoutResettingNewIntent() async throws {
        try await MainActor.run {
            for action in ["manual", "reservation", "battery"] {
                try withFixture { defaults, backend in
                    var wallOffset = 0.0
                    let wallBase = Date()
                    let subject = UserSessionController(defaults: defaults, backend: backend,
                        guiProbe: nil, environmentProbe: nil, boot: "fixture",
                        wallClock: { wallBase.addingTimeInterval(wallOffset) })
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    let power: PowerSource = action == "battery" ? .battery : .ac
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base, batteryPercent: 80)
                    XCTAssertTrue(subject.start(duration: 600, now: base + 1))
                    let old = try XCTUnwrap(subject.workLease(now: base + 1))
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.sleepConsumption = WorkSessionSleepConsumption(bootID: "fixture", sessionID: subject.sessionID,
                        sequence: old.sequence, observedAt: base + 2)
                    wallOffset = 3; subject.acceptBridge(bridge, protection: nil, now: base + 3)
                    wallOffset = 4
                    if action == "manual" { XCTAssertTrue(subject.start(duration: 180, now: base + 4)) }
                    else { XCTAssertTrue(subject.startBatteryHold(minutes: 3, now: base + 4)) }
                    let current = try XCTUnwrap(subject.workLease(now: base + 4))
                    let manualEnd = subject.status.until, batteryEnd = subject.status.batteryHoldUntil
                    subject.observeSystemSleep(observedAt: base + 2)
                    wallOffset = 6
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base + 6, batteryPercent: 80)
                    XCTAssertFalse(subject.status.holding)
                    subject.endRootCoordination(confirmedBridge: bridge, now: base + 6)
                    let native = try XCTUnwrap(subject.workLease(now: base + 6))
                    XCTAssertEqual(native.continuationToken, current.continuationToken)
                    XCTAssertTrue(subject.status.manualActive)
                    XCTAssertNil(subject.status.pendingBatteryMinutes)
                    XCTAssertTrue(subject.status.holding)
                    XCTAssertEqual(subject.status.until, manualEnd); XCTAssertEqual(subject.status.batteryHoldUntil, batteryEnd)
                    if action == "manual" { XCTAssertEqual(subject.status.manualContinuousDeadline, base + 184) }
                    if action == "battery" {
                        XCTAssertEqual(subject.status.manualContinuousDeadline, base + 184)
                    }
                }
            }
        }
    }

    func testIncompatibleOrForeignBridgeDoesNotEndRootSleepConsumptionWait() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                XCTAssertTrue(subject.start(duration: 600, now: base + 1))
                let old = try XCTUnwrap(subject.workLease(now: base + 1))
                var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                subject.acceptBridge(bridge, protection: nil, now: base + 1)
                subject.observeSystemSleep(observedAt: base + 2)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 3)
                bridge.version = 99; bridge.coordinated = false
                subject.acceptBridge(bridge, protection: nil, now: base + 3)
                XCTAssertTrue(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                XCTAssertFalse(subject.start(duration: 60, now: base + 3))
                bridge.version = 1
                bridge.sleepConsumption = WorkSessionSleepConsumption(bootID: "fixture", sessionID: UUID(),
                    sequence: old.sequence, observedAt: base + 2)
                subject.acceptBridge(bridge, protection: nil, now: base + 3)
                XCTAssertFalse(subject.status.canStart); XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.workLease(now: base + 3)?.reasons, [])
                // A positive detach acknowledgement, not the incompatible poll,
                // releases this wait and consumes its remaining old temporary work.
                subject.endRootCoordination(now: base + 3)
                XCTAssertFalse(subject.status.manualActive); XCTAssertTrue(subject.start(duration: 60, now: base + 4))
            }
        }
    }

    func testRootSleepReceiptConsumesOldTemporaryWorkBeforeAQuickWakeLease() async throws {
        try await MainActor.run {
            for (power, automatic) in [(PowerSource.ac, false), (.ac, true), (.battery, true)] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend,
                        guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    selectAdvancedPowerFixture(subject)
                    let base = ContinuousTime.now
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base, batteryPercent: 80)
                    subject.setPowerCondition(.any); subject.setAutomatic(automatic)
                    XCTAssertTrue(subject.start(duration: 600, now: base + 1))
                    let original = try XCTUnwrap(subject.workLease(now: base + 1))
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    subject.acceptBridge(bridge, protection: nil, now: base + 1)
                    // The helper has slept; the GUI has not received its Workspace
                    // notification and still evaluates the old manual policy.
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base + 3, batteryPercent: 80)
                    XCTAssertTrue(try XCTUnwrap(subject.workLease(now: base + 3)).reasons.contains(.manual))
                    let consumption = WorkSessionSleepConsumption(bootID: "fixture", sessionID: subject.sessionID,
                        sequence: original.sequence, observedAt: base + 2, continuationToken: original.continuationToken)
                    bridge.sleepConsumption = consumption
                    subject.acceptBridge(bridge, protection: nil, now: base + 3)
                    let fresh = try XCTUnwrap(subject.workLease(now: base + 3))
                    XCTAssertEqual(fresh.sleepConsumptionID, consumption.id)
                    XCTAssertFalse(subject.status.manualActive)
                    if automatic && power == .battery { XCTAssertNotNil(subject.status.batteryHoldUntil) }
                    else { XCTAssertNil(subject.status.batteryHoldUntil) }
                    XCTAssertNil(subject.status.pendingBatteryMinutes); XCTAssertFalse(fresh.reasons.contains(.manual))
                    XCTAssertEqual(fresh.reasons, automatic ? [.automatic] : [])
                    XCTAssertEqual(subject.status.enabled, true)
                    if power == .battery {
                        XCTAssertEqual(subject.status.manualBatteryRemaining, 7200, accuracy: 1)
                        XCTAssertEqual(subject.status.batteryRemaining, 7197, accuracy: 1,
                            "A fresh ordinary Wake uses the explicitly selected power range and the original first battery cap")
                        XCTAssertTrue(subject.status.automaticActive)
                        XCTAssertTrue(subject.status.holding)
                    }
                }
            }
        }
    }

    func testLateWorkspaceDeliveryAndRepeatedReceiptRestoreNewManualAndBatteryIntent() async throws {
        try await MainActor.run {
            for action in ["manual", "reservation", "battery"] {
                try withFixture { defaults, backend in
                    var wallOffset = 0.0
                    let wallBase = Date()
                    let subject = UserSessionController(defaults: defaults, backend: backend,
                        guiProbe: nil, environmentProbe: nil, boot: "fixture",
                        wallClock: { wallBase.addingTimeInterval(wallOffset) })
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    let power: PowerSource = action == "battery" ? .battery : .ac
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base, batteryPercent: 80)
                    XCTAssertTrue(subject.start(duration: 600, now: base + 1))
                    let original = try XCTUnwrap(subject.workLease(now: base + 1))
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.sleepConsumption = WorkSessionSleepConsumption(bootID: "fixture", sessionID: subject.sessionID,
                        sequence: original.sequence, observedAt: base + 2)
                    wallOffset = 3
                    subject.acceptBridge(bridge, protection: nil, now: base + 3)
                    wallOffset = 4
                    if action == "manual" { XCTAssertTrue(subject.start(duration: 300, now: base + 4)) }
                    else { XCTAssertTrue(subject.startBatteryHold(minutes: 3, now: base + 4)) }
                    let fresh = try XCTUnwrap(subject.workLease(now: base + 4))
                    let originalUntil = subject.status.until
                    // Delivery at 5 retains the time captured at 2 before the
                    // main-queue hop, preserving the explicit post-boundary start.
                    subject.observeSystemSleep(observedAt: base + 2)
                    wallOffset = 6
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base + 6, batteryPercent: 80)
                    XCTAssertFalse(subject.status.holding, "Native work waits for the root observation")
                    subject.acceptBridge(bridge, protection: nil, now: base + 6)
                    let restored = try XCTUnwrap(subject.workLease(now: base + 6))
                    XCTAssertEqual(restored.sleepConsumptionID, fresh.sleepConsumptionID)
                    XCTAssertEqual(restored.continuationToken, fresh.continuationToken)
                    if action == "manual" {
                        XCTAssertTrue(subject.status.manualActive); XCTAssertTrue(subject.status.holding)
                        XCTAssertEqual(subject.status.manualStartedAt, base + 4)
                        XCTAssertEqual(subject.status.manualContinuousDeadline, base + 304)
                        XCTAssertEqual(try XCTUnwrap(subject.status.until).timeIntervalSince(try XCTUnwrap(originalUntil)), 0, accuracy: 0.001)
                    } else if action == "reservation" {
                        XCTAssertNil(subject.status.pendingBatteryMinutes); XCTAssertTrue(subject.status.holding)
                        XCTAssertTrue(subject.status.manualActive)
                        XCTAssertEqual(subject.status.manualStartedAt, base + 4)
                        XCTAssertEqual(subject.status.manualContinuousDeadline, base + 184)
                        XCTAssertEqual(try XCTUnwrap(subject.status.until).timeIntervalSince(try XCTUnwrap(originalUntil)), 0, accuracy: 0.001)
                    } else {
                        XCTAssertTrue(subject.status.holding); XCTAssertNil(subject.status.pendingBatteryMinutes)
                        XCTAssertEqual(try XCTUnwrap(subject.status.until).timeIntervalSince(try XCTUnwrap(originalUntil)), 0, accuracy: 0.001)
                        XCTAssertEqual(subject.status.manualContinuousDeadline, base + 184)
                    }
                }
            }
        }
    }

    func testDelayedRootReceiptPreservesOnlyExplicitIntentStartedAfterItsBoundary() async throws {
        try await MainActor.run {
            for action in ["manual", "reservation", "battery"] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend,
                        guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    let power: PowerSource = action == "battery" ? .battery : .ac
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base, batteryPercent: 80)
                    XCTAssertTrue(subject.start(duration: 600, now: base + 1))
                    let original = try XCTUnwrap(subject.workLease(now: base + 1))
                    subject.endManual()
                    if action == "manual" { XCTAssertTrue(subject.start(duration: 300, now: base + 4)) }
                    else { XCTAssertTrue(subject.startBatteryHold(minutes: 3, now: base + 4)) }
                    let newer = try XCTUnwrap(subject.workLease(now: base + 4))
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.sleepConsumption = WorkSessionSleepConsumption(bootID: "fixture", sessionID: subject.sessionID,
                        sequence: original.sequence, observedAt: base + 2, continuationToken: original.continuationToken)
                    subject.acceptBridge(bridge, protection: nil, now: base + 5)
                    let accepted = try XCTUnwrap(subject.workLease(now: base + 5))
                    XCTAssertEqual(accepted.sleepConsumptionID, bridge.sleepConsumption?.id)
                    XCTAssertEqual(accepted.continuationToken, newer.continuationToken)
                    XCTAssertTrue(subject.status.manualActive)
                    XCTAssertNil(subject.status.pendingBatteryMinutes)
                    XCTAssertTrue(subject.status.holding)
                }
            }
        }
    }

    func testForeignFutureAndOldSleepReceiptsCannotConsumeOrReplaceAnAcknowledgement() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                XCTAssertTrue(subject.start(duration: 600, now: base + 1))
                let original = try XCTUnwrap(subject.workLease(now: base + 1))
                let valid = WorkSessionSleepConsumption(bootID: "fixture", sessionID: subject.sessionID,
                    sequence: original.sequence, observedAt: base + 2)
                var invalid: [WorkSessionSleepConsumption] = []
                var value = valid; value.sessionID = UUID(); invalid.append(value)
                value = valid; value.sequence = .max; invalid.append(value)
                value = valid; value.observedAt = base + 100; invalid.append(value)
                value = valid; value.observedAt = .nan; invalid.append(value)
                value = valid; value.bootID = "other-boot"; invalid.append(value)
                value = valid; value.version = 2; invalid.append(value)
                for receipt in invalid {
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.sleepConsumption = receipt
                    subject.acceptBridge(bridge, protection: nil, now: base + 3)
                    XCTAssertTrue(subject.status.manualActive)
                    XCTAssertNil(subject.workLease(now: base + 3)?.sleepConsumptionID)
                }
                var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                bridge.sleepConsumption = valid
                subject.acceptBridge(bridge, protection: nil, now: base + 3)
                XCTAssertTrue(subject.start(duration: 300, now: base + 4))
                let newer = try XCTUnwrap(subject.workLease(now: base + 4))
                let second = WorkSessionSleepConsumption(bootID: "fixture", sessionID: subject.sessionID,
                    sequence: newer.sequence, observedAt: base + 5)
                bridge.sleepConsumption = second
                subject.acceptBridge(bridge, protection: nil, now: base + 6)
                XCTAssertFalse(subject.status.manualActive)
                bridge.sleepConsumption = valid
                subject.acceptBridge(bridge, protection: nil, now: base + 7)
                XCTAssertEqual(subject.workLease(now: base + 7)?.sleepConsumptionID, second.id)
            }
        }
    }

    func testSleepReceiptConsumesEachOldTemporaryReasonIndependentlyOfNewUserIntent() async throws {
        try await MainActor.run {
            for newer in ["manual", "batteryCarry"] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend,
                        guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    XCTAssertTrue(subject.start(duration: 600, now: base + 1))
                    let original = try XCTUnwrap(subject.workLease(now: base + 1))
                    subject.endManual()
                    if newer == "manual" { XCTAssertTrue(subject.start(duration: 300, now: base + 4)) }
                    else { XCTAssertTrue(subject.startBatteryHold(minutes: 3, now: base + 4)) }
                    let before = try XCTUnwrap(subject.workLease(now: base + 4))
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.sleepConsumption = WorkSessionSleepConsumption(bootID: "fixture", sessionID: subject.sessionID,
                        sequence: original.sequence, observedAt: base + 2)
                    subject.acceptBridge(bridge, protection: nil, now: base + 5)
                    let after = try XCTUnwrap(subject.workLease(now: base + 5))
                    XCTAssertTrue(subject.status.manualActive); XCTAssertTrue(subject.status.holding)
                    XCTAssertEqual(after.continuationToken, before.continuationToken)
                    if newer == "manual" { XCTAssertEqual(after.manualDeadline, base + 304) }
                    else { XCTAssertNil(subject.status.pendingBatteryMinutes) }
                }
            }
        }
    }

    func testWorkspaceCaptureTimeDoesNotConsumeANewerStandaloneManualStart() async {
        await MainActor.run {
            withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                XCTAssertTrue(subject.start(duration: 600, now: base + 1))
                subject.endManual(); XCTAssertTrue(subject.start(duration: 300, now: base + 4))
                subject.observeSystemSleep(observedAt: base + 2)
                XCTAssertTrue(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 5)
                XCTAssertTrue(subject.status.holding)
                XCTAssertEqual(subject.status.manualStartedAt, base + 4)
            }
        }
    }

    func testUnobservedWorkCannotAttachOrRetainCanceledReasons() async throws {
        try await MainActor.run {
            for action in ["stop", "off", "condition", "duration", "manualEnd", "thermal", "gui", "power"] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend,
                        guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                        now: ContinuousTime.now, batteryPercent: 80)
                    selectAdvancedPowerFixture(subject)
                    subject.setAutomatic(true)
                    if action == "manualEnd" { XCTAssertTrue(subject.start(duration: 600)) }
                    let original = try XCTUnwrap(subject.workLease())
                    var gate = WorkSessionLeaseGate()
                    XCTAssertTrue(gate.accept(original, now: ContinuousTime.now, attaching: true))
                    backend.levelValue = nil
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                        now: ContinuousTime.now, batteryPercent: 80)
                    XCTAssertNil(subject.workLease(), action)
                    switch action {
                    case "stop": subject.stopCurrent()
                    case "off": subject.setEnabled(false)
                    case "condition": subject.setPowerCondition(.battery)
                    case "duration": subject.setAutomaticMinutes(2)
                    case "manualEnd": subject.endManual()
                    default:
                        subject.update(power: action == "power" ? .battery : .ac,
                            thermal: action == "thermal" ? 2 : 0, fullWake: true,
                            controllingUser: action != "gui", now: ContinuousTime.now, batteryPercent: 80)
                    }
                    let ended = try XCTUnwrap(subject.workLease(), action)
                    if action == "condition" {
                        XCTAssertEqual(subject.status.powerCondition, .battery)
                        XCTAssertTrue(subject.status.automaticEnabled)
                        XCTAssertTrue(subject.status.automaticActive,
                            "The existing activation retains its captured AC range, but unverified native evidence cannot issue another grant")
                        XCTAssertNil(ended.lidPermit, "A changed condition publishes release, never a new positive grant")
                        XCTAssertEqual(gate.current?.expiry, original.expiry)
                    }
                    XCTAssertTrue(ended.reasons.isEmpty, action); XCTAssertNil(ended.expiry, action)
                    XCTAssertTrue(gate.accept(ended, now: ContinuousTime.now), action)
                    XCTAssertTrue(gate.reasons(now: ContinuousTime.now, power: ended.power).isEmpty, action)
                }
            }
        }
    }

    func testInitiallyUnconfirmedWorkDoesNotGrantLidOwnershipAndRecoveryIsFinite() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                backend.levelValue = nil
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                subject.setAutomatic(true)
                let initial = try XCTUnwrap(subject.workLease())
                XCTAssertTrue(initial.reasons.isEmpty); XCTAssertNil(initial.expiry)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                XCTAssertTrue(try XCTUnwrap(subject.workLease()).reasons.isEmpty)
                XCTAssertEqual(backend.renews, 0)
                backend.levelValue = 255
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                let confirmed = try XCTUnwrap(subject.workLease())
                XCTAssertEqual(confirmed.reasons, [.automatic])
                let now = ContinuousTime.now
                XCTAssertGreaterThan(try XCTUnwrap(confirmed.expiry), now)
                XCTAssertLessThanOrEqual(try XCTUnwrap(confirmed.expiry), now + min(IdleSessionPolicy.healthTTL, IdleSessionPolicy.observationTTL))
                XCTAssertEqual(backend.creates, 1)
            }
        }
    }

    func testSystemSleepDoesNotTurnPowerTriggerIntoAnExplicitStop() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let login = GUISessionIdentity(uid: getuid(), sessionID: 100001)
                var environment = UserSessionEnvironment(power: .ac, thermal: 0, fullWake: true, batteryPercent: 80)
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: { GUISessionObservation(login: login, consoleUID: login.uid) },
                    environmentProbe: { environment }, boot: "fixture")
                defer { _ = subject.end() }
                subject.startObserving(); subject.setAutomatic(true)
                XCTAssertTrue(subject.status.holding)
                environment.power = .battery; subject.refresh()
                XCTAssertFalse(subject.status.holding)
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
                environment.power = .ac
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                XCTAssertTrue(subject.status.automaticActive)
                XCTAssertTrue(subject.status.holding)
                let settings = try JSONDecoder().decode(IdleSessionSettings.self,
                    from: XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey)))
                XCTAssertFalse(settings.automaticSuppressed)
            }
        }
    }

    func testAssertionObservationGapDoesNotSendAnEndOrRenewExistingLidWork() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let now = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now)
                subject.setAutomatic(true)
                let issued = ContinuousTime.now
                let original = try XCTUnwrap(subject.workLease(now: issued))
                var gate = WorkSessionLeaseGate()
                XCTAssertTrue(gate.accept(original, now: issued, attaching: true))
                backend.levelValue = nil
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: issued + 3)
                XCTAssertTrue(subject.status.automaticActive)
                XCTAssertFalse(subject.status.holding)
                XCTAssertNotNil(subject.status.error)
                XCTAssertNil(subject.workLease(now: issued + 3), "No replacement means preserve the helper's original finite grant")
                let renews = backend.renews
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: issued + 6)
                XCTAssertEqual(backend.renews, renews, "An unavailable observation cannot extend the native timeout")
                XCTAssertNil(subject.workLease(now: issued + 6))
                XCTAssertEqual(gate.current?.expiry, original.expiry)
                XCTAssertEqual(gate.reasons(now: issued + 6, power: .ac), [.automatic])
                XCTAssertEqual(gate.reasons(now: try XCTUnwrap(original.expiry), power: .ac), [])
            }
        }
    }

    func testDirectManualPermitSurvivesAutomaticEditsAndCannotReturnAfterExpiry() async throws {
        try await MainActor.run {
            for action in ["automaticOff", "condition"] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    selectAdvancedPowerFixture(subject)
                    let base = ContinuousTime.now
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    subject.setAllowClosedLid(true); subject.setAutomatic(true)
                    XCTAssertTrue(subject.startBatteryHold(minutes: 3, now: base))
                    let original = try XCTUnwrap(subject.workLease(now: base))
                    let bridge = try batteryBridge(for: original, boot: "fixture", at: base + 1)
                    if action == "automaticOff" { subject.setAutomatic(false) } else { subject.setPowerCondition(.battery) }
                    let edited = try XCTUnwrap(subject.workLease(now: base))
                    XCTAssertTrue(edited.reasons.contains(.manual))
                    XCTAssertEqual(edited.lidPermit?.batteryPermitID, original.lidPermit?.batteryPermitID)
                    subject.acceptBridge(bridge, protection: nil, now: base + 3)
                    XCTAssertEqual(subject.status.manualContinuousDeadline, base + 180)
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 180, batteryPercent: 80)
                    subject.acceptBridge(bridge, protection: nil, now: base + 181)
                    XCTAssertFalse(subject.status.manualActive)
                    XCTAssertEqual(subject.status.holding, action == "condition")
                    XCTAssertNil(subject.status.manualContinuousDeadline)
                    let afterExpiry = subject.workLease(now: base + 181)
                    if action == "condition" {
                        XCTAssertEqual(afterExpiry?.reasons, [.automatic])
                        XCTAssertNotEqual(afterExpiry?.lidPermit?.batteryPermitID, original.manualRequestID)
                    } else { XCTAssertNil(afterExpiry?.lidPermit) }
                }
            }
        }
    }

    func testIndependentAutomaticEditKeepsLiveManualAndItsEarlierBatteryReceipt() async throws {
        try await MainActor.run {
            for action in ["automaticOff", "condition"] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    selectAdvancedPowerFixture(subject)
                    let base = ContinuousTime.now
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    subject.setAllowClosedLid(true); subject.setAutomatic(true)
                    XCTAssertTrue(subject.startBatteryHold(minutes: 3, now: base))
                    let original = try XCTUnwrap(subject.workLease(now: base))
                    let bridge = try batteryBridge(for: original, boot: "fixture", at: base + 1)
                    if action == "automaticOff" { subject.setAutomatic(false) } else { subject.setPowerCondition(.battery) }
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 20, batteryPercent: 80)
                    subject.acceptBridge(bridge, protection: nil, now: base + 20)
                    XCTAssertTrue(subject.status.manualActive); XCTAssertTrue(subject.status.holding)
                    XCTAssertNil(subject.status.pendingBatteryMinutes); XCTAssertEqual(subject.status.manualContinuousDeadline, base + 180)
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 180, batteryPercent: 80)
                    XCTAssertFalse(subject.status.manualActive)
                    XCTAssertEqual(subject.status.holding, action == "condition")
                }
            }
        }
    }

    func testUnissuedBatteryReceiptCannotChangeManualAcrossIndependentChoiceEdits() async throws {
        try await MainActor.run {
            for action in ["automaticMinutes", "automaticOff", "condition", "manualDefault", "timeSelection", "manualExtend", "limits"] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    subject.setAllowClosedLid(true); subject.setAutomatic(true)
                    XCTAssertTrue(subject.start(duration: 600, now: base))
                    let original = try XCTUnwrap(subject.workLease(now: base))
                    XCTAssertNil(original.lidPermit?.batteryPermitID)
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.batteryPermitReceipt = WorkSessionBatteryPermitReceipt(bootID: "fixture", sessionID: subject.sessionID,
                        permitID: original.manualRequestID ?? UUID(), observedAt: base + 1, deadline: base + 181)
                    switch action {
                    case "automaticMinutes": subject.setAutomaticMinutes(120)
                    case "automaticOff": subject.setAutomatic(false)
                    case "condition": subject.setPowerCondition(.battery)
                    case "manualDefault": XCTAssertFalse(subject.setManualBatteryContinuationMinutes(120, now: base))
                    case "timeSelection": XCTAssertTrue(subject.selectManualDuration(7200))
                    case "manualExtend": XCTAssertFalse(subject.extend(duration: 60, now: base))
                    default: subject.setLimits(UserLimits(batteryFloor: 30, maxHoldHours: 3))
                    }
                    subject.acceptBridge(bridge, protection: nil, now: base + 3)
                    XCTAssertEqual(subject.status.manualContinuousDeadline, base + 600, action)
                    XCTAssertNil(subject.status.manualBatteryContinuationMinutes, action)
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 4, batteryPercent: 80)
                    XCTAssertFalse(subject.status.manualActive, action)
                    subject.setAutomatic(false)
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 5, batteryPercent: 80)
                }
            }
        }
    }

    func testBatteryReceiptDuringDarkWakeCannotAuthorizeCarryoverOrAcquireWork() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                XCTAssertTrue(subject.start(duration: 600, now: base))
                let requestID = try XCTUnwrap(subject.status.manualRequestID)
                var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                bridge.batteryPermitReceipt = WorkSessionBatteryPermitReceipt(bootID: "fixture", sessionID: subject.sessionID,
                    permitID: requestID, observedAt: base + 1, deadline: base + 181)
                subject.update(power: .ac, thermal: 0, fullWake: false, controllingUser: true, now: base + 2, batteryPercent: 80)
                let creates = backend.creates, renews = backend.renews
                subject.acceptBridge(bridge, protection: nil, now: base + 3)
                XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(backend.creates, creates); XCTAssertEqual(backend.renews, renews)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 4, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                XCTAssertNil(subject.status.manualContinuousDeadline)
            }
        }
    }

    func testLateBatteryReceiptCannotRestoreCancelledStoppedOrReplacedManual() async throws {
        try await MainActor.run {
            for action in ["cancel", "off", "stop", "end", "replace", "thermal", "gui"] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    subject.setAllowClosedLid(true); XCTAssertTrue(subject.startBatteryHold(minutes: 3, now: base))
                    let original = try XCTUnwrap(subject.workLease(now: base))
                    let bridge = try batteryBridge(for: original, boot: "fixture", at: base + 1)
                    switch action {
                    case "cancel": subject.cancelBatteryHold()
                    case "off": XCTAssertTrue(subject.setEnabled(false))
                    case "stop": subject.stopCurrent()
                    case "end": XCTAssertTrue(subject.end())
                    case "replace": subject.cancelBatteryHold(); XCTAssertTrue(subject.startBatteryHold(minutes: 5, now: base + 2))
                    default: break
                    }
                    subject.update(power: .battery, thermal: action == "thermal" ? 2 : 0, fullWake: true,
                        controllingUser: action != "gui", now: base + 3, batteryPercent: 80)
                    subject.acceptBridge(bridge, protection: nil, now: base + 3)
                    XCTAssertEqual(subject.status.manualActive, action == "replace")
                    XCTAssertNil(subject.status.pendingBatteryMinutes)
                    if action == "replace" {
                        XCTAssertEqual(subject.status.manualContinuousDeadline, base + 302)
                        XCTAssertNotEqual(subject.workLease(now: base + 3)?.lidPermit?.batteryPermitID, original.lidPermit?.batteryPermitID)
                        subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 4, batteryPercent: 80)
                        subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 5, batteryPercent: 80)
                        XCTAssertFalse(subject.status.manualActive); XCTAssertNil(subject.status.manualContinuousDeadline)
                    } else { XCTAssertNil(subject.status.manualContinuousDeadline) }
                }
            }
        }
    }

    func testPowerObserverIsRemovedWhenControllerIsDroppedWithoutExplicitEnd() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let login = GUISessionIdentity(uid: getuid(), sessionID: 100001)
                var subject: UserSessionController? = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: { GUISessionObservation(login: login, consoleUID: login.uid) },
                    environmentProbe: { UserSessionEnvironment(power: .ac, thermal: 0, fullWake: true, batteryPercent: 80) },
                    boot: "fixture")
                subject?.startObserving()
                guard let source = subject?.powerSourceObserver else {
                    _ = subject?.end()
                    throw XCTSkip("Native IOPS notification source unavailable in this test environment; lifecycle not verified.")
                }
                XCTAssertTrue(CFRunLoopSourceIsValid(source))
                XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))
                weak let previous = subject
                subject = nil
                XCTAssertNil(previous)
                XCTAssertFalse(CFRunLoopSourceIsValid(source))
                XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))
                XCTAssertEqual(backend.creates, 0)
            }
        }
    }
    func testHelperDisconnectReceiptConsumesManualEvenWhenAppOnlyObservesReturnedAC() async throws {
        try await MainActor.run {
            for delay in [20.0, 200, 300] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    subject.setAllowClosedLid(true); subject.setAutomatic(true)
                    XCTAssertTrue(subject.start(duration: 180, now: base))
                    let lease = try XCTUnwrap(subject.workLease(now: base))
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.lidEndReceipt = WorkSessionEndReceipt(bootID: "fixture", sessionID: subject.sessionID,
                        sequence: lease.sequence, observedAt: base + 1, kind: .disconnect, action: .followOS)
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + delay, batteryPercent: 80)
                    subject.acceptBridge(bridge, protection: nil, now: base + delay)
                    XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.automaticActive)
                    XCTAssertFalse(subject.status.holding); XCTAssertNil(subject.status.pendingBatteryMinutes)
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + delay + 1, batteryPercent: 80)
                    XCTAssertFalse(subject.status.holding); XCTAssertFalse(subject.status.manualActive)
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + delay + 2, batteryPercent: 80)
                    XCTAssertTrue(subject.status.automaticActive, "Only a newly confirmed AC edge can start a new activation")
                }
            }
        }
    }
    private func batteryBridge(for lease: WorkSessionLease, boot: String, at now: Double) throws -> WorkSessionBridge {
        let permit = try XCTUnwrap(lease.lidPermit)
        var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
        bridge.batteryPermitReceipt = WorkSessionBatteryPermitReceipt(bootID: boot, sessionID: lease.sessionID,
            permitID: try XCTUnwrap(permit.batteryPermitID), observedAt: now,
            deadline: now + (try XCTUnwrap(permit.batteryDuration)))
        return bridge
    }
    private func observedBridge(for lease: WorkSessionLease, boot: String, at now: Double) throws -> WorkSessionBridge {
        let decision = try XCTUnwrap(lease.powerTransition)
        var automatic = ProtectionState(); automatic.restart(boot: boot)
        if let start = decision.automaticBudgetStart {
            automatic.prepareBatteryBudget(power: .battery, needed: true, clock: start, boot: boot)
        }
        var manual: ProtectionState?
        if let start = decision.manualBudgetStart {
            var budget = ProtectionState(); budget.restart(boot: boot)
            budget.prepareBatteryBudget(power: .battery, needed: true, clock: start, boot: boot)
            manual = budget
        }
        var bridge = WorkSessionBridge(coordinated: true, automaticBudget: automatic, manualBudget: manual)
        bridge.powerTransition = WorkSessionPowerTransitionReceipt(sessionID: lease.sessionID, sequence: lease.sequence,
            observedAt: now, decision: decision)
        return bridge
    }
    func testOneACManualNeverPreapprovesOppositePowerAndDetachConsumesItsDeadline() async throws {
        try await MainActor.run {
            for duration in [600.0, 7200.0] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    subject.setAllowClosedLid(true)
                    XCTAssertTrue(subject.start(duration: duration, now: base))
                    let original = try XCTUnwrap(subject.workLease(now: base))
                    XCTAssertFalse(subject.startBatteryHold(minutes: 3, now: base))
                    XCTAssertNil(original.powerTransition); XCTAssertEqual(original.lidPermit?.powerScopes, [.ac])
                    XCTAssertNil(original.lidPermit?.batteryPermitID)
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 3, batteryPercent: 80)
                    XCTAssertFalse(subject.status.holding); XCTAssertFalse(subject.status.manualActive)
                    XCTAssertEqual(subject.status.manualEndReason, .powerDisconnected)
                    XCTAssertNil(subject.status.manualContinuousDeadline)
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 4, batteryPercent: 80)
                }
            }
        }
    }
    func testLateDisconnectReceiptCannotOverrideStopOrObservedPhysicalDetach() async throws {
        try await MainActor.run {
            for action in ["stop", "off", "gui", "thermal", "expiry", "wrongSession", "wrongSequence"] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    XCTAssertTrue(subject.start(duration: 120, now: base))
                    let lease = try XCTUnwrap(subject.workLease(now: base))
                    XCTAssertNil(lease.powerTransition)
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.lidEndReceipt = WorkSessionEndReceipt(bootID: "fixture", sessionID: action == "wrongSession" ? UUID() : subject.sessionID,
                        sequence: lease.sequence + (action == "wrongSequence" ? 1 : 0), observedAt: base + 1, kind: .disconnect, action: .followOS)
                    if action == "stop" { subject.stopCurrent() }
                    if action == "off" { XCTAssertTrue(subject.setEnabled(false)) }
                    let now = base + (action == "expiry" ? 121 : 3)
                    subject.update(power: .battery, thermal: action == "thermal" ? 2 : 0, fullWake: true,
                        controllingUser: action != "gui", now: now, batteryPercent: 80)
                    subject.acceptBridge(bridge, protection: nil, now: now)
                    XCTAssertFalse(subject.status.manualActive, action); XCTAssertFalse(subject.status.holding, action)
                    XCTAssertNil(subject.status.pendingBatteryMinutes); XCTAssertNil(subject.status.manualContinuousDeadline)
                    XCTAssertNil(subject.workLease(now: now)?.powerTransition)
                }
            }
        }
    }
    func testRepeatedProjectionCannotCreateCarryoverOrChangeTheSingleManualDeadline() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                subject.setAutomatic(true); XCTAssertTrue(subject.start(duration: 180, now: base))
                let original = subject.status.manualRequestID
                for _ in 0..<3 {
                    let lease = try XCTUnwrap(subject.workLease(now: base))
                    XCTAssertNil(lease.powerTransition); XCTAssertNil(lease.lidPermit?.batteryPermitID)
                    XCTAssertEqual(lease.manualRequestID, original)
                }
                let saved = try JSONDecoder().decode(IdleSessionSettings.self, from: XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey)))
                XCTAssertNil(saved.manualBatteryBudget); XCTAssertNil(saved.automaticBatteryBudget)
                XCTAssertNil(subject.status.pendingBatteryMinutes); XCTAssertTrue(subject.status.manualActive)
                XCTAssertEqual(subject.status.manualContinuousDeadline, base + 180); XCTAssertEqual(backend.releases, 0)
            }
        }
    }
    func testConsumedDisconnectReceiptCannotCreateAllowanceAfterConfirmedACReturn() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                XCTAssertTrue(subject.start(duration: 600, now: base))
                let old = try XCTUnwrap(subject.workLease(now: base))
                var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                bridge.lidEndReceipt = WorkSessionEndReceipt(bootID: "fixture", sessionID: subject.sessionID, sequence: old.sequence,
                    observedAt: base + 1, kind: .disconnect, action: .followOS)
                subject.acceptBridge(bridge, protection: nil, now: base + 2)
                XCTAssertFalse(subject.status.manualActive)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 3, batteryPercent: 80)
                subject.acceptBridge(bridge, protection: nil, now: base + 4)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 5, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                XCTAssertNil(subject.status.manualContinuousDeadline); XCTAssertEqual(subject.status.manualBatteryRemaining, 7200, accuracy: 0.001)
            }
        }
    }
    func testEnableAcknowledgementDoesNotRequireTheAutomaticPowerConditionToMatch() async {
        await MainActor.run {
            withFixture { defaults, backend in
                let controller = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil)
                controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
                controller.setAutomatic(true)
                XCTAssertTrue(controller.setEnabled(false))
                XCTAssertTrue(controller.setEnabled(true))
                XCTAssertTrue(controller.status.enabled); XCTAssertTrue(controller.status.automaticEnabled)
                XCTAssertEqual(controller.status.powerCondition, .ac)
                XCTAssertNil(controller.status.blockReason)
                XCTAssertFalse(controller.status.automaticActive); XCTAssertFalse(controller.status.holding)
                XCTAssertEqual(backend.creates, 0)
                XCTAssertTrue(controller.end())
            }
        }
    }

    func testLegacyHandoffDoesNotRearmSuppressedAutomaticWork() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                var saved = IdleSessionSettings(); saved.version = 2
                saved.automaticEnabled = true; saved.automaticSuppressed = true
                defaults.set(try JSONEncoder().encode(saved), forKey: UserSessionController.preferenceKey)
                var legacy = Control(enabled: true); legacy.powerCondition = .ac
                let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil,
                    legacyControl: legacy, legacyBridge: WorkSessionBridge(coordinated: false,
                        automaticBudget: ProtectionState(), manualBudget: nil))
                controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
                XCTAssertTrue(controller.status.automaticEnabled)
                XCTAssertEqual(controller.runtimeMarkers.pauseReason, .userStop)
                XCTAssertFalse(controller.status.automaticActive)
                XCTAssertFalse(controller.status.holding); XCTAssertEqual(backend.creates, 0)
                XCTAssertTrue(controller.end())
            }
        }
    }

    func testCurrentCommonPreferencesAreNotOverwrittenByAnUncoordinatedRoot() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                var saved = IdleSessionSettings(); saved.version = 3
                saved.automaticEnabled = false; saved.powerCondition = .ac
                saved.automaticHoldMinutes = 15
                defaults.set(try JSONEncoder().encode(saved), forKey: UserSessionController.preferenceKey)
                var legacy = Control(); legacy.powerCondition = .any; legacy.automaticHoldMinutes = 240
                let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil,
                    legacyControl: legacy, legacyBridge: WorkSessionBridge(coordinated: false,
                        automaticBudget: ProtectionState(), manualBudget: nil))
                controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
                XCTAssertFalse(controller.status.automaticEnabled); XCTAssertFalse(controller.status.holding)
                XCTAssertEqual(controller.status.powerCondition, .ac)
                XCTAssertEqual(controller.status.automaticMinutes, 15); XCTAssertEqual(backend.creates, 0)
                XCTAssertTrue(controller.end())
            }
        }
    }

    func testLegacyBatteryTimerIsNotRestartedDuringHandoff() async {
        await MainActor.run {
            withFixture { defaults, backend in
                let now = ContinuousTime.now
                var legacy = Control(); legacy.powerCondition = .battery; legacy.automaticHoldMinutes = 180
                legacy.batteryHoldUntil = Date().timeIntervalSince1970 + 60
                var budget = ProtectionState(); budget.restart(boot: "old-timer")
                budget.prepareBatteryBudget(power: .battery, needed: true, clock: now - 600, boot: "old-timer")
                let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil,
                    legacyControl: legacy, legacyBridge: WorkSessionBridge(coordinated: false,
                        automaticBudget: budget, manualBudget: nil), boot: "old-timer")
                controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: now, batteryPercent: 80)
                XCTAssertNil(controller.status.batteryHoldUntil); XCTAssertNil(controller.status.pendingBatteryMinutes)
                XCTAssertFalse(controller.status.holding); XCTAssertEqual(backend.creates, 0)
                XCTAssertEqual(controller.status.batteryRemaining, 0, accuracy: 1)
                XCTAssertTrue(controller.end())
            }
        }
    }

    func testLegacyNotebookHandoffKeepsExplicitOffConditionAndEarlierBudgetsWithoutRestoringATimer() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let now = ContinuousTime.now
                var previous = IdleSessionSettings(); previous.version = 2
                previous.enabled = false; previous.automaticEnabled = true
                previous.limits = UserLimits(batteryFloor: 40, maxHoldHours: 2)
                var nativeBudget = ProtectionState(); nativeBudget.restart(boot: "handoff")
                nativeBudget.prepareBatteryBudget(power: .battery, needed: true, clock: now - 90, boot: "handoff")
                previous.manualBatteryBudget = nativeBudget
                let original = try JSONEncoder().encode(previous)
                defaults.set(original, forKey: UserSessionController.preferenceKey)
                var legacy = Control(); legacy.powerCondition = .battery; legacy.automaticHoldMinutes = 180
                legacy.batteryHoldUntil = Date().timeIntervalSince1970 + 600
                XCTAssertTrue(legacy.isSupported)
                var rootAuto = ProtectionState(); rootAuto.restart(boot: "handoff")
                rootAuto.prepareBatteryBudget(power: .battery, needed: true, clock: now - 120, boot: "handoff")
                var rootManual = ProtectionState(); rootManual.restart(boot: "handoff")
                rootManual.prepareBatteryBudget(power: .battery, needed: true, clock: now - 60, boot: "handoff")
                let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil,
                    legacyControl: legacy, legacyBridge: WorkSessionBridge(coordinated: false,
                        automaticBudget: rootAuto, manualBudget: rootManual), boot: "handoff")
                controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: now, batteryPercent: 80)
                XCTAssertFalse(controller.status.enabled); XCTAssertFalse(controller.status.holding)
                XCTAssertEqual(controller.status.powerCondition, .ac)
                XCTAssertEqual(controller.status.automaticMinutes, 120, "Legacy battery choices respect the v3 120-minute limit")
                XCTAssertEqual(controller.status.limits?.batteryFloor, 40)
                XCTAssertEqual(controller.status.batteryRemaining, 0, accuracy: 1)
                XCTAssertEqual(controller.status.manualBatteryRemaining, 7200, accuracy: 1)
                XCTAssertNil(controller.status.pendingBatteryMinutes); XCTAssertNil(controller.status.batteryHoldUntil)
                XCTAssertNil(controller.status.until); XCTAssertFalse(controller.status.manualActive)
                XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey + ".migration.v2.backup"), original)
                let migrated = try JSONDecoder().decode(IdleSessionSettings.self,
                    from: XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey)))
                XCTAssertEqual(migrated.version, IdleSessionSettings.currentVersion)
                XCTAssertEqual(migrated.automaticHoldMinutes, 120, "Clamp the saved choice without importing a live timer or legacy ledger")
                XCTAssertNil(migrated.manualBatteryBudget); XCTAssertNil(migrated.automaticBatteryBudget)
                XCTAssertNil(migrated.limits?.maxHoldHours)
                XCTAssertTrue(controller.end())
            }
        }
    }

    func testChangingBatteryLimitsKeepsConsumedBudgetAndRejectsUnsupportedValues() async throws {
        try await MainActor.run {
            try withFixture { defaults, fixture in
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil,
                    boot: "limit-update")
                let now = ContinuousTime.now
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: now, batteryPercent: 80)
                XCTAssertTrue(subject.start(duration: 3600, now: now))
                let requestID = try XCTUnwrap(subject.status.manualRequestID)
                let deadline = try XCTUnwrap(subject.status.manualContinuousDeadline)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: now + 60, batteryPercent: 80)
                subject.setLimits(UserLimits(batteryFloor: 50, maxHoldHours: 0.5))
                XCTAssertTrue(subject.status.holding)
                XCTAssertEqual(subject.status.manualMaximumMinutes, 120)
                XCTAssertEqual(subject.status.manualRequestID, requestID)
                XCTAssertEqual(subject.status.manualContinuousDeadline, deadline)
                XCTAssertEqual(deadline, now + 3600, accuracy: 0.001)
                XCTAssertEqual(subject.status.manualBatteryRemaining, 7140, accuracy: 0.001,
                               "The original 120-minute battery ceiling is distinct from the selected one-hour deadline")
                let original = try XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey))
                subject.setLimits(UserLimits(closedLidMaxTemperature: 40))
                subject.setLimits(UserLimits(maxHoldHours: .infinity))
                XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), original)
                XCTAssertEqual(subject.status.limits, UserLimits(batteryFloor: 50))
                XCTAssertTrue(subject.end())
                subject.setLimits(UserLimits())
                XCTAssertEqual(subject.status.limits, UserLimits(batteryFloor: 50))
            }
        }
    }

    func testExplicitStartUsesFreshEnvironmentRatherThanPreviousPollingResult() async {
        await MainActor.run {
            withFixture { defaults, fixture in
                let login = GUISessionIdentity(uid: getuid(), sessionID: 100001)
                let gui = GUISessionObservation(login: login, consoleUID: login.uid)
                let cases: [UserSessionEnvironment] = [
                    .init(power: .battery, thermal: 0, fullWake: true, batteryPercent: 80),
                    .init(power: .ac, thermal: 2, fullWake: true, batteryPercent: nil),
                    .init(power: .ac, thermal: nil, fullWake: true, batteryPercent: nil),
                    .init(power: .ac, thermal: 0, fullWake: false, batteryPercent: nil),
                    .init(power: .ac, thermal: 0, fullWake: nil, batteryPercent: nil),
                    .init(power: .unknown, thermal: 0, fullWake: true, batteryPercent: nil)
                ]
                for (index, environment) in cases.enumerated() {
                    defaults.removeObject(forKey: UserSessionController.preferenceKey)
                    let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: { gui },
                        environmentProbe: { environment })
                    let now = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, gui: gui, now: now)
                    XCTAssertTrue(subject.status.canStart)
                    XCTAssertFalse(subject.start(duration: index == 0 ? nil : 60, now: now))
                    XCTAssertEqual(subject.status.power, environment.power)
                    XCTAssertFalse(subject.status.holding); XCTAssertEqual(fixture.creates, 0)
                    XCTAssertTrue(subject.end())
                }
            }
        }
    }
    func testAutomaticAndResumeCommandsRecheckPowerAndThermalImmediately() async {
        await MainActor.run {
            withFixture { defaults, fixture in
                let login = GUISessionIdentity(uid: getuid(), sessionID: 100001)
                let gui = GUISessionObservation(login: login, consoleUID: login.uid)
                var environment = UserSessionEnvironment(power: .battery, thermal: 0, fullWake: true, batteryPercent: 80)
                var clock = ContinuousTime.now
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: { gui },
                    environmentProbe: { environment }, boot: "fixture", continuousClock: { clock })
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: gui, now: clock)
                subject.setAutomatic(true)
                XCTAssertFalse(subject.status.holding); XCTAssertEqual(fixture.creates, 0)
                environment = .init(power: .ac, thermal: 2, fullWake: true, batteryPercent: nil)
                subject.setEnabled(true)
                XCTAssertEqual(subject.status.blockReason, "thermal"); XCTAssertEqual(fixture.creates, 0)
                environment.thermal = 0
                XCTAssertFalse(subject.setEnabled(true), "One healthy observation cannot clear a protection latch")
                for _ in 0..<6 { clock += 10; subject.refresh() }
                XCTAssertTrue(subject.setEnabled(true))
                XCTAssertNil(subject.status.blockReason); XCTAssertTrue(subject.status.automaticActive)
                XCTAssertTrue(subject.status.holding); XCTAssertEqual(fixture.creates, 1)
                XCTAssertTrue(subject.end())
            }
        }
    }
    func testExtensionReadsBatteryFloorAndDoesNotLeaveThePreviousRequestHolding() async {
        await MainActor.run {
            withFixture { defaults, fixture in
                let login = GUISessionIdentity(uid: getuid(), sessionID: 100001)
                let gui = GUISessionObservation(login: login, consoleUID: login.uid)
                var environment = UserSessionEnvironment(power: .ac, thermal: 0, fullWake: true, batteryPercent: nil)
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: { gui },
                    environmentProbe: { environment }, boot: "fixture")
                defer { _ = subject.end() }
                subject.refresh(); XCTAssertFalse(subject.setManualBatteryContinuationMinutes(120))
                XCTAssertTrue(subject.start(duration: 3600))
                let original = subject.status.manualContinuousDeadline
                XCTAssertFalse(subject.extend(duration: 60)); XCTAssertEqual(subject.status.manualContinuousDeadline, original)
                environment = .init(power: .battery, thermal: 0, fullWake: true, batteryPercent: 20)
                subject.refresh()
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.status.manualEndReason, .powerDisconnected)
                XCTAssertFalse(subject.status.canStart, "The fresh 20% reading also prevents a new battery request")
                XCTAssertFalse(subject.start(duration: 900))
                XCTAssertNil(subject.status.manualRequestID); XCTAssertEqual(fixture.releases, 1)
            }
        }
    }
    func testV1SettingsMigrationBacksUpOriginalBytesAndKeepsConsumedBatteryBudget() async throws {
        try await MainActor.run {
            try withFixture { defaults, fixture in
                let now = ContinuousTime.now
                var budget = ProtectionState()
                budget.prepareBatteryBudget(power: .battery, needed: true, clock: now - 60, boot: "migration-test")
                var v1 = IdleSessionSettings(); v1.version = 1
                v1.enabled = false; v1.automaticEnabled = true; v1.automaticSuppressed = true
                v1.manualBatteryBudget = budget
                let original = try JSONEncoder().encode(v1)
                defaults.set(original, forKey: UserSessionController.preferenceKey)
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil, boot: "migration-test")
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: now, batteryPercent: 80)
                XCTAssertFalse(subject.status.enabled); XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.status.manualBatteryRemaining, 7200, accuracy: 0.01)
                XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey + ".migration.v1.backup"), original)
                let saved = try JSONDecoder().decode(IdleSessionSettings.self,
                    from: XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey)))
                XCTAssertEqual(saved.version, IdleSessionSettings.currentVersion)
                XCTAssertFalse(saved.automaticEnabled); XCTAssertNil(saved.manualBatteryBudget)
                subject.setEnabled(true); subject.setAutomatic(false)
                XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey + ".migration.v1.backup"), original)
                XCTAssertTrue(subject.end())
            }
        }
    }
    func testLegacyBatteryFloorAndStricterTimeLimitApplyToCommonWork() async throws {
        try await MainActor.run {
            try withFixture { defaults, fixture in
                var legacy = Control(enabled: true)
                legacy.limits = UserLimits(batteryFloor: 50, maxHoldHours: 0.5)
                let wall = Date(timeIntervalSince1970: 1000)
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil,
                    legacyControl: legacy, boot: "legacy-limits", wallClock: { wall })
                defer { _ = subject.end() }
                let now = ContinuousTime.now
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: now, batteryPercent: 50)
                XCTAssertEqual(subject.status.manualMaximumMinutes, 120)
                XCTAssertFalse(subject.status.canStart); XCTAssertFalse(subject.start(duration: 3600, now: now))
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: now + 1, batteryPercent: 80)
                XCTAssertTrue(subject.start(duration: 3600, now: now + 1))
                XCTAssertEqual(subject.status.limits, UserLimits(batteryFloor: 50))
                XCTAssertNil(subject.settings.limits?.maxHoldHours, "Legacy time limits do not replace the per-request battery ceiling")
                XCTAssertEqual(try XCTUnwrap(subject.status.until).timeIntervalSince(wall), 3600, accuracy: 0.001)
                XCTAssertEqual(try XCTUnwrap(subject.status.manualContinuousDeadline), now + 3601, accuracy: 0.001)
                XCTAssertEqual(subject.status.manualBatteryRemaining, 7200, accuracy: 0.001)
                XCTAssertTrue(subject.end())
            }
        }
    }
    func testCompletedControllerCannotBeReopenedOrRewritePreferences() async throws {
        try await MainActor.run {
            try withFixture { defaults, fixture in
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                subject.setAutomatic(true)
                XCTAssertTrue(subject.start(duration: 60)); XCTAssertTrue(subject.end())
                let raw = try XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey))
                XCTAssertFalse(subject.start(duration: 60))
                subject.setAutomatic(false); subject.setEnabled(false)
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                XCTAssertTrue(subject.status.enabled); XCTAssertTrue(subject.status.automaticEnabled)
                XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), raw)
                XCTAssertEqual(fixture.creates, 1)
            }
        }
    }
    @MainActor
    func testNativeRequestIsReleasedOnFreshBatteryProtectionWhileForeignWorkSurvives() async throws {
        final class RecordedNativeBackend: IdleAssertionBackend {
            let native = NativeIdleAssertionBackend()
            var createdIDs: [UInt32] = []
            var createCodes: [Int32] = []
            var timeouts: [TimeInterval] = []
            var releasedIDs: [UInt32] = []
            var releaseCodes: [Int32] = []
            func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
                let result = native.create(timeout: timeout)
                createCodes.append(result.code); timeouts.append(timeout)
                if let id = result.id { createdIDs.append(id) }
                return result
            }
            func renew(id: UInt32, timeout: TimeInterval) -> Int32 { native.renew(id: id, timeout: timeout) }
            func level(id: UInt32) -> Int? { native.level(id: id) }
            func release(id: UInt32) -> Int32 {
                let code = native.release(id: id)
                releasedIDs.append(id); releaseCodes.append(code)
                return code
            }
        }
        guard ProcessInfo.processInfo.environment["TETHER_RUN_LIVE_ASSERTION_TESTS"] == "1" else {
            throw XCTSkip("Set TETHER_RUN_LIVE_ASSERTION_TESTS=1 for bounded live IOKit tests")
        }
        let gui = GUISessionProbe.callerObservation()
        guard gui.login?.uid == getuid(), gui.consoleUID == getuid() else {
            throw XCTSkip("A current native GUI login is required for the controller's live assertion test")
        }
        let suite = "tether-session-native-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let foreign = Process()
        foreign.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        foreign.arguments = ["-i", "-t", "10"]
        try foreign.run()
        defer { if foreign.isRunning { foreign.terminate() }; foreign.waitUntilExit() }
        var environment = UserSessionEnvironment(power: .battery, thermal: 0, fullWake: true,
            batteryPercent: 80, lowPowerWarning: false)
        let backend = RecordedNativeBackend()
        let subject = UserSessionController(defaults: defaults, backend: backend, environmentProbe: { environment })
        defer { _ = subject.end() }
        subject.refresh()
        // Direct battery work reaches protection without an AC departure consuming it first.
        subject.setLimits(UserLimits(batteryFloor: 30))
        XCTAssertFalse(subject.setManualBatteryContinuationMinutes(1))
        XCTAssertTrue(subject.status.canStart, "Healthy fixture must have current GUI authority: \(subject.status), gui=\(gui)")
        XCTAssertFalse(subject.start(duration: 10), "A battery request below one minute is rejected by policy")
        XCTAssertTrue(backend.createCodes.isEmpty, "A rejected duration must never reach IOKit: \(subject.status)")
        XCTAssertTrue(subject.start(duration: 60), "Valid battery start failed: \(subject.status), GUI=\(gui), IOKit=\(backend.createCodes)")
        XCTAssertTrue(subject.status.holding)
        let ownID = try XCTUnwrap(backend.createdIDs.first)
        XCTAssertEqual(backend.createdIDs, [ownID]); XCTAssertEqual(backend.createCodes, [0])
        let nativeTimeout = try XCTUnwrap(backend.timeouts.first)
        XCTAssertGreaterThanOrEqual(nativeTimeout, IdleAssertionDriver.minimumLease)
        XCTAssertLessThanOrEqual(nativeTimeout, IdleSessionPolicy.healthTTL)
        XCTAssertEqual(backend.native.level(id: ownID), 255, "The exact allocation must be observed active before protection")
        let until = ContinuousTime.now + 2
        var observedForeign = false
        while ContinuousTime.now < until {
            if let requests = SystemProbe.sleepBlockerSnapshot(),
               requests.contains(where: { $0.pid == foreign.processIdentifier && $0.kind == .system }) {
                observedForeign = true; break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(observedForeign)
        let originalDeadline = try XCTUnwrap(subject.status.manualContinuousDeadline)
        let originalStart = try XCTUnwrap(subject.status.manualStartedAt)
        XCTAssertEqual(originalDeadline, originalStart + 60, accuracy: 0.001)
        environment = .init(power: .battery, thermal: 0, fullWake: true, batteryPercent: 20, lowPowerWarning: false)
        XCTAssertFalse(subject.extend(duration: 900))
        XCTAssertNil(subject.status.manualContinuousDeadline)
        XCTAssertNil(subject.status.manualRequestID)
        XCTAssertFalse(subject.status.manualActive)
        XCTAssertEqual(subject.status.manualEndReason, .protection)
        // A fresh reserve observation ends only Tether's request before extension approval.
        subject.refresh()
        XCTAssertEqual(subject.status.blockReason, "battery"); XCTAssertFalse(subject.status.holding)
        XCTAssertEqual(backend.createdIDs, [ownID], "Protection must not allocate another request")
        XCTAssertEqual(backend.releasedIDs, [ownID], "Protection must release exactly the allocation this test created")
        XCTAssertEqual(backend.releaseCodes, [0], "IOKit must confirm release of that allocation")
        XCTAssertNil(backend.native.level(id: ownID))
        let requests = try XCTUnwrap(SystemProbe.sleepBlockerSnapshot())
        XCTAssertFalse(requests.contains { $0.pid == getpid() && $0.reason == "Tether work session" })
        XCTAssertTrue(requests.contains { $0.pid == foreign.processIdentifier && $0.kind == .system })
        XCTAssertTrue(foreign.isRunning)
    }
    func testGUIObservationGapPreservesOriginalLeaseWithoutRenewingOrStarting() async {
        await MainActor.run {
            withFixture { defaults, fixture in
                let login = GUISessionIdentity(uid: getuid(), sessionID: 100001)
                var observed = GUISessionObservation(login: login, consoleUID: login.uid)
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: { observed }, environmentProbe: nil)
                let now = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: observed, now: now)
                XCTAssertTrue(subject.start(duration: nil, now: now))
                let renews = fixture.renews
                observed = GUISessionObservation(login: nil, consoleUID: nil)
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: observed, now: now + 1)
                XCTAssertTrue(subject.status.holding); XCTAssertFalse(subject.status.canStart)
                XCTAssertFalse(subject.start(duration: 60, now: now + 2))
                XCTAssertEqual(fixture.renews, renews); XCTAssertEqual(fixture.creates, 1)
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: observed, now: now + 30)
                XCTAssertFalse(subject.status.holding); XCTAssertFalse(subject.status.manualActive)
                XCTAssertEqual(fixture.releases, 1); _ = subject.end()
            }
        }
    }
    func testGUIUserSwitchReleasesOwnRequestAndDoesNotResurrectManualWork() async {
        await MainActor.run {
            withFixture { defaults, fixture in
                let login = GUISessionIdentity(uid: getuid(), sessionID: 100001)
                var observed = GUISessionObservation(login: login, consoleUID: login.uid)
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: { observed }, environmentProbe: nil)
                let now = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: observed, now: now)
                XCTAssertTrue(subject.start(duration: nil, now: now))
                observed = GUISessionObservation(login: login, consoleUID: login.uid + 1)
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: observed, now: now + 1)
                XCTAssertFalse(subject.status.holding); XCTAssertEqual(fixture.releases, 1)
                XCTAssertEqual(subject.status.manualEndReason, .sessionEnded)
                XCTAssertFalse(subject.start(duration: 60, now: now + 2))
                observed = GUISessionObservation(login: login, consoleUID: login.uid)
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: observed, now: now + 3)
                XCTAssertFalse(subject.status.holding); XCTAssertFalse(subject.status.canStart)
                XCTAssertTrue(subject.start(duration: 60, now: now + 4))
                XCTAssertEqual(fixture.creates, 2); _ = subject.end()
            }
        }
    }
    func testSameLoginLockObservationKeepsWorkButNewLoginRequiresExplicitStart() async {
        await MainActor.run {
            withFixture { defaults, fixture in
                let login = GUISessionIdentity(uid: getuid(), sessionID: 100001)
                var observed = GUISessionObservation(login: login, consoleUID: login.uid)
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: { observed }, environmentProbe: nil)
                let now = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: observed, now: now)
                XCTAssertTrue(subject.start(duration: nil, now: now))
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: observed, now: now + 1)
                XCTAssertTrue(subject.status.holding); XCTAssertEqual(fixture.releases, 0)
                observed = GUISessionObservation(login: GUISessionIdentity(uid: login.uid, sessionID: 100002), consoleUID: login.uid)
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: observed, now: now + 2)
                XCTAssertFalse(subject.status.holding); XCTAssertFalse(subject.status.manualActive)
                XCTAssertTrue(subject.start(duration: 60, now: now + 3)); _ = subject.end()
            }
        }
    }
    @MainActor
    private func withFixture(_ body: (UserDefaults, UserAssertionFixture) throws -> Void) rethrows {
        let name = "tether-session-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, UserAssertionFixture())
    }
    func testTimedStartAndExpiryUseActualOwnedRequestState() async {
        await MainActor.run {
            withFixture { defaults, fixture in
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil)
                let now = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now)
                XCTAssertFalse(subject.status.holding); XCTAssertTrue(subject.status.canStart)
                XCTAssertTrue(subject.start(duration: 3, now: now))
                XCTAssertNotNil(subject.status.until); XCTAssertEqual(fixture.creates, 1)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now + 3)
                XCTAssertFalse(subject.status.holding); XCTAssertFalse(subject.status.manualActive)
                XCTAssertNil(subject.status.until); XCTAssertEqual(fixture.releases, 1)
                _ = subject.end()
            }
        }
    }
    func testCorruptAndFuturePreferencesAreNeverOverwritten() async throws {
        try await MainActor.run {
            try withFixture { defaults, fixture in
                var future = IdleSessionSettings(); future.version = IdleSessionSettings.currentVersion + 1
                for raw in [Data("not-json".utf8), try JSONEncoder().encode(future)] {
                    defaults.set(raw, forKey: UserSessionController.preferenceKey)
                    let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil)
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                    subject.setAutomatic(true); subject.setEnabled(true)
                    XCTAssertFalse(subject.start(duration: 30)); XCTAssertFalse(subject.status.canStart)
                    XCTAssertNotNil(subject.status.error)
                    XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), raw)
                    XCTAssertEqual(fixture.creates, 0); _ = subject.end()
                }
            }
        }
    }
    func testLegacyOffMigratesButNotebookPowerRuleDoesNotAutoStartDesktop() async {
        await MainActor.run {
            withFixture { defaults, fixture in
                var legacy = Control(); legacy.enabled = false
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil, legacyControl: legacy)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                XCTAssertFalse(subject.status.enabled); XCTAssertFalse(subject.status.automaticEnabled)
                XCTAssertFalse(subject.start(duration: nil)); XCTAssertFalse(subject.status.holding)
                XCTAssertTrue(subject.setEnabled(true)); XCTAssertTrue(subject.start(duration: nil))
                XCTAssertTrue(subject.status.manualActive); XCTAssertTrue(subject.end())
                let restarted = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil)
                defer { _ = restarted.end() }
                restarted.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                XCTAssertFalse(restarted.status.manualActive); XCTAssertFalse(restarted.status.holding)
            }
        }
    }
    func testExplicitAutomaticChoiceSurvivesNormalExitAndUpdate() async throws {
        try await MainActor.run {
            try withFixture { defaults, fixture in
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                subject.setAutomatic(true); XCTAssertTrue(subject.status.holding)
                XCTAssertTrue(subject.end()); XCTAssertFalse(subject.status.holding)
                let saved = try JSONDecoder().decode(IdleSessionSettings.self, from: XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey)))
                XCTAssertTrue(saved.automaticEnabled); XCTAssertFalse(saved.automaticSuppressed)
                let restarted = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil)
                restarted.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                XCTAssertTrue(restarted.status.holding); _ = restarted.end()
            }
        }
    }
    func testFailedQuitIsRetriableAndNeverClaimsReleaseOrCreatesAnotherRequest() async {
        await MainActor.run {
            withFixture { defaults, fixture in
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                subject.setAutomatic(true); fixture.releaseCode = -7
                XCTAssertFalse(subject.end()); XCTAssertNotNil(subject.status.error)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                XCTAssertFalse(subject.status.holding); XCTAssertEqual(fixture.creates, 1)
                fixture.releaseCode = 0; XCTAssertTrue(subject.end())
                XCTAssertEqual(fixture.creates, 1)
            }
        }
    }
    func testForeignGUIAndUnreadableWakeCannotStart() async {
        await MainActor.run {
            withFixture { defaults, fixture in
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil)
                let base = ContinuousTime.now
                for (offset, wake, user) in [(0.0, Optional(true), false), (1, nil, true), (2, false, true)] {
                    subject.update(power: .ac, thermal: 0, fullWake: wake, controllingUser: user, now: base + offset)
                    XCTAssertFalse(subject.status.canStart); XCTAssertFalse(subject.start(duration: nil, now: base + offset))
                }
                XCTAssertEqual(fixture.creates, 0); _ = subject.end()
            }
        }
    }
    func testFailedLevelObservationIsNeverReportedAsHolding() async {
        await MainActor.run {
            withFixture { defaults, fixture in
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                fixture.levelValue = nil
                XCTAssertFalse(subject.start(duration: 30)); XCTAssertFalse(subject.status.holding)
                XCTAssertFalse(subject.status.manualActive); XCTAssertNil(subject.status.manualRequestID)
                XCTAssertEqual(fixture.creates, 1); XCTAssertEqual(fixture.releases, 1,
                    "Unconfirmed new work must roll back its own allocation before returning rejection")
                XCTAssertEqual(subject.workLease()?.reasons, [])
                XCTAssertNil(subject.workLease()?.expiry)
                _ = subject.end()
            }
        }
    }

    func testUnlimitedACEndsOnDetachAndBatteryRequiresNewExplicitBoundedManual() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                XCTAssertFalse(subject.setManualBatteryContinuationMinutes(120, now: base))
                XCTAssertTrue(subject.start(duration: nil, now: base)); XCTAssertNil(subject.status.until)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 1, batteryPercent: 80)
                XCTAssertFalse(subject.status.holding); XCTAssertFalse(subject.status.manualActive)
                XCTAssertNil(subject.status.until); XCTAssertEqual(subject.status.manualEndReason, .powerDisconnected)
                XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 1)
                XCTAssertTrue(subject.start(duration: 7200, now: base + 2))
                XCTAssertEqual(subject.status.manualContinuousDeadline, base + 7202)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 7202, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 7203, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
            }
        }
    }

    func testManualAndAutomaticReasonsEndIndependently() async {
        await MainActor.run {
            withFixture { defaults, fixture in
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                subject.setAutomatic(true)
                XCTAssertTrue(subject.start(duration: nil))
                subject.setAutomatic(false)
                XCTAssertTrue(subject.status.manualActive); XCTAssertTrue(subject.status.holding)
                XCTAssertFalse(subject.status.automaticActive); XCTAssertEqual(fixture.releases, 0)
                subject.setAutomatic(true)
                subject.endManual()
                XCTAssertFalse(subject.status.manualActive); XCTAssertTrue(subject.status.automaticActive)
                XCTAssertTrue(subject.status.holding); XCTAssertEqual(fixture.creates, 1)
                XCTAssertEqual(fixture.releases, 0)
                _ = subject.end()
            }
        }
    }

    func testBatteryRejectsUnlimitedAndOverCapWithoutResumingOnRestart() async throws {
        try await MainActor.run {
            try withFixture { defaults, fixture in
                let subject = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil, boot: "manual-test")
                let base = ContinuousTime.now
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                XCTAssertFalse(subject.start(duration: nil, now: base))
                XCTAssertFalse(subject.start(duration: 4 * 3600, now: base))
                XCTAssertTrue(subject.start(duration: 7200, now: base))
                XCTAssertEqual(subject.status.manualContinuousDeadline, base + 7200)
                let saved = try JSONDecoder().decode(IdleSessionSettings.self,
                    from: XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey)))
                XCTAssertNil(saved.manualBatteryBudget); XCTAssertTrue(subject.end())
                let restarted = UserSessionController(defaults: defaults, backend: fixture, guiProbe: nil, boot: "manual-test")
                defer { _ = restarted.end() }
                restarted.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 60, batteryPercent: 80)
                XCTAssertFalse(restarted.status.manualActive); XCTAssertFalse(restarted.status.holding)
                XCTAssertNil(restarted.status.manualContinuousDeadline)
                XCTAssertTrue(restarted.start(duration: 7200, now: base + 60))
                XCTAssertEqual(restarted.status.manualContinuousDeadline, base + 7260)
            }
        }
    }
}

extension UserSessionControllerTests {
    func testV3GeneralWorkRunsWhileOptionalRootHandoffIsUnavailable() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, requiresRootHandoff: true, boot: "v3-live")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                XCTAssertTrue(subject.start(duration: 180, now: base))
                XCTAssertTrue(subject.status.holding); XCTAssertEqual(backend.creates, 1)
                XCTAssertNil(try XCTUnwrap(subject.workLease(now: base)).lidPermit)
            }
        }
    }
    func testV4PreparedACManualLidPermitDoesNotImportLegacyBatteryAutomaticOrCarryChoice() async throws {
        try await MainActor.run {
            for continuation in [Int?(3), nil] {
                try withFixture { defaults, backend in
                    let base = ContinuousTime.now
                    let prepared = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil,
                        requiresRootHandoff: true, boot: "fixture")
                    defer { _ = prepared.end() }
                    prepared.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    prepared.setAllowClosedLid(true); prepared.setPowerCondition(.battery); prepared.setAutomatic(false)
                    XCTAssertEqual(prepared.setManualBatteryContinuationMinutes(continuation, now: base), continuation == nil)
                    XCTAssertTrue(prepared.start(duration: 900, now: base))
                    XCTAssertNil(try XCTUnwrap(prepared.workLease(now: base)).lidPermit)
                    let bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    prepared.acceptBridge(bridge, protection: nil, preparedControl: Control(), now: base + 1)
                    let lease = try XCTUnwrap(prepared.workLease(now: base + 1))
                    let permit = try XCTUnwrap(lease.lidPermit)
                    XCTAssertEqual(lease.reasons, [.manual]); XCTAssertFalse(prepared.status.automaticActive)
                    XCTAssertEqual(permit.powerScopes, [.ac]); XCTAssertNil(permit.batteryPermitID); XCTAssertNil(permit.batteryDuration)
                    XCTAssertTrue(permit.isValid(now: base + 1, source: .ac)); XCTAssertFalse(permit.isValid(now: base + 1, source: .battery))
                    XCTAssertTrue(lease.isValid(now: base + 1)); XCTAssertTrue(prepared.status.holding)
                    XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
                }
            }
        }
    }
    func testV4ACManualLidPermitNeverCapturesRemovedUnplugChoice() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                subject.setAllowClosedLid(true)
                XCTAssertFalse(subject.setManualBatteryContinuationMinutes(30, now: base))
                XCTAssertTrue(subject.start(duration: nil, now: base))
                let original = try XCTUnwrap(subject.workLease(now: base)?.lidPermit)
                XCTAssertEqual(original.powerScopes, [.ac]); XCTAssertNil(original.batteryDuration); XCTAssertNil(original.batteryPermitID)
                XCTAssertTrue(subject.setManualBatteryContinuationMinutes(nil, now: base + 1))
                let changed = try XCTUnwrap(subject.workLease(now: base + 1)?.lidPermit)
                XCTAssertEqual(changed.powerScopes, [.ac]); XCTAssertNil(changed.batteryPermitID)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 2, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                XCTAssertNil(subject.status.manualContinuousDeadline)
            }
        }
    }
    func testV4BatteryManualACKCanShortenButNotExtendAndSecondDetachConsumesIt() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                subject.setAllowClosedLid(true); XCTAssertTrue(subject.start(duration: 1800, now: base))
                let permit = try XCTUnwrap(subject.workLease(now: base)?.lidPermit?.batteryPermitID)
                var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                bridge.batteryPermitReceipt = WorkSessionBatteryPermitReceipt(bootID: "fixture", sessionID: subject.sessionID,
                    permitID: permit, observedAt: base + 1, deadline: base + 1780)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 2, batteryPercent: 80)
                subject.acceptBridge(bridge, protection: nil, now: base + 2)
                XCTAssertEqual(subject.status.manualContinuousDeadline, base + 1780)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 3, batteryPercent: 80)
                bridge.batteryPermitReceipt?.observedAt = base + 4; bridge.batteryPermitReceipt?.deadline = base + 2000
                subject.acceptBridge(bridge, protection: nil, now: base + 4)
                XCTAssertEqual(subject.status.manualContinuousDeadline, base + 1780)
                XCTAssertFalse(subject.extend(duration: 180, now: base + 4)); XCTAssertFalse(subject.rescheduleManual(duration: 180, now: base + 4))
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 5, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
            }
        }
    }
    func testV4LateEndedManualACKCannotCreateBatteryAuthorityForSurvivingACAutomatic() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                subject.setAllowClosedLid(true); subject.setAutomatic(true)
                XCTAssertTrue(subject.start(duration: 600, now: base))
                let original = try XCTUnwrap(subject.workLease(now: base))
                subject.endManual()
                var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                bridge.batteryPermitReceipt = WorkSessionBatteryPermitReceipt(bootID: "fixture", sessionID: subject.sessionID,
                    permitID: try XCTUnwrap(original.manualRequestID), observedAt: base + 1, deadline: base + 7201)
                subject.acceptBridge(bridge, protection: nil, now: base + 2)
                XCTAssertTrue(subject.status.automaticActive); XCTAssertFalse(subject.status.manualActive)
                XCTAssertNil(subject.sessionDecision.automaticBatteryDeadline)
                XCTAssertNil(subject.workLease(now: base + 2)?.lidPermit?.batteryPermitID)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 3, batteryPercent: 80)
                XCTAssertFalse(subject.status.automaticActive); XCTAssertFalse(subject.status.holding)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 4, batteryPercent: 80)
                XCTAssertTrue(subject.status.automaticActive); XCTAssertFalse(subject.status.manualActive)
            }
        }
    }
    func testV4LateBatteryACKRejectsUnissuedBeforeIssueForeignAndReplacedRequests() async throws {
        try await MainActor.run {
            for scenario in ["unissued", "beforeIssue", "wrongSession", "newActivation"] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    subject.setAllowClosedLid(true); XCTAssertTrue(subject.start(duration: 1800, now: base))
                    let old = try XCTUnwrap(subject.workLease(now: base))
                    let original = try XCTUnwrap(old.lidPermit?.batteryPermitID)
                    if scenario == "newActivation" { subject.endManual(); XCTAssertTrue(subject.start(duration: 1200, now: base + 2)) }
                    let deadline = subject.status.manualContinuousDeadline
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.batteryPermitReceipt = WorkSessionBatteryPermitReceipt(bootID: "fixture",
                        sessionID: scenario == "wrongSession" ? UUID() : subject.sessionID,
                        permitID: scenario == "unissued" ? UUID() : original,
                        observedAt: base + (scenario == "beforeIssue" ? -1 : 1), deadline: base + 60)
                    subject.acceptBridge(bridge, protection: nil, now: base + 3)
                    XCTAssertTrue(subject.status.manualActive)
                    XCTAssertEqual(subject.status.manualContinuousDeadline, deadline, scenario)
                    XCTAssertNil(subject.sessionDecision.automaticBatteryDeadline)
                }
            }
        }
    }
    func testV4RetainedBatteryManualReceiptsKeepEarliestCapAndNeverAuthorizeSecondDetach() async throws {
        try await MainActor.run {
            for reversed in [false, true] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    subject.setAllowClosedLid(true); XCTAssertTrue(subject.start(duration: 1800, now: base))
                    let permit = try XCTUnwrap(subject.workLease(now: base)?.lidPermit?.batteryPermitID)
                    let first = WorkSessionBatteryPermitReceipt(bootID: "fixture", sessionID: subject.sessionID, permitID: permit, observedAt: base + 1, deadline: base + 1700)
                    let later = WorkSessionBatteryPermitReceipt(bootID: "fixture", sessionID: subject.sessionID, permitID: permit, observedAt: base + 2, deadline: base + 1780)
                    let foreign = WorkSessionBatteryPermitReceipt(bootID: "fixture", sessionID: UUID(), permitID: permit, observedAt: base + 1, deadline: base + 60)
                    var retained = [later, foreign, first]; if reversed { retained.reverse() }
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.batteryPermitReceipt = later; bridge.batteryPermitReceipts = retained
                    subject.acceptBridge(bridge, protection: nil, now: base + 3)
                    XCTAssertEqual(subject.status.manualContinuousDeadline, base + 1700)
                    bridge.batteryPermitReceipts = nil
                    subject.acceptBridge(bridge, protection: nil, now: base + 4)
                    XCTAssertEqual(subject.status.manualContinuousDeadline, base + 1700)
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 5, batteryPercent: 80)
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 6, batteryPercent: 80)
                    XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                }
            }
        }
    }
    func testV4TerminalReceiptWinsEveryOrderWithoutCreatingBatteryAutomatic() async throws {
        try await MainActor.run {
            for scenario in ["sleep/together", "sleep/terminalFirst", "sleep/ackFirst", "end/together", "end/terminalFirst", "end/ackFirst"] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    let pieces = scenario.split(separator: "/"); let terminal = pieces[0], order = pieces[1]
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    subject.setAllowClosedLid(true); subject.setAutomatic(true)
                    XCTAssertTrue(subject.start(duration: 600, now: base))
                    let original = try XCTUnwrap(subject.workLease(now: base))
                    var battery = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    battery.batteryPermitReceipt = WorkSessionBatteryPermitReceipt(bootID: "fixture", sessionID: subject.sessionID,
                        permitID: try XCTUnwrap(original.manualRequestID), observedAt: base + 1, deadline: base + 7201)
                    var consumed = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    if terminal == "sleep" {
                        consumed.sleepConsumption = WorkSessionSleepConsumption(bootID: "fixture", sessionID: subject.sessionID,
                            sequence: original.sequence, observedAt: base + 2)
                    } else {
                        consumed.lidEndReceipt = WorkSessionEndReceipt(bootID: "fixture", sessionID: subject.sessionID,
                            sequence: original.sequence, observedAt: base + 2, kind: .disconnect, action: .followOS)
                    }
                    if order == "together" {
                        consumed.batteryPermitReceipt = battery.batteryPermitReceipt
                        subject.acceptBridge(consumed, protection: nil, now: base + 3)
                    } else {
                        subject.acceptBridge(order == "terminalFirst" ? consumed : battery, protection: nil, now: base + 3)
                        subject.acceptBridge(order == "terminalFirst" ? battery : consumed, protection: nil, now: base + 4)
                    }
                    XCTAssertFalse(subject.status.manualActive, scenario); XCTAssertNil(subject.sessionDecision.automaticBatteryDeadline)
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 5, batteryPercent: 80)
                    XCTAssertEqual(subject.status.automaticActive, terminal == "sleep",
                        "An ordinary Sleep receipt may reevaluate automatic work; a terminal disconnect receipt needs a new actual trigger")
                    subject.acceptBridge(battery, protection: nil, now: base + 6)
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 7, batteryPercent: 80)
                    XCTAssertFalse(subject.status.holding); XCTAssertFalse(subject.status.manualActive)
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 8, batteryPercent: 80)
                    XCTAssertTrue(subject.status.automaticActive)
                }
            }
        }
    }
    func testV4OldTerminalReceiptsPreserveNewACIntentButNewDetachConsumesEverything() async throws {
        try await MainActor.run {
            for scenario in ["sleep/newAuto", "sleep/oldAuto", "end/newAuto", "end/oldAuto"] {
                try withFixture { defaults, backend in
                    let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    let terminal = scenario.hasPrefix("sleep") ? "sleep" : "end"
                    let replaceAutomatic = scenario.hasSuffix("newAuto")
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    subject.setAllowClosedLid(true); subject.setAutomatic(true)
                    XCTAssertTrue(subject.start(duration: nil, now: base))
                    let original = try XCTUnwrap(subject.workLease(now: base))
                    subject.endManual(); XCTAssertTrue(subject.start(duration: 600, now: base + 3))
                    if replaceAutomatic { subject.setAutomatic(false); subject.setAutomatic(true) }
                    let current = try XCTUnwrap(subject.status.manualRequestID)
                    var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                    bridge.batteryPermitReceipt = WorkSessionBatteryPermitReceipt(bootID: "fixture", sessionID: subject.sessionID,
                        permitID: try XCTUnwrap(original.manualRequestID), observedAt: base + 1, deadline: base + 7201)
                    if terminal == "sleep" {
                        bridge.sleepConsumption = WorkSessionSleepConsumption(bootID: "fixture", sessionID: subject.sessionID,
                            sequence: original.sequence, observedAt: base + 2)
                    } else {
                        bridge.lidEndReceipt = WorkSessionEndReceipt(bootID: "fixture", sessionID: subject.sessionID,
                            sequence: original.sequence, observedAt: base + 2, kind: .disconnect, action: .followOS)
                    }
                    subject.acceptBridge(bridge, protection: nil, now: base + 4)
                    XCTAssertTrue(subject.status.manualActive); XCTAssertEqual(subject.status.manualRequestID, current)
                    XCTAssertEqual(subject.status.manualContinuousDeadline, base + 603)
                    subject.acceptBridge(bridge, protection: nil, now: base + 5)
                    XCTAssertEqual(subject.status.manualRequestID, current)
                    subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 6, batteryPercent: 80)
                    XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.automaticActive); XCTAssertFalse(subject.status.holding)
                    subject.acceptBridge(bridge, protection: nil, now: base + 7)
                    XCTAssertFalse(subject.status.manualActive); XCTAssertNil(subject.status.manualContinuousDeadline)
                }
            }
        }
    }
    func testV3StopMarkersSurviveAutomaticToggleAndActualControllerRestart() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let base = ContinuousTime.now
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "v3-live")
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.setPowerCondition(.any); subject.setAutomatic(true)
                XCTAssertTrue(subject.start(duration: 180, now: base)); subject.stopCurrent()
                subject.setAutomatic(false); subject.setAutomatic(true)
                XCTAssertEqual(subject.runtimeMarkers.pauseReason, .userStop); XCTAssertFalse(subject.status.holding)
                XCTAssertTrue(subject.end())
                let next = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "v3-live")
                defer { _ = next.end() }
                next.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 20)
                XCTAssertEqual(next.runtimeMarkers.pauseReason, .userStop); XCTAssertFalse(next.status.holding)
                XCTAssertFalse(next.status.manualActive); XCTAssertTrue(next.setEnabled(true)); XCTAssertTrue(next.status.automaticActive)
            }
        }
    }
    func testV3UserSleepPauseNeedsObservedSameProcessSleepWakeAndStaysOnRestart() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let base = ContinuousTime.now
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "v3-live")
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.setAutomatic(true); XCTAssertTrue(subject.start(duration: 180, now: base))
                XCTAssertTrue(subject.pauseForUserSleep(now: base + 1))
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 2)
                XCTAssertEqual(subject.runtimeMarkers.pauseReason, .userSleep); XCTAssertFalse(subject.status.holding)
                subject.observeSystemSleep(observedAt: base + 3)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 4)
                XCTAssertEqual(subject.runtimeMarkers.pauseReason, .userSleep); XCTAssertFalse(subject.status.manualActive)
                XCTAssertFalse(subject.status.automaticActive, "An observed Sleep/Wake pair alone never clears explicit Sleep")
                XCTAssertTrue(subject.setEnabled(true)); XCTAssertTrue(subject.status.automaticActive)
                XCTAssertTrue(subject.pauseForUserSleep(now: base + 5)); XCTAssertTrue(subject.end())
                let next = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "v3-live")
                defer { _ = next.end() }
                next.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 6)
                next.observeSystemSleep(observedAt: base + 7)
                next.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 8)
                XCTAssertEqual(next.runtimeMarkers.pauseReason, .userSleep); XCTAssertFalse(next.status.holding)
            }
        }
    }
    func testV3ThermalHelperLatchRequiresExplicitMatchingResumeAcknowledgement() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "v3-live")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.setAutomatic(true); XCTAssertTrue(subject.start(duration: nil, now: base))
                let old = try XCTUnwrap(subject.workLease(now: base))
                let latch = WorkSessionProtectionLatch(bootID: "v3-live", reason: "thermal", observedAt: base + 1,
                    sessionID: subject.sessionID, sequence: old.sequence)
                var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                bridge.lidProtection = latch
                bridge.lidEndReceipt = WorkSessionEndReceipt(bootID: "v3-live", sessionID: subject.sessionID,
                    sequence: old.sequence, observedAt: base + 1, kind: .protection, action: .sleepIfClosed)
                subject.acceptBridge(bridge, protection: nil, now: base + 2)
                let ended = try XCTUnwrap(subject.workLease(now: base + 2))
                XCTAssertEqual(ended.reasons, []); XCTAssertEqual(ended.endConsumptionID, bridge.lidEndReceipt?.id)
                XCTAssertNil(ended.protectionResumeID); XCTAssertFalse(subject.status.manualActive)
                subject.setAutomatic(false); subject.setAutomatic(true)
                XCTAssertFalse(subject.status.holding); XCTAssertEqual(subject.runtimeMarkers.protectionReason, "thermal")
                XCTAssertFalse(subject.setEnabled(true))
                for second in stride(from: 12, through: 62, by: 10) {
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                        now: base + Double(second), batteryPercent: 80)
                }
                XCTAssertTrue(subject.setEnabled(true))
                XCTAssertEqual(subject.workLease(now: base + 62)?.protectionResumeID, latch.id)
                XCTAssertFalse(subject.status.manualActive)
            }
        }
    }
    func testV3HelperCommandAcceptanceCannotClearUserSleepWithoutObservedOSSleep() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "v3-live")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.setAutomatic(true)
                let lease = try XCTUnwrap(subject.workLease(now: base))
                XCTAssertTrue(subject.pauseForUserSleep(now: base + 1))
                var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                bridge.lidEndReceipt = WorkSessionEndReceipt(bootID: "v3-live", sessionID: subject.sessionID,
                    sequence: lease.sequence, observedAt: base + 1, kind: .user, action: .sleepIfClosed)
                bridge.lidEndReceipt?.phase = .consumed
                bridge.lidEndReceipt?.outcome = "commandAccepted"
                subject.acceptBridge(bridge, protection: nil, now: base + 2)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 3)
                XCTAssertEqual(subject.runtimeMarkers.pauseReason, .userSleep)
                XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.workLease(now: base + 3)?.endConsumptionID, bridge.lidEndReceipt?.id)
                bridge.sleepConsumption = WorkSessionSleepConsumption(bootID: "v3-live",
                    sessionID: subject.sessionID, sequence: lease.sequence, observedAt: base + 4)
                subject.acceptBridge(bridge, protection: nil, now: base + 5)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 6)
                XCTAssertEqual(subject.runtimeMarkers.pauseReason, .userSleep)
                XCTAssertFalse(subject.status.automaticActive)
                XCTAssertFalse(subject.status.manualActive)
                XCTAssertTrue(subject.setEnabled(true)); XCTAssertTrue(subject.status.automaticActive)
            }
        }
    }
    func testV3PriorBootProtectionCanBeExplicitlyAcknowledgedWithoutImportingOldExecutionReceipts() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "new-boot")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: base, batteryPercent: 80)
                subject.setAllowClosedLid(true)
                XCTAssertFalse(subject.setManualBatteryContinuationMinutes(30, now: base))
                XCTAssertTrue(subject.start(duration: nil, now: base))
                let old = try XCTUnwrap(subject.workLease(now: base))
                var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                bridge.batteryPermitReceipt = WorkSessionBatteryPermitReceipt(bootID: "prior-boot",
                    sessionID: subject.sessionID, permitID: try XCTUnwrap(old.manualRequestID),
                    observedAt: base + 1, deadline: base + 1801)
                bridge.sleepConsumption = WorkSessionSleepConsumption(bootID: "prior-boot",
                    sessionID: subject.sessionID, sequence: old.sequence, observedAt: base + 1)
                bridge.lidEndReceipt = WorkSessionEndReceipt(bootID: "prior-boot", sessionID: subject.sessionID,
                    sequence: old.sequence, observedAt: base + 1, kind: .user, action: .sleepIfClosed)
                subject.acceptBridge(bridge, protection: nil, now: base + 2)
                XCTAssertTrue(subject.status.manualActive); XCTAssertNil(subject.status.manualContinuousDeadline)
                XCTAssertNil(subject.workLease(now: base + 2)?.endConsumptionID)
                XCTAssertNil(subject.workLease(now: base + 2)?.sleepConsumptionID)
                let latch = WorkSessionProtectionLatch(bootID: "prior-boot", reason: "thermal",
                    observedAt: base + 100_000, sessionID: UUID(), sequence: old.sequence)
                bridge.lidProtection = latch
                subject.acceptBridge(bridge, protection: nil, now: base + 3)
                XCTAssertEqual(subject.runtimeMarkers.protectionReason, "thermal")
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                XCTAssertNil(subject.workLease(now: base + 3)?.protectionResumeID)
                XCTAssertFalse(subject.setEnabled(true))
                for second in stride(from: 13, through: 63, by: 10) {
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                        now: base + Double(second), batteryPercent: 80)
                }
                XCTAssertTrue(subject.setEnabled(true))
                let resumed = try XCTUnwrap(subject.workLease(now: base + 63))
                XCTAssertEqual(resumed.protectionResumeID, latch.id)
                XCTAssertNil(resumed.endConsumptionID); XCTAssertNil(resumed.sleepConsumptionID)
                XCTAssertFalse(subject.status.manualActive)
            }
        }
    }
    func testV3KnownLegacyChoicesClampTo120AndPreserveOriginalOffAndProtection() async throws {
        try await MainActor.run {
            try withFixture { defaults, backend in
                var legacy = IdleSessionSettings()
                legacy.version = 4; legacy.enabled = false; legacy.automaticEnabled = true
                legacy.powerCondition = .any; legacy.automaticHoldMinutes = 240
                legacy.manualBatteryContinuationMinutes = 240; legacy.blockReason = "thermal"
                legacy.limits = UserLimits(batteryFloor: 30, maxHoldHours: 24)
                var oldBudget = ProtectionState(); oldBudget.restart(boot: "v3-live")
                oldBudget.prepareBatteryBudget(power: .battery, needed: true, clock: 10, boot: "v3-live")
                legacy.manualBatteryBudget = oldBudget; legacy.automaticBatteryBudget = oldBudget
                let raw = try JSONEncoder().encode(legacy)
                defaults.set(raw, forKey: UserSessionController.preferenceKey)
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "v3-live")
                defer { _ = subject.end() }
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
                XCTAssertEqual(subject.settings.version, IdleSessionSettings.currentVersion)
                XCTAssertEqual(subject.settings.condition, .ac)
                XCTAssertNil(subject.settings.manualBatteryContinuationMinutes)
                XCTAssertEqual(subject.settings.automaticMinutes, 120)
                XCTAssertFalse(subject.settings.automaticEnabled); XCTAssertFalse(subject.settings.enabled)
                XCTAssertEqual(subject.runtimeMarkers.pauseReason, .userStop)
                XCTAssertEqual(subject.runtimeMarkers.protectionReason, "thermal")
                XCTAssertEqual(subject.settings.limits?.batteryFloor, 30)
                XCTAssertNil(subject.settings.limits?.maxHoldHours)
                XCTAssertNil(subject.settings.manualBatteryBudget); XCTAssertNil(subject.settings.automaticBatteryBudget)
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey + ".migration.v4.backup"), raw)
            }
        }
    }
    func testV3FailedMarkerPersistenceCannotAcquireOrRenewNativeWork() async {
        await MainActor.run {
            withFixture { defaults, backend in
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "v3-live")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.persistenceProbe = { false }
                XCTAssertFalse(subject.start(duration: 180, now: base))
                XCTAssertEqual(backend.creates, 0); XCTAssertEqual(backend.renews, 0)
                XCTAssertFalse(subject.status.holding); XCTAssertNil(subject.workLease(now: base))
                XCTAssertNotNil(subject.status.error)
            }
        }
    }
    func testExplicitBatteryAutomaticAndManualClockChangesOnlyReprojectLabels() async throws {
        try await MainActor.run {
            for adjustment in [-3600.0, 3600.0] {
                try withFixture { defaults, backend in
                    let base = ContinuousTime.now
                    var wall = Date(timeIntervalSince1970: 10000)
                    let clocked = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil,
                        boot: "fixture", wallClock: { wall })
                    defer { _ = clocked.end() }
                    clocked.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                    selectAdvancedPowerFixture(clocked)
                    clocked.setPowerCondition(.battery); clocked.setAutomatic(true)
                    XCTAssertTrue(clocked.status.automaticActive)
                    let automaticDeadline = clocked.sessionDecision.automaticBatteryDeadline
                    XCTAssertEqual(try XCTUnwrap(automaticDeadline), base + 7200, accuracy: 0.001)
                    XCTAssertTrue(clocked.start(duration: 900, now: base))
                    let firstWall = wall
                    wall = firstWall.addingTimeInterval(60 + adjustment)
                    clocked.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 60, batteryPercent: 80)
                    XCTAssertEqual(clocked.status.manualContinuousDeadline, base + 900)
                    XCTAssertEqual(try XCTUnwrap(clocked.status.until).timeIntervalSince(wall), 840, accuracy: 0.001)
                    XCTAssertEqual(clocked.status.manualBatteryRemaining, 7140, accuracy: 0.001)
                    XCTAssertEqual(try XCTUnwrap(clocked.status.manualContinuousDeadline) - (base + 60), 840, accuracy: 0.001,
                                   "Selected manual time and remaining 120-minute battery ceiling are separate")
                    clocked.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 900, batteryPercent: 80)
                    XCTAssertFalse(clocked.status.manualActive); XCTAssertTrue(clocked.status.holding)
                    XCTAssertEqual(clocked.sessionDecision.automaticBatteryDeadline, automaticDeadline)
                }
            }
        }
    }

    func testV3SelectionOnlyAndWallClockEditsCannotStartOrLengthenManual() async {
        await MainActor.run {
            withFixture { defaults, backend in
                var wall = Date(timeIntervalSince1970: 1000)
                let subject = UserSessionController(defaults: defaults, backend: backend,
                    guiProbe: nil, environmentProbe: nil, boot: "v3-live", wallClock: { wall })
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: base, batteryPercent: 80)
                XCTAssertTrue(subject.selectManualDuration(180)); XCTAssertFalse(subject.status.manualActive)
                XCTAssertEqual(backend.creates, 0); XCTAssertTrue(subject.start(duration: 180, now: base))
                wall = wall.addingTimeInterval(-3600)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: base + 10, batteryPercent: 80)
                XCTAssertEqual(subject.status.manualContinuousDeadline, base + 180)
                XCTAssertTrue(subject.selectManualDuration(7200)); XCTAssertEqual(subject.status.manualContinuousDeadline, base + 180)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: base + 180, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
            }
        }
    }
}

@MainActor
private func selectAdvancedPowerFixture(_ controller: UserSessionController) {
    var settings = controller.settings.v4
    settings.automaticMode = .advanced
    let preset = V4Preset(id: UUID(), name: "Explicit advanced power fixture",
        groups: [.init(id: UUID(), conditions: [.init(id: UUID(), kind: .timeWindow,
            timeWindow: .init(startMinute: 0, endMinute: 0))])])
    settings.presets = [preset]; settings.activePresetID = preset.id
    XCTAssertTrue(controller.setV4Settings(settings))
}
