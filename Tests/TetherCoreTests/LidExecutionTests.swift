import Foundation
import XCTest
@testable import TetherCore

final class LidExecutionTests: XCTestCase {
    func testBatteryEndIsPreparedOnlyForItsApprovedEndpointNotHeartbeatExpiry() {
        let settings = IdleSessionSettings()
        let session = UUID(), permitID = UUID()
        let receipt = WorkSessionBatteryPermitReceipt(bootID: "boot", sessionID: session,
            permitID: permitID, observedAt: 100, deadline: 150)
        var lease = WorkSessionLease(sessionID: session, sequence: 1, power: .battery,
            expiry: 150, reasons: [.manual], manualDeadline: 150, settings: settings,
            lidPermit: WorkSessionLidPermit(powerScopes: [.battery], batteryPermitID: permitID,
                batteryDuration: 50, batteryDeadline: 150))
        func deadline(_ now: Double = 149, boot: String = "boot") -> Double? {
            SleepRequestPolicy.approvedBatteryEndDeadline(lease: lease, receipt: receipt, boot: boot, now: now)
        }
        XCTAssertEqual(deadline(), 150, "An endpoint equal to the health expiry can be pre-approved")
        XCTAssertNil(deadline(150), "Expiry cannot invent new approval")
        XCTAssertNil(deadline(99))
        XCTAssertNil(deadline(.nan))
        XCTAssertNil(deadline(boot: "new-boot"))
        lease.expiry = 140
        XCTAssertNil(deadline(130), "Losing the heartbeat before the battery endpoint is restore-only")
        lease.expiry = 190; lease.lidPermit?.batteryPermitID = UUID()
        XCTAssertNil(deadline())
        lease.lidPermit?.batteryPermitID = permitID; lease.sessionID = UUID()
        XCTAssertNil(deadline())
    }

    func testManualBatteryDeadlineCannotEndAnIndependentAutomaticReason() {
        var settings = IdleSessionSettings()
        settings.powerCondition = .any
        let session = UUID(), permitID = UUID()
        let receipt = WorkSessionBatteryPermitReceipt(bootID: "boot", sessionID: session,
            permitID: permitID, observedAt: 100, deadline: 150)
        var lease = WorkSessionLease(sessionID: session, sequence: 1, power: .battery,
            expiry: 150, reasons: [.manual], manualDeadline: 130, settings: settings,
            lidPermit: WorkSessionLidPermit(powerScopes: [.battery], batteryPermitID: permitID,
                batteryDuration: 50, batteryDeadline: 150))
        XCTAssertEqual(SleepRequestPolicy.approvedBatteryEndDeadline(lease: lease, receipt: receipt,
            boot: "boot", now: 120), 130)
        lease.reasons.append(.automatic)
        lease.configuration.automaticEnabled = true
        XCTAssertNil(SleepRequestPolicy.approvedBatteryEndDeadline(lease: lease, receipt: receipt,
            boot: "boot", now: 120), "Retired automatic battery work cannot authorize an end action")
        lease.configuration.automaticEnabled = false
        XCTAssertNil(SleepRequestPolicy.approvedBatteryEndDeadline(lease: lease, receipt: receipt,
            boot: "boot", now: 130))
    }

    func testExpiredBatteryEndStillRequiresClosedRestoredBatteryAndNoOtherWork() {
        let battery = Snapshot(power: .battery, lidClosed: true, sleepDisabled: false, fullWake: true)
        func allowed(_ value: Snapshot, action: WorkSessionEndAction = .sleepIfClosed,
                     owner: Bool = true, work: Bool = false) -> Bool {
            SleepRequestPolicy.allowsCoordinatedEnd(.batteryExpired, action: action,
                snapshot: value, ownerConfirmed: owner, restoreConfirmed: true,
                batteryPermitValid: work, thermal: 0, observerConfirmed: true)
        }
        XCTAssertTrue(allowed(battery))
        XCTAssertFalse(allowed(battery, action: .followOS))
        XCTAssertFalse(allowed(battery, owner: false))
        XCTAssertFalse(allowed(battery, work: true))
        XCTAssertFalse(allowed(Snapshot(power: .ac, lidClosed: true, sleepDisabled: false, fullWake: true)))
        XCTAssertFalse(allowed(Snapshot(power: .battery, lidClosed: false, sleepDisabled: false, fullWake: true)))
        XCTAssertFalse(allowed(Snapshot(power: .battery, lidClosed: true, sleepDisabled: true, fullWake: true)))
    }

