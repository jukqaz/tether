import Foundation
import XCTest
import TetherCore
@testable import Tether

/// No persistent preferences, native assertions, helper service, GUI observers,
/// run-loop waiting or OS Sleep. Only the controller's own Timer callback fires.
private final class ProtectionRecoveryAssertion: IdleAssertionBackend {
    private var nextID: UInt32 = 1
    private var active: Set<UInt32> = []

    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        let id = nextID
        nextID += 1
        active.insert(id)
        return (0, id)
    }

    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { active.contains(id) ? 0 : -1 }
    func level(id: UInt32) -> Int? { active.contains(id) ? 255 : 0 }
    func release(id: UInt32) -> Int32 { active.remove(id); return 0 }
}

@MainActor
private final class ProtectionRecoveryInputs {
    let origin = ContinuousTime.now
    var elapsed: Double = 0
    var power: PowerSource = .ac
    var thermal: Int? = 0
    var fullWake: Bool? = true
    var environmentReads = 0
    var now: Double { origin + elapsed }
    var wall: Date { Date(timeIntervalSince1970: 1_800_000_000 + elapsed) }
    func environment() -> UserSessionEnvironment {
        environmentReads += 1
        return .init(power: power, thermal: thermal, fullWake: fullWake, batteryPercent: 80)
    }
}

@MainActor
private final class ProtectionRecoveryFixture {
    let inputs = ProtectionRecoveryInputs()
    let controller: UserSessionController

    init(automatic: Bool, automaticallyResume: Bool = false, power: PowerSource = .ac) throws {
        let defaults = TestMemoryDefaults(domain: "ProtectionRecovery." + UUID().uuidString)
        var settings = IdleSessionSettings()
        settings.automaticEnabled = automatic
        settings.automaticallyResumeAfterProtection = automaticallyResume
        settings.legacyRootConfigurationPending = false
        if power == .battery {
            settings.automaticPowerCondition = .battery
            settings.batteryTimeLimit = .fourHours
            settings.disconnectPolicy = .continueEligible
            let condition = V4Condition(id: UUID(), kind: .timeWindow,
                timeWindow: .init(startMinute: 0, endMinute: 0))
            let preset = V4Preset(id: UUID(), name: "Recovery battery fixture", groups: [
                V4RuleGroup(id: UUID(), conditions: [condition])
            ])
            settings.v4.automaticMode = .advanced
            settings.v4.presets = [preset]
            settings.v4.activePresetID = preset.id
        }
        defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
        let inputs = self.inputs
        inputs.power = power
        let owner = GUISessionObservation(login: .init(uid: getuid(), sessionID: 100001), consoleUID: getuid())
        controller = UserSessionController(defaults: defaults, backend: ProtectionRecoveryAssertion(),
            displayBackend: ProtectionRecoveryAssertion(), guiProbe: { owner },
            environmentProbe: { inputs.environment() }, boot: "protection-recovery",
            wallClock: { inputs.wall }, continuousClock: { inputs.now })
        controller.refresh()
    }

    func observe(after seconds: Double, thermal: Int? = 0) {
        inputs.elapsed += seconds
        inputs.thermal = thermal
        controller.refresh()
    }

