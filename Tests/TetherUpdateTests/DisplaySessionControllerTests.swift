import Darwin
import Foundation
import XCTest
@testable import Tether
import TetherCore

private final class DisplaySessionAssertionFixture: IdleAssertionBackend {
    let id: UInt32
    var createCode: Int32 = 0
    var releaseCode: Int32 = 0
    var levelValue: Int? = 255
    var created: [TimeInterval] = []
    var renewed: [TimeInterval] = []
    var released: [UInt32] = []

    init(id: UInt32) { self.id = id }
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        created.append(timeout)
        return (createCode, createCode == 0 ? id : nil)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { renewed.append(timeout); return 0 }
    func level(id: UInt32) -> Int? { levelValue }
    func release(id: UInt32) -> Int32 { released.append(id); return releaseCode }
}

final class DisplaySessionControllerTests: XCTestCase {
    func testDefaultManualAndAutomaticWorkNeverAcquireDisplayAssertion() async {
        await MainActor.run {
            for automatic in [false, true] {
                withFixture { defaults, system, display in
                    let subject = controller(defaults, system, display)
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                    if automatic { subject.setAutomatic(true) }
                    else { XCTAssertTrue(subject.start(duration: 30, now: base)) }
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 1)

                    XCTAssertTrue(subject.status.holding)
                    XCTAssertEqual(subject.status.keepDisplayAwake, false)
                    XCTAssertEqual(subject.status.displayHolding, false)
                    XCTAssertNil(subject.status.displayError)
                    XCTAssertEqual(system.created.count, 1)
                    XCTAssertTrue(display.created.isEmpty)
                    XCTAssertTrue(display.renewed.isEmpty)
                }
            }
        }
    }

    func testOptInIsSavedWithoutStartingWorkOrRestoringATemporarySession() async throws {
        try await MainActor.run {
            try withFixture { defaults, system, display in
                let subject = controller(defaults, system, display)
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.setKeepDisplayAwake(true)
                XCTAssertTrue(subject.settings.keepDisplayAwake)
                XCTAssertEqual(subject.status.keepDisplayAwake, true)
                XCTAssertFalse(subject.status.holding)
                XCTAssertTrue(system.created.isEmpty)
                XCTAssertTrue(display.created.isEmpty)
                let saved = try JSONDecoder().decode(IdleSessionSettings.self,
                    from: XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey)))
                XCTAssertTrue(saved.keepDisplayAwake)
                XCTAssertTrue(subject.start(duration: 30, now: base))
                XCTAssertTrue(subject.end())

                let restartedSystem = DisplaySessionAssertionFixture(id: 29)
                let restartedDisplay = DisplaySessionAssertionFixture(id: 39)
                let restarted = controller(defaults, restartedSystem, restartedDisplay)
                defer { _ = restarted.end() }
                restarted.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 1)
                XCTAssertTrue(restarted.settings.keepDisplayAwake)
                XCTAssertFalse(restarted.status.manualActive)
                XCTAssertEqual(restarted.status.displayHolding, false)
                XCTAssertTrue(restartedSystem.created.isEmpty)
                XCTAssertTrue(restartedDisplay.created.isEmpty)
            }
        }
    }

    func testOptedInManualAndAutomaticDisplayRequestsShareFiniteWorkLease() async throws {
        try await MainActor.run {
            for automatic in [false, true] {
                try withFixture { defaults, system, display in
                    let subject = controller(defaults, system, display)
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                    subject.setKeepDisplayAwake(true)
                    if automatic { subject.setAutomatic(true) }
                    else { XCTAssertTrue(subject.start(duration: 20, now: base)) }

                    XCTAssertTrue(subject.status.holding)
                    XCTAssertEqual(subject.status.displayHolding, true)
                    XCTAssertNil(subject.status.error)
                    XCTAssertNil(subject.status.displayError)
                    let workTimeout = try XCTUnwrap(system.created.first)
                    let displayTimeout = try XCTUnwrap(display.created.first)
                    XCTAssertGreaterThanOrEqual(displayTimeout, 1)
                    XCTAssertLessThanOrEqual(displayTimeout, IdleSessionPolicy.healthTTL)
                    XCTAssertLessThanOrEqual(displayTimeout, workTimeout)
                    XCTAssertEqual(subject.workLease(now: base)?.reasons, automatic ? [.automatic] : [.manual])
                }
            }
        }
    }

    func testTurningDisplayOptionOffReleasesOnlyDisplayAndKeepsOriginalManualDeadline() async {
        await MainActor.run {
            withFixture { defaults, system, display in
                let subject = controller(defaults, system, display)
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.setKeepDisplayAwake(true)
                XCTAssertTrue(subject.start(duration: 30, now: base))
                let deadline = subject.status.manualContinuousDeadline
                subject.setKeepDisplayAwake(false)

                XCTAssertTrue(subject.status.holding)
                XCTAssertTrue(subject.status.manualActive)
                XCTAssertEqual(subject.status.manualContinuousDeadline, deadline)
                XCTAssertEqual(subject.status.keepDisplayAwake, false)
                XCTAssertEqual(subject.status.displayHolding, false)
                XCTAssertNil(subject.status.displayError)
                XCTAssertEqual(system.created.count, 1)
                XCTAssertTrue(system.released.isEmpty)
                XCTAssertEqual(display.released, [display.id])
                XCTAssertEqual(subject.workLease(now: base)?.reasons, [.manual])
            }
        }
    }

    func testACAutomaticDisplayRequestEndsOnUnplugWithoutBatteryPermission() async {
        await MainActor.run {
            withFixture { defaults, system, display in
                let subject = controller(defaults, system, display)
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                subject.setKeepDisplayAwake(true)
                subject.setAutomatic(true)
                XCTAssertEqual(subject.status.displayHolding, true)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: base + 1, batteryPercent: 80)

                XCTAssertFalse(subject.status.automaticActive)
                XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.status.displayHolding, false)
                XCTAssertEqual(system.released, [system.id])
                XCTAssertEqual(display.released, [display.id])
            }
        }
    }

    func testUnplugEndsBothManualDisplayAndGeneralWithoutContinuation() async throws {
        try await MainActor.run {
            try withFixture { defaults, system, display in
                let subject = controller(defaults, system, display)
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base, batteryPercent: 80)
                subject.setKeepDisplayAwake(true)
                XCTAssertFalse(subject.setManualBatteryContinuationMinutes(1, now: base))
                XCTAssertTrue(subject.start(duration: nil, now: base))
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: base + 1, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive); XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.status.displayHolding, false)
                XCTAssertEqual(subject.status.manualEndReason, .powerDisconnected)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 2, batteryPercent: 80)
                XCTAssertFalse(subject.status.manualActive); XCTAssertNil(subject.status.manualContinuousDeadline)
                XCTAssertEqual(system.released, [system.id]); XCTAssertEqual(display.released, [display.id])
                XCTAssertEqual(display.created.count, 1)
            }
        }
    }

    func testManualTimeoutReleasesBothRequestsAndKeepsDisplayChoice() async {
        await MainActor.run {
            withFixture { defaults, system, display in
                let subject = controller(defaults, system, display)
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.setKeepDisplayAwake(true)
                XCTAssertTrue(subject.start(duration: 3, now: base))
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 3)

                XCTAssertFalse(subject.status.holding)
                XCTAssertFalse(subject.status.manualActive)
                XCTAssertTrue(subject.settings.keepDisplayAwake)
                XCTAssertEqual(subject.status.displayHolding, false)
                XCTAssertEqual(system.released, [system.id])
                XCTAssertEqual(display.released, [display.id])
            }
        }
    }

    func testSystemSleepReleasesDisplayAndCannotReplayManualAfterWake() async {
        await MainActor.run {
            withFixture { defaults, system, display in
                let subject = controller(defaults, system, display)
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.setKeepDisplayAwake(true)
                XCTAssertTrue(subject.start(duration: 30, now: base))
                subject.observeSystemSleep(observedAt: base + 1)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 2)

                XCTAssertFalse(subject.status.manualActive)
                XCTAssertEqual(subject.status.displayHolding, false)
                XCTAssertEqual(system.released, [system.id])
                XCTAssertEqual(display.released, [display.id])
                XCTAssertEqual(system.created.count, 1)
                XCTAssertEqual(display.created.count, 1)
            }
        }
    }

    func testExplicitStopsReleaseDisplayWithoutRestartingTemporaryWork() async {
        await MainActor.run {
            for action in ["manual", "current", "off", "automatic"] {
                withFixture { defaults, system, display in
                    let subject = controller(defaults, system, display)
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                    subject.setKeepDisplayAwake(true)
                    if action == "automatic" { subject.setAutomatic(true) }
                    else { XCTAssertTrue(subject.start(duration: 30, now: base)) }
                    switch action {
                    case "manual": subject.endManual()
                    case "current": subject.stopCurrent()
                    case "off": XCTAssertTrue(subject.setEnabled(false))
                    default: subject.setAutomatic(false)
                    }
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 1)

                    XCTAssertFalse(subject.status.holding, action)
                    XCTAssertEqual(subject.status.displayHolding, false, action)
                    XCTAssertEqual(system.released, [system.id], action)
                    XCTAssertEqual(display.released, [display.id], action)
                    XCTAssertEqual(display.created.count, 1, action)
                }
            }
        }
    }

    func testThermalAndBatteryFloorProtectionReleaseBothRequests() async {
        await MainActor.run {
            for reason in ["thermal", "battery"] {
                withFixture { defaults, system, display in
                    let subject = controller(defaults, system, display)
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    let power: PowerSource = reason == "thermal" ? .ac : .battery
                    subject.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
                        now: base, batteryPercent: 80)
                    subject.setKeepDisplayAwake(true)
                    subject.setLimits(UserLimits(batteryFloor: 40))
                    XCTAssertTrue(subject.start(duration: power == .battery ? 60 : 30, now: base))
                    subject.update(power: power, thermal: reason == "thermal" ? 2 : 0, fullWake: true,
                        controllingUser: true, now: base + 1, batteryPercent: reason == "battery" ? 39 : 80)

                    XCTAssertEqual(subject.status.blockReason, reason)
                    XCTAssertFalse(subject.status.holding)
                    XCTAssertEqual(subject.status.displayHolding, false)
                    XCTAssertEqual(system.released, [system.id])
                    XCTAssertEqual(display.released, [display.id])
                }
            }
        }
    }

    func testCoordinatorOwnershipLossReleasesBothRequests() async {
        await MainActor.run {
            withFixture { defaults, system, display in
                let subject = controller(defaults, system, display)
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.setKeepDisplayAwake(true)
                XCTAssertTrue(subject.start(duration: 30, now: base))
                subject.ownershipProbe = { false }
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 1)

                XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.status.displayHolding, false)
                XCTAssertEqual(system.released, [system.id])
                XCTAssertEqual(display.released, [display.id])
                XCTAssertNotNil(subject.status.error)
            }
        }
    }

    func testFailedPersistenceCannotAcquireOrKeepDisplayWork() async {
        await MainActor.run {
            for alreadyActive in [false, true] {
                withFixture { defaults, system, display in
                    let subject = controller(defaults, system, display)
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                    subject.setKeepDisplayAwake(true)
                    if alreadyActive { XCTAssertTrue(subject.start(duration: 30, now: base)) }
                    subject.persistenceProbe = { false }
                    if alreadyActive { subject.setKeepDisplayAwake(false) }
                    else { XCTAssertFalse(subject.start(duration: 30, now: base)) }

                    XCTAssertFalse(subject.status.holding)
                    XCTAssertEqual(subject.status.displayHolding, false)
                    XCTAssertNotNil(subject.status.error)
                    XCTAssertEqual(system.created.count, alreadyActive ? 1 : 0)
                    XCTAssertEqual(display.created.count, alreadyActive ? 1 : 0)
                    XCTAssertEqual(display.released, alreadyActive ? [display.id] : [])
                }
            }
        }
    }

    func testFailedRequiredDisplayRejectsTheNewManualAndReleasesItsOwnGeneralRequest() async {
        await MainActor.run {
            for creationFails in [false, true] {
                withFixture { defaults, system, display in
                    let subject = controller(defaults, system, display)
                    defer { _ = subject.end() }
                    let base = ContinuousTime.now
                    subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                    subject.setKeepDisplayAwake(true)
                    if creationFails { display.createCode = -5 }
                    else { display.levelValue = nil }
                    XCTAssertFalse(subject.start(duration: 30, now: base))
                    XCTAssertFalse(subject.status.holding); XCTAssertFalse(subject.status.manualActive)
                    XCTAssertEqual(subject.status.displayHolding, false)
                    XCTAssertEqual(subject.workLease(now: base)?.reasons, [])
                    XCTAssertEqual(system.released, [system.id])
                }
            }
        }
    }

    func testUnconfirmedSystemCreationNeverAuthorizesDisplayAcquisition() async {
        await MainActor.run {
            withFixture { defaults, system, display in
                let subject = controller(defaults, system, display)
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.setKeepDisplayAwake(true)
                system.levelValue = nil
                XCTAssertFalse(subject.start(duration: 30, now: base))

                XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.status.displayHolding, false)
                XCTAssertTrue(display.created.isEmpty)
                XCTAssertFalse(subject.status.manualActive)
                let inactive = subject.workLease(now: base)
                XCTAssertEqual(inactive?.reasons, [])
                XCTAssertNil(inactive?.expiry)
                XCTAssertNil(inactive?.lidPermit)
            }
        }
    }

    func testSystemObservationGapCannotRenewDisplayPastOriginalConfirmedDeadline() async {
        await MainActor.run {
            withFixture { defaults, system, display in
                let subject = controller(defaults, system, display)
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.setKeepDisplayAwake(true)
                XCTAssertTrue(subject.start(duration: nil, now: base))
                let systemRenewals = system.renewed.count
                let displayRenewals = display.renewed.count
                system.levelValue = nil
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 10)

                XCTAssertEqual(system.renewed.count, systemRenewals)
                XCTAssertEqual(display.renewed.count, displayRenewals)
                XCTAssertEqual(display.created.count, 1)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: base + IdleSessionPolicy.healthTTL)
                XCTAssertEqual(subject.status.displayHolding, false)
                XCTAssertEqual(display.released, [display.id])
                XCTAssertEqual(display.created.count, 1)
            }
        }
    }

    func testGUIObservationGapDoesNotRenewEitherRequestAndReleasesAtAuthorityDeadline() async {
        await MainActor.run {
            withFixture { defaults, system, display in
                let login = GUISessionIdentity(uid: getuid(), sessionID: 100001)
                var observed = GUISessionObservation(login: login, consoleUID: login.uid)
                let subject = UserSessionController(defaults: defaults, backend: system, displayBackend: display,
                    guiProbe: { observed }, environmentProbe: nil, boot: "display-fixture")
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: observed, now: base)
                subject.setKeepDisplayAwake(true)
                let started = ContinuousTime.now
                XCTAssertTrue(subject.start(duration: nil, now: started))
                let systemRenewals = system.renewed.count
                let displayRenewals = display.renewed.count
                observed = GUISessionObservation(login: nil, consoleUID: nil)
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: observed, now: started + 1)

                XCTAssertFalse(subject.status.canStart)
                XCTAssertEqual(system.renewed.count, systemRenewals)
                XCTAssertEqual(display.renewed.count, displayRenewals)
                subject.update(power: .ac, thermal: 0, fullWake: true, gui: observed, now: started + 30)
                XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.status.displayHolding, false)
                XCTAssertEqual(system.released, [system.id])
                XCTAssertEqual(display.released, [display.id])
                XCTAssertEqual(display.created.count, 1)
            }
        }
    }

    func testShortenedBatteryReceiptDuringGUIObservationGapReleasesWithoutRenewing() async throws {
        try await MainActor.run {
            try withFixture { defaults, system, display in
                let login = GUISessionIdentity(uid: getuid(), sessionID: 100001)
                var observed = GUISessionObservation(login: login, consoleUID: login.uid)
                let subject = UserSessionController(defaults: defaults, backend: system, displayBackend: display,
                    guiProbe: { observed }, environmentProbe: nil, boot: "display-fixture")
                defer { _ = subject.end() }
                subject.update(power: .battery, thermal: 0, fullWake: true, gui: observed,
                    now: ContinuousTime.now, batteryPercent: 80)
                subject.setKeepDisplayAwake(true)
                subject.setAllowClosedLid(true)
                let started = ContinuousTime.now
                XCTAssertTrue(subject.start(duration: 600, now: started))
                let permit = try XCTUnwrap(subject.workLease(now: started)?.lidPermit?.batteryPermitID)
                let systemRenewals = system.renewed.count
                let displayRenewals = display.renewed.count
                observed = GUISessionObservation(login: nil, consoleUID: nil)
                subject.update(power: .battery, thermal: 0, fullWake: true, gui: observed,
                    now: started + 1, batteryPercent: 80)
                var bridge = WorkSessionBridge(coordinated: true, automaticBudget: .init(), manualBudget: nil)
                bridge.batteryPermitReceipt = WorkSessionBatteryPermitReceipt(bootID: "display-fixture",
                    sessionID: subject.sessionID, permitID: permit, observedAt: started + 1, deadline: started + 10)
                subject.acceptBridge(bridge, protection: nil, now: started + 2)

                XCTAssertEqual(subject.status.manualContinuousDeadline, started + 10)
                XCTAssertTrue(subject.status.manualActive)
                XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.status.displayHolding, false)
                XCTAssertEqual(system.renewed.count, systemRenewals)
                XCTAssertEqual(display.renewed.count, displayRenewals)
                XCTAssertEqual(system.released, [system.id])
                XCTAssertEqual(display.released, [display.id])
                XCTAssertEqual(system.created.count, 1)
                XCTAssertEqual(display.created.count, 1)
            }
        }
    }

    func testFailedDisplayReleaseIsSeparateAndRetriesSameAllocationWhileSystemContinues() async {
        await MainActor.run {
            withFixture { defaults, system, display in
                let subject = controller(defaults, system, display)
                defer { _ = subject.end() }
                let base = ContinuousTime.now
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                subject.setKeepDisplayAwake(true)
                XCTAssertTrue(subject.start(duration: 30, now: base))
                display.releaseCode = -7
                subject.setKeepDisplayAwake(false)

                XCTAssertTrue(subject.status.holding)
                XCTAssertEqual(subject.status.displayHolding, false)
                XCTAssertNotNil(subject.status.displayError)
                XCTAssertNil(subject.status.error)
                XCTAssertEqual(subject.workLease(now: base)?.reasons, [.manual])
                display.releaseCode = 0
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base + 1)
                XCTAssertTrue(subject.status.holding)
                XCTAssertNil(subject.status.displayError)
                XCTAssertEqual(display.created.count, 1)
                XCTAssertEqual(display.released, [display.id, display.id])
                XCTAssertTrue(system.released.isEmpty)
            }
        }
    }

    func testQuitAndUserSleepRequireReleaseOfBothExecutorsAndCanRetry() async {
        await MainActor.run {
            for sleep in [false, true] {
                for failedDisplay in [false, true] {
                    withFixture { defaults, system, display in
                        let subject = controller(defaults, system, display)
                        defer { _ = subject.end() }
                        let base = ContinuousTime.now
                        subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: base)
                        subject.setKeepDisplayAwake(true)
                        XCTAssertTrue(subject.start(duration: 30, now: base))
                        let failing = failedDisplay ? display : system
                        failing.releaseCode = -7

                        XCTAssertFalse(sleep ? subject.pauseForUserSleep(now: base + 1) : subject.end())
                        XCTAssertEqual(system.released, [system.id])
                        XCTAssertEqual(display.released, [display.id])
                        failing.releaseCode = 0
                        XCTAssertTrue(sleep ? subject.pauseForUserSleep(now: base + 2) : subject.end())
                        XCTAssertEqual(failing.released, [failing.id, failing.id])
                        XCTAssertEqual(system.created.count, 1)
                        XCTAssertEqual(display.created.count, 1)
                        XCTAssertEqual(subject.status.displayHolding, false)
                    }
                }
            }
        }
    }

    @MainActor
    private func controller(_ defaults: UserDefaults, _ system: DisplaySessionAssertionFixture,
                            _ display: DisplaySessionAssertionFixture) -> UserSessionController {
        UserSessionController(defaults: defaults, backend: system, displayBackend: display,
            guiProbe: nil, environmentProbe: nil, boot: "display-fixture")
    }

    @MainActor
    private func withFixture(_ body: (UserDefaults, DisplaySessionAssertionFixture, DisplaySessionAssertionFixture) throws -> Void) rethrows {
        let name = "tether-display-session-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, DisplaySessionAssertionFixture(id: 9), DisplaySessionAssertionFixture(id: 19))
    }
}