    func testLidEndAuthorityCannotOutliveItsGrantOrOnlyManualReason() {
        for reasons in [[WorkSessionReason.manual], [.automatic, .manual]] {
            var settings = IdleSessionSettings()
            settings.automaticEnabled = reasons.contains(.automatic)
            let lease = WorkSessionLease(sessionID: UUID(), sequence: 1, power: .ac, expiry: 130,
                reasons: reasons, manualDeadline: 110, settings: settings,
                lidPermit: WorkSessionLidPermit(powerScopes: [.ac]))
            var gate = WorkSessionLeaseGate()
            XCTAssertTrue(gate.accept(lease, now: 100, attaching: true))
            XCTAssertEqual(gate.reasons(now: 109, power: lease.power), reasons)
            let remaining: [WorkSessionReason] = reasons.contains(.automatic) ? [.automatic] : []
            XCTAssertEqual(gate.reasons(now: 110, power: lease.power), remaining)
            XCTAssertEqual(gate.reasons(now: 129, power: lease.power), remaining)
            XCTAssertEqual(gate.reasons(now: 130, power: lease.power), [])
            XCTAssertEqual(gate.reasons(now: 131, power: lease.power), [])
            XCTAssertEqual(gate.current, lease, "Retained evidence after expiry cannot authorize an end action")
        }
    }

    func testDisconnectEndsOnlyTheApprovedClosedBatteryIncident() {
        let snapshot = Snapshot(power: .battery, lidClosed: true, sleepDisabled: false, fullWake: true)
        func allowed(_ value: Snapshot, action: WorkSessionEndAction = .sleepIfClosed,
                     owner: Bool = true, restored: Bool = true, battery: Bool = false,
                     observer: Bool = true) -> Bool {
            SleepRequestPolicy.allowsCoordinatedEnd(.disconnect, action: action, snapshot: value,
                ownerConfirmed: owner, restoreConfirmed: restored, batteryPermitValid: battery,
                thermal: 0, observerConfirmed: observer)
        }
        XCTAssertTrue(allowed(snapshot))
        XCTAssertFalse(allowed(snapshot, action: .followOS))
        XCTAssertFalse(allowed(snapshot, owner: false))
        XCTAssertFalse(allowed(snapshot, restored: false))
        XCTAssertFalse(allowed(snapshot, battery: true))
        XCTAssertFalse(allowed(snapshot, observer: false))
        for value in [Snapshot(power: .ac, lidClosed: true, sleepDisabled: false, fullWake: true),
            Snapshot(power: .unknown, lidClosed: true, sleepDisabled: false, fullWake: true),
            Snapshot(power: .battery, lidClosed: false, sleepDisabled: false, fullWake: true),
            Snapshot(power: .battery, lidClosed: nil, sleepDisabled: false, fullWake: true),
            Snapshot(power: .battery, lidClosed: true, sleepDisabled: true, fullWake: true),
            Snapshot(power: .battery, lidClosed: true, sleepDisabled: nil, fullWake: true),
            Snapshot(power: .battery, lidClosed: true, sleepDisabled: false, fullWake: nil)] {
            XCTAssertFalse(allowed(value))
        }
    }

    func testProtectionOverridesBatteryPermitOnBothPowerSourcesAndRequiresCurrentThermalPressure() {
        for power in [PowerSource.ac, .battery] {
            let snapshot = Snapshot(power: power, lidClosed: true, sleepDisabled: false, fullWake: true)
            for thermal in [Int?.none, -1, 0, 1, 2, 3, 4] {
                let result = SleepRequestPolicy.allowsCoordinatedEnd(.protection, action: .sleepIfClosed,
                    snapshot: snapshot, ownerConfirmed: true, restoreConfirmed: true,
                    batteryPermitValid: true, thermal: thermal, observerConfirmed: true)
                XCTAssertEqual(result, thermal.map { (2...3).contains($0) } ?? false)
            }
        }
    }

    func testExplicitUserSleepUsesRestoredOwnershipAndCurrentWakeEvenWithOpenLidOnAC() {
        let snapshot = Snapshot(power: .ac, lidClosed: false, sleepDisabled: false, fullWake: true)
        XCTAssertTrue(SleepRequestPolicy.allowsCoordinatedEnd(.user, action: .followOS, snapshot: snapshot,
            ownerConfirmed: true, restoreConfirmed: true, batteryPermitValid: true, thermal: 0,
            observerConfirmed: true))
    }

    func testBatteryProtectiveSleepNeedsCurrentBatteryEvidenceAndEveryExistingSafetyGate() {
        let battery = Snapshot(power: .battery, lidClosed: true, sleepDisabled: false, fullWake: true)
        func allowed(_ snapshot: Snapshot, active: Bool = true, action: WorkSessionEndAction = .sleepIfClosed,
                     owner: Bool = true, restored: Bool = true, observer: Bool = true) -> Bool {
            SleepRequestPolicy.allowsCoordinatedEnd(.protection, action: action, snapshot: snapshot,
                ownerConfirmed: owner, restoreConfirmed: restored, batteryPermitValid: true,
                thermal: 0, observerConfirmed: observer, batteryProtectionActive: active)
        }
        XCTAssertTrue(allowed(battery))
        XCTAssertFalse(allowed(battery, active: false), "A cleared or unknown final warning cannot authorize Sleep")
        XCTAssertFalse(allowed(battery, action: .followOS))
        XCTAssertFalse(allowed(battery, owner: false))
        XCTAssertFalse(allowed(battery, restored: false))
        XCTAssertFalse(allowed(battery, observer: false))
        for snapshot in [Snapshot(power: .ac, lidClosed: true, sleepDisabled: false, fullWake: true),
            Snapshot(power: .unknown, lidClosed: true, sleepDisabled: false, fullWake: true),
            Snapshot(power: .battery, lidClosed: false, sleepDisabled: false, fullWake: true),
            Snapshot(power: .battery, lidClosed: nil, sleepDisabled: false, fullWake: true),
            Snapshot(power: .battery, lidClosed: true, sleepDisabled: true, fullWake: true),
            Snapshot(power: .battery, lidClosed: true, sleepDisabled: nil, fullWake: true),
            Snapshot(power: .battery, lidClosed: true, sleepDisabled: false, fullWake: false)] {
            XCTAssertFalse(allowed(snapshot))
        }
    }