    /// Inspect the existing scheduled Timer without adding a production test seam.
    /// A non-nil fake GUI probe exercises the actual native scheduling branch.
    func scheduledObservation() throws -> Timer? {
        let storage = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "timer" },
            "The regression must inspect the real controller observation timer")
        guard let wrapped = Mirror(reflecting: storage.value).children.first else { return nil }
        return try XCTUnwrap(wrapped.value as? Timer)
    }

    func fireObservation(after seconds: Double = 5, thermal: Int? = 0) throws {
        let timer = try XCTUnwrap(scheduledObservation(),
            "Protection recovery must keep a scheduled observation even without automatic or manual work")
        XCTAssertTrue(timer.isValid)
        inputs.elapsed += seconds
        inputs.thermal = thermal
        let reads = inputs.environmentReads
        timer.fire()
        timer.invalidate()
        XCTAssertGreaterThan(inputs.environmentReads, reads,
                             "The scheduled callback must query the injected environment")
    }

    func protectionBridge() throws -> WorkSessionBridge {
        let lease = try XCTUnwrap(controller.workLease(now: inputs.now))
        var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
        bridge.lidProtection = WorkSessionProtectionLatch(bootID: "protection-recovery",
            reason: "thermal", observedAt: inputs.now, sessionID: controller.sessionID, sequence: lease.sequence)
        return bridge
    }

    func accept(_ bridge: WorkSessionBridge, status: ProtectionStatus? = nil) {
        controller.acceptBridge(bridge, protection: status, now: inputs.now)
    }

    func startAndProtectManual() throws {
        XCTAssertTrue(controller.start(duration: 600, now: inputs.now))
        observe(after: 1, thermal: 3)
        XCTAssertEqual(controller.status.blockReason, "thermal")
        XCTAssertFalse(controller.status.manualActive)
        XCTAssertFalse(controller.status.holding)
        observe(after: 1)
    }
}

@MainActor
final class ProtectionRecoveryTests: XCTestCase {
    private enum ProtectionSource { case helperLatch, legacyBudgets, status }

    func testSameHelperLatchAfterAutomaticRecoveryPreservesNewWorkAndBatteryCap() throws {
        try verifyConsumedProtectionReplay(source: .helperLatch)
    }

    func testSameLegacyBudgetsAfterAutomaticRecoveryPreserveNewWorkAndBatteryCap() throws {
        try verifyConsumedProtectionReplay(source: .legacyBudgets)
    }

    func testSameStatusAfterAutomaticRecoveryPreservesNewWorkAndBatteryCap() throws {
        try verifyConsumedProtectionReplay(source: .status)
    }