    func testBatteryPermitScopeNeedsAnIdentityFiniteDurationAndDirectBatteryDeadline() {
        let id = UUID()
        let acOnly = WorkSessionLidPermit(powerScopes: [.ac])
        XCTAssertTrue(acOnly.isValid(now: 100, source: .ac))
        XCTAssertFalse(acOnly.isValid(now: 100, source: .battery))
        var both = WorkSessionLidPermit(powerScopes: [.ac, .battery], batteryPermitID: id, batteryDuration: 1800)
        XCTAssertTrue(both.isValid(now: 100, source: .ac))
        XCTAssertFalse(both.isValid(now: 100, source: .battery))
        both.batteryDeadline = 1900
        XCTAssertTrue(both.isValid(now: 100, source: .battery))
        both.batteryDuration = 7201
        XCTAssertFalse(both.isValid(now: 100, source: .ac))
        both.batteryDuration = 1800; both.batteryPermitID = nil
        XCTAssertFalse(both.isValid(now: 100, source: .ac))
        both.batteryPermitID = id; both.powerScopes = [.ac, .ac]
        XCTAssertFalse(both.isValid(now: 100, source: .ac))
    }

    func testNewExecutionFieldsDoNotInventAuthorityWhenDecodingOldData() throws {
        let old = Data(#"{"version":1,"sessionID":"CCFAF5EE-F23C-4E72-A03F-4056BC0B2099","sequence":1,"power":"ac","expiry":190,"reasons":["automatic"],"configuration":{"enabled":true,"automaticEnabled":true,"condition":"ac","automaticMinutes":60}}"#.utf8)
        let lease = try JSONDecoder().decode(WorkSessionLease.self, from: old)
        XCTAssertNil(lease.executionVersion); XCTAssertNil(lease.lidPermit)
        let state = try JSONDecoder().decode(HelperState.self, from: Data("{}".utf8))
        XCTAssertNil(state.lidExecutionVersion); XCTAssertNil(state.batteryPermitReceipts)
        XCTAssertNil(state.lidEndReceipt); XCTAssertNil(state.lidProtection)
    }

    func testReceiptBatchIsOptionalInOldBridgeAndRoundTripsEvidenceWithoutExtendingPermission() throws {
        let old = Data(#"{"version":1,"coordinated":true,"automaticBudget":{},"stopRequested":false}"#.utf8)
        var bridge = try JSONDecoder().decode(WorkSessionBridge.self, from: old)
        XCTAssertNil(bridge.batteryPermitReceipt); XCTAssertNil(bridge.batteryPermitReceipts)
        let session = UUID()
        let manual = WorkSessionBatteryPermitReceipt(bootID: "boot", sessionID: session,
            permitID: UUID(), observedAt: 110, deadline: 7310)
        let automatic = WorkSessionBatteryPermitReceipt(bootID: "boot", sessionID: session,
            permitID: UUID(), observedAt: 200, deadline: 2000)
        bridge.batteryPermitReceipt = automatic
        bridge.batteryPermitReceipts = [manual, automatic]
        let decoded = try JSONDecoder().decode(WorkSessionBridge.self, from: JSONEncoder().encode(bridge))
        XCTAssertEqual(decoded.batteryPermitReceipt, automatic)
        XCTAssertEqual(decoded.batteryPermitReceipts, [manual, automatic])
    }

    func testBatteryReceiptCannotCarryADeadlineOutsideItsFirstObservedProductCapOrAcrossBoot() {
        var receipt = WorkSessionBatteryPermitReceipt(bootID: "boot", sessionID: UUID(), permitID: UUID(),
            observedAt: 100, deadline: 1900)
        XCTAssertTrue(receipt.isValid(boot: "boot"))
        XCTAssertFalse(receipt.isValid(boot: "other"))
        receipt.deadline = 7301; XCTAssertFalse(receipt.isValid(boot: "boot"))
        receipt.deadline = 100; XCTAssertFalse(receipt.isValid(boot: "boot"))
    }
}