    private func verifyConsumedProtectionReplay(source: ProtectionSource) throws {
        let fixture = try ProtectionRecoveryFixture(automatic: true, automaticallyResume: true, power: .battery)
        let controller = fixture.controller
        defer { _ = controller.end() }
        let originalCap = try XCTUnwrap(controller.workLease(now: fixture.inputs.now)?.automaticBatteryDeadline)
        var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
        var status: ProtectionStatus?
        switch source {
        case .helperLatch: bridge = try fixture.protectionBridge()
        case .legacyBudgets:
            var automatic = ProtectionState(), manual = ProtectionState()
            automatic.block("thermal")
            manual.block("battery")
            bridge.automaticBudget = automatic
            bridge.manualBudget = manual
        case .status: status = ProtectionStatus(reason: "thermal", error: nil, dryRun: true)
        }
        fixture.accept(bridge, status: status)
        for sample in 1...12 {
            try fixture.fireObservation()
            XCTAssertEqual(controller.runtimeMarkers.protectionReason == nil, sample == 12)
            XCTAssertEqual(controller.workLease(now: fixture.inputs.now)?.protectionResumeID,
                           sample == 12 ? bridge.lidProtection?.id : nil)
        }
        XCTAssertNil(controller.runtimeMarkers.protectionReason)
        // Advanced conditions are evaluated before the policy clears protection.
        // The next scheduled observation evaluates the now-healthy rule gate.
        try fixture.fireObservation()
        XCTAssertTrue(controller.status.automaticActive)
        let recovered = try XCTUnwrap(controller.workLease(now: fixture.inputs.now))
        let automaticID = try XCTUnwrap(recovered.automaticRequestID)
        XCTAssertEqual(recovered.protectionResumeID, bridge.lidProtection?.id)
        XCTAssertEqual(recovered.automaticBatteryDeadline, originalCap)

        XCTAssertTrue(controller.start(duration: 600, now: fixture.inputs.now))
        let manualID = try XCTUnwrap(controller.manualRequestID)
        let manualDeadline = try XCTUnwrap(controller.status.manualContinuousDeadline)
        fixture.accept(bridge, status: status)
        let replayed = try XCTUnwrap(controller.workLease(now: fixture.inputs.now))
        XCTAssertEqual(controller.manualRequestID, manualID,
                       "A consumed protection incident must not terminate newly approved manual work")
        XCTAssertEqual(controller.status.manualContinuousDeadline, manualDeadline)
        XCTAssertEqual(replayed.automaticRequestID, automaticID,
                       "Re-delivery of a recovered incident must not replace automatic execution")
        XCTAssertEqual(replayed.automaticBatteryDeadline, originalCap)

        if source == .legacyBudgets {
            bridge.manualBudget = nil
            fixture.accept(bridge)
            let partiallyCleared = try XCTUnwrap(controller.workLease(now: fixture.inputs.now))
            XCTAssertEqual(controller.manualRequestID, manualID,
                           "Clearing one legacy cause must not turn an unchanged old cause into a new incident")
            XCTAssertEqual(controller.status.manualContinuousDeadline, manualDeadline)
            XCTAssertEqual(partiallyCleared.automaticRequestID, automaticID)
            XCTAssertEqual(partiallyCleared.automaticBatteryDeadline, originalCap)
        }

        if source == .helperLatch {
            fixture.accept(.init(coordinated: true, automaticBudget: .init(), manualBudget: nil))
            XCTAssertNil(controller.workLease(now: fixture.inputs.now)?.protectionResumeID,
                         "A confirmed latch removal retires the outgoing acknowledgement")
            bridge.lidProtection?.id = UUID()
            bridge.lidProtection?.observedAt = fixture.inputs.now
            fixture.accept(bridge)
        } else {
            try fixture.fireObservation(thermal: 3)
            try fixture.fireObservation()
        }
        XCTAssertFalse(controller.status.manualActive)
        XCTAssertFalse(controller.status.automaticActive)
        XCTAssertNotNil(controller.runtimeMarkers.protectionReason)
        for sample in 1...12 {
            try fixture.fireObservation()
            XCTAssertEqual(controller.runtimeMarkers.protectionReason == nil, sample == 12,
                           "A new incident or recurring live hazard still requires 60 healthy seconds")
            XCTAssertFalse(controller.status.manualActive)
            XCTAssertEqual(controller.workLease(now: fixture.inputs.now)?.protectionResumeID,
                           sample == 12 ? bridge.lidProtection?.id : nil)
        }
        try fixture.fireObservation()
        XCTAssertTrue(controller.status.automaticActive)
        XCTAssertEqual(controller.workLease(now: fixture.inputs.now)?.automaticBatteryDeadline, originalCap)
    }

    func testAutomaticRecoveryCannotAcknowledgeHelperWhileUserStopped() throws {
        let fixture = try ProtectionRecoveryFixture(automatic: true, automaticallyResume: true)
        let controller = fixture.controller
        defer { _ = controller.end() }
        XCTAssertTrue(controller.start(duration: 600, now: fixture.inputs.now))
        let bridge = try fixture.protectionBridge()
        fixture.accept(bridge)
        for _ in 0..<6 { try fixture.fireObservation() }
        XCTAssertTrue(controller.setEnabled(false))
        for _ in 0..<12 { try fixture.fireObservation() }
        let stopped = try XCTUnwrap(controller.workLease(now: fixture.inputs.now))
        XCTAssertFalse(stopped.configuration.enabled)
        XCTAssertTrue(stopped.reasons.isEmpty)
        XCTAssertNil(stopped.protectionResumeID)
        XCTAssertEqual(controller.runtimeMarkers.protectionReason, "thermal")
        XCTAssertTrue(controller.setEnabled(true))
        let resumed = try XCTUnwrap(controller.workLease(now: fixture.inputs.now))
        XCTAssertEqual(resumed.protectionResumeID, bridge.lidProtection?.id)
        XCTAssertEqual(resumed.reasons, [.automatic])
        XCTAssertNil(controller.manualRequestID)
    }

    func testAutomaticRecoveryCannotAcknowledgeHelperWithoutWakeOrDurableConfirmation() throws {
        let fixture = try ProtectionRecoveryFixture(automatic: true, automaticallyResume: true)
        let controller = fixture.controller
        defer { _ = controller.end() }
        let bridge = try fixture.protectionBridge()
        fixture.accept(bridge)
        for _ in 0..<11 { try fixture.fireObservation() }
        fixture.inputs.fullWake = nil
        try fixture.fireObservation()
        XCTAssertEqual(controller.status.blockReason, "thermal")
        XCTAssertNil(controller.workLease(now: fixture.inputs.now)?.protectionResumeID)

        fixture.inputs.fullWake = true
        controller.persistenceProbe = { false }
        try fixture.fireObservation()
        XCTAssertFalse(controller.status.holding)
        XCTAssertNotNil(controller.status.error)
        XCTAssertNil(controller.workLease(now: fixture.inputs.now),
                     "Rejected durable recovery cannot send any helper lease")
    }

    func testExhaustedLegacyBatteryAllowanceNeedsStableACEvenWithAnotherProtectionCause() throws {
        for exhaustedReason in ["time", "budget"] {
            let fixture = try ProtectionRecoveryFixture(automatic: true, automaticallyResume: true, power: .battery)
            let controller = fixture.controller
            defer { _ = controller.end() }
            XCTAssertTrue(controller.status.automaticActive)
            var bridge = try fixture.protectionBridge()
            bridge.automaticBudget.block(exhaustedReason)
            fixture.accept(bridge)
            for sample in 1...13 {
                try fixture.fireObservation()
                if sample.isMultiple(of: 3) { fixture.accept(bridge) }
                XCTAssertEqual(controller.status.blockReason, exhaustedReason)
                XCTAssertFalse(controller.status.holding)
                XCTAssertFalse(controller.canResume)
                XCTAssertNil(controller.workLease(now: fixture.inputs.now)?.protectionResumeID)
            }
            fixture.inputs.power = .ac
            try fixture.fireObservation()
            for sample in 1...12 {
                try fixture.fireObservation()
                XCTAssertEqual(controller.status.blockReason == nil, sample == 12)
                XCTAssertEqual(controller.workLease(now: fixture.inputs.now)?.protectionResumeID,
                               sample == 12 ? bridge.lidProtection?.id : nil)
            }
            XCTAssertFalse(controller.status.automaticActive, "The saved battery-only trigger does not match AC")
            XCTAssertNil(controller.manualRequestID)
        }
    }

    func testManualOnlyProtectionKeepsRecoveryObservationScheduled() throws {
        let fixture = try ProtectionRecoveryFixture(automatic: false)
        let controller = fixture.controller
        defer { _ = controller.end() }
        try fixture.startAndProtectManual()
        XCTAssertFalse(controller.status.automaticEnabled)
        XCTAssertNotNil(try fixture.scheduledObservation())
        for sample in 1...12 {
            try fixture.fireObservation()
            XCTAssertEqual(controller.canResume, sample == 12,
                           "Resume requires the complete 60-second healthy window")
        }
        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertFalse(controller.status.manualActive)
        XCTAssertNil(controller.manualRequestID)
        XCTAssertFalse(controller.status.holding, "Explicit Resume must not revive ended manual work")
        XCTAssertNil(try fixture.scheduledObservation(), "Idle manual-only work needs no recovery polling after Resume")
    }

    func testRepeatedSameHelperProtectionLatchDoesNotRestartHealthyRecoveryWindow() throws {
        let control = try ProtectionRecoveryFixture(automatic: true)
        let repeated = try ProtectionRecoveryFixture(automatic: true)
        defer { _ = control.controller.end(); _ = repeated.controller.end() }
        XCTAssertTrue(repeated.controller.start(duration: 600, now: repeated.inputs.now))
        let controlBridge = try control.protectionBridge()
        let repeatedBridge = try repeated.protectionBridge()
        control.accept(controlBridge)
        repeated.accept(repeatedBridge)

        for sample in 1...12 {
            try control.fireObservation()
            try repeated.fireObservation()
            if sample.isMultiple(of: 3) { repeated.accept(repeatedBridge) }
            XCTAssertEqual(repeated.controller.canResume, sample == 12)
        }
        XCTAssertTrue(control.controller.canResume)
        XCTAssertTrue(repeated.controller.canResume)
        XCTAssertEqual(repeated.controller.runtimeMarkers.protectionReason, "thermal")
        XCTAssertTrue(repeated.controller.setEnabled(true))
        XCTAssertEqual(repeated.controller.workLease(now: repeated.inputs.now)?.protectionResumeID,
                       repeatedBridge.lidProtection?.id)
        XCTAssertTrue(repeated.controller.status.automaticActive)
        XCTAssertFalse(repeated.controller.status.manualActive)
        XCTAssertNil(repeated.controller.manualRequestID)
    }

    func testNewHelperLatchWithSameReasonRestartsRecoveryWindow() throws {
        let fixture = try ProtectionRecoveryFixture(automatic: true)
        defer { _ = fixture.controller.end() }
        var bridge = try fixture.protectionBridge()
        fixture.accept(bridge)
        for _ in 0..<6 { try fixture.fireObservation() }
        bridge.lidProtection?.id = UUID()
        bridge.lidProtection?.observedAt = fixture.inputs.now
        fixture.accept(bridge)
        for sample in 1...12 {
            try fixture.fireObservation()
            XCTAssertEqual(fixture.controller.canResume, sample == 12,
                           "A different helper incident must require its own complete safe window")
        }
    }

    func testRepeatedLegacyAndStatusProtectionPreservesRecoveryButChangedEvidenceResetsIt() throws {
        let fixture = try ProtectionRecoveryFixture(automatic: true)
        defer { _ = fixture.controller.end() }
        var automatic = ProtectionState(), manual = ProtectionState()
        automatic.block("thermal")
        manual.block("battery")
        var bridge = WorkSessionBridge(coordinated: true, automaticBudget: automatic, manualBudget: manual)
        let status = ProtectionStatus(reason: "sensor", error: nil, dryRun: true)
        fixture.accept(bridge, status: status)
        for sample in 1...12 {
            try fixture.fireObservation()
            if sample.isMultiple(of: 3) { fixture.accept(bridge, status: status) }
            XCTAssertEqual(fixture.controller.canResume, sample == 12)
        }

        var changedManual = ProtectionState()
        changedManual.block("time")
        bridge.manualBudget = changedManual
        fixture.accept(bridge, status: status)
        XCTAssertFalse(fixture.controller.canResume, "A new imported cause must reset even while the original cause stays latched")
        fixture.observe(after: 0)
        for sample in 1...12 {
            try fixture.fireObservation()
            XCTAssertEqual(fixture.controller.canResume, sample == 12)
        }
    }

    func testNewThermalRiseRequiresSixtyHealthySecondsAgain() throws {
        let fixture = try ProtectionRecoveryFixture(automatic: false)
        defer { _ = fixture.controller.end() }
        try fixture.startAndProtectManual()
        for _ in 0..<6 { try fixture.fireObservation() }
        try fixture.fireObservation(thermal: 3)
        XCTAssertFalse(fixture.controller.canResume)
        try fixture.fireObservation()
        for sample in 1...12 {
            try fixture.fireObservation()
            XCTAssertEqual(fixture.controller.canResume, sample == 12,
                           "A real recurring hazard must reset recovery even when the durable reason is unchanged")
        }
        XCTAssertFalse(fixture.controller.status.manualActive)
    }

    func testObservationGapAndUnknownThermalRestartRecoveryWindow() throws {
        for interruptedByUnknown in [false, true] {
            let fixture = try ProtectionRecoveryFixture(automatic: false)
            defer { _ = fixture.controller.end() }
            try fixture.startAndProtectManual()
            for _ in 0..<6 { try fixture.fireObservation() }
            if interruptedByUnknown {
                try fixture.fireObservation(thermal: nil)
                try fixture.fireObservation()
            } else {
                try fixture.fireObservation(after: 16)
            }
            for sample in 1...12 {
                try fixture.fireObservation()
                XCTAssertEqual(fixture.controller.canResume, sample == 12,
                               "Recovery must start over after an unavailable sample or a gap longer than 15 seconds")
            }
            XCTAssertFalse(fixture.controller.status.manualActive)
        }
    }
}
