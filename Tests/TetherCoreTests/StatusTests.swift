import XCTest
@testable import TetherCore

final class StatusTests: XCTestCase {

    func testProtectionSleepEventPreservesItsIdentityAndLegacyEvents() throws {
        for event in [EventKind.protectionSleep, .overheatSleep, .weakChargerSleep, .sleepNow, .sleepRefused] {
            let data = try JSONEncoder().encode(event)
            XCTAssertEqual(try JSONDecoder().decode(EventKind.self, from: data), event)
        }
        XCTAssertEqual(try JSONDecoder().decode(EventKind.self, from: Data(#""overheatSleep""#.utf8)), .overheatSleep)
        XCTAssertEqual(EventKind.protectionSleep.logText, "protection stop: sleep requested")
    }

    func testRequestPresentationDoesNotClaimCompletedSleepOrRetry() {
        let saved = Localization.current
        defer { Localization.current = saved }
        Localization.current = .english
        XCTAssertEqual(Texts.sleepRequestAttempts(2), "sleep request attempts 2×")
        XCTAssertEqual(EventKind.protectionSleep.displayText, "protection stop → sleep requested")
        XCTAssertEqual(EventKind.sleepNow.displayText, "sleep requested")
        XCTAssertEqual(EventKind.sleepRefused.displayText, "sleep request refused")
        Localization.current = .korean
        XCTAssertEqual(Texts.sleepRequestAttempts(2), "잠자기 요청 시도 2회")
        XCTAssertEqual(EventKind.protectionSleep.displayText, "보호 중지 → 잠자기 요청")
        XCTAssertEqual(EventKind.sleepNow.displayText, "잠자기 요청")
        XCTAssertEqual(EventKind.sleepRefused.displayText, "잠자기 요청 거절됨")
    }

    func testDisplayRecoveryIsCurrentEvidenceNotSavedRetryHistory() throws {
        let now = Date(timeIntervalSince1970: 100)
        var status = Status(updatedAt: 99, version: TetherPaths.version,
            enabled: true, power: .ac, lidClosed: true, sleepDisabled: true,
            lastEvent: nil, lastEventAt: nil, fullWake: true)
        status.lidObservationAvailable = true; status.sleepOverrideObservationAvailable = true
        status.appConnected = true; status.ownsOverride = true
        status.displayTopology = DisplayTopology.none
        status.displayRecovery = DisplayRecoveryStatus(phase: .stopped, requests: 3)
        XCTAssertEqual(status.currentDisplayRecovery(now: now)?.phase, .stopped)
        for timestamp in [70.0, 101.0, Double.infinity, Double.nan] {
            var stale = status; stale.updatedAt = timestamp
            XCTAssertNil(stale.currentDisplayRecovery(now: now))
        }
        status.lidClosed = false
        XCTAssertNil(status.currentDisplayRecovery(now: now))
        let decoded = try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded.displayRecovery?.phase, .stopped)
        XCTAssertNil(decoded.currentDisplayRecovery(now: now))
    }

    private func currentReadyReply(now: Double = 100) -> ServiceReply {
        var control = Control(); control.schemaVersion = Control.currentSchema
        var reply = ServiceReply(id: UUID(), ok: true, epoch: "ready", revision: 1, control: control,
            protection: ProtectionStatus(reason: nil, error: nil, dryRun: true))
        var status = Status(updatedAt: now, version: TetherPaths.version, enabled: false, power: .ac,
            lidClosed: false, sleepDisabled: false, lastEvent: nil, lastEventAt: nil)
        status.build = TetherPaths.build
        status.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
        reply.status = status
        return reply
    }

    func testHelperReadinessRequiresTheExactRuntimeCoordinatorContract() throws {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(currentReadyReply().isCurrentHelperReady(now: now))
        for coordinator: Int? in [nil, 1, 2, 3, 4, 5, WorkSessionLease.coordinatorVersion + 1] {
            var reply = currentReadyReply(); reply.status?.workSessionCoordinatorVersion = coordinator
            let wire = try JSONDecoder().decode(ServiceReply.self, from: JSONEncoder().encode(reply))
            XCTAssertFalse(wire.isCurrentHelperReady(now: now), "coordinator \(String(describing: coordinator))")
        }
    }

    func testHelperReadinessRejectsStaleFutureAndNonfiniteObservationTimes() {
        let now = Date(timeIntervalSince1970: 100)
        for updated in [100.0, 99.0, 70.001] {
            XCTAssertTrue(currentReadyReply(now: updated).isCurrentHelperReady(now: now))
        }
        for updated in [70.0, 69.0, 100.001, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertFalse(currentReadyReply(now: updated).isCurrentHelperReady(now: now))
        }
        XCTAssertFalse(currentReadyReply().isCurrentHelperReady(now: Date(timeIntervalSince1970: .nan)))
    }

    func testHelperReadinessRejectsIncompleteFailedAndIncompatibleReplies() {
        let now = Date(timeIntervalSince1970: 100)
        for change in 0..<9 {
            var reply = currentReadyReply()
            switch change {
            case 0: reply.ok = false
            case 1: reply.version = 1
            case 2: reply.control.schemaVersion = Control.currentSchema + 1
            case 3: reply.protection = nil
            case 4: reply.protection?.protocolVersion = 1
            case 5: reply.protection?.blockReason = "migrationFailed"
            case 6: reply.status?.version = "older"
            case 7: reply.status?.build = TetherPaths.build - 1
            default: reply.status = nil
            }
            XCTAssertFalse(reply.isCurrentHelperReady(now: now), "case \(change)")
        }
    }

    func testHelperReadinessDoesNotRequireAnActiveSessionOrRemoveProtection() {
        var reply = currentReadyReply()
        reply.control.enabled = false
        reply.protection?.blockReason = "thermal"
        XCTAssertTrue(reply.isCurrentHelperReady(now: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(reply.control.enabled)
        XCTAssertEqual(reply.protection?.blockReason, "thermal")
        XCTAssertFalse(reply.status?.sleepDisabled == true)
    }

    func testHelperReadinessRejectsExplicitSleepEventRegistrationFailureWithoutChangingSelection() throws {
        var reply = currentReadyReply()
        reply.control.enabled = false
        reply.status?.systemPowerObservationAvailable = false
        let failed = try JSONDecoder().decode(ServiceReply.self, from: JSONEncoder().encode(reply))
        XCTAssertFalse(failed.isCurrentHelperReady(now: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(failed.control.enabled)
        XCTAssertEqual(failed.status?.systemPowerObservationAvailable, false)
        reply.status?.systemPowerObservationAvailable = true
        let recovered = try JSONDecoder().decode(ServiceReply.self, from: JSONEncoder().encode(reply))
        XCTAssertTrue(recovered.isCurrentHelperReady(now: Date(timeIntervalSince1970: 100)))
    }

    func testOldAndMalformedAvailabilityNeverUpgradeLegacyBoolValuesIntoEvidence() throws {
        let base = #"{"enabled":true,"lidClosed":false,"power":"ac","sleepDisabled":true,"updatedAt":1,"version":"old"}"#
        let old = try JSONDecoder().decode(Status.self, from: Data(base.utf8))
        XCTAssertNil(old.observedLidClosed); XCTAssertNil(old.observedSleepDisabled); XCTAssertNil(old.fullWake)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any])
        json["lidObservationAvailable"] = "yes"; json["sleepOverrideObservationAvailable"] = 1
        json["fullWake"] = "yes"
        let malformed = try JSONDecoder().decode(Status.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(malformed.observedLidClosed); XCTAssertNil(malformed.observedSleepDisabled); XCTAssertNil(malformed.fullWake)
    }

    func testObservationGapRoundTripPreservesOwnershipAndUnavailableFields() throws {
        var status = Status(updatedAt: 1, version: TetherPaths.version, enabled: true, power: .ac,
            lidClosed: false, sleepDisabled: false, lastEvent: nil, lastEventAt: nil, fullWake: nil)
        status.lidObservationAvailable = false; status.sleepOverrideObservationAvailable = false
        status.ownsOverride = true
        let decoded = try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded, status)
        XCTAssertNil(decoded.observedLidClosed); XCTAssertNil(decoded.observedSleepDisabled)
        XCTAssertTrue(decoded.ownsOverride == true)
    }
    /// A 1.0 helper wrote "displayOff", which 1.1 no longer has; the status must still decode.
    func testUnknownEventFromAnotherVersionStillDecodes() throws {
        let json = """
        {"enabled":true,"lastEvent":"displayOff","lastEventAt":1790358175.4,"lidClosed":false,
         "power":"ac","sleepDisabled":true,"updatedAt":1790358371.8,"version":"1.0.0"}
        """
        let status = try JSONDecoder().decode(Status.self, from: Data(json.utf8))
        XCTAssertEqual(status.version, "1.0.0")
        XCTAssertTrue(status.sleepDisabled)
        XCTAssertNil(status.lastEvent)
    }

    /// A 1.6 status read by a build that knows the new fields, and one written before them.
    func testNewFieldsAreOptional() throws {
        let old = """
        {"enabled":true,"lidClosed":true,"power":"ac","sleepDisabled":true,"updatedAt":1,"version":"1.4.0",
         "lastEvent":"heatGuardOn"}
        """
        let decodedOld = try JSONDecoder().decode(Status.self, from: Data(old.utf8))
        XCTAssertNil(decodedOld.heatGuard)
        XCTAssertNil(decodedOld.displayRecovery)
        XCTAssertNil(decodedOld.nativeDisplayVerified)
        XCTAssertEqual(decodedOld.lastEvent, .heatGuardOn)

        var status = Status(updatedAt: 1, version: TetherPaths.version, enabled: true, power: .ac,
                            lidClosed: true, sleepDisabled: true, lastEvent: .heatCritical, lastEventAt: 2)
        status.heatGuard = true
        status.displayRecovery = DisplayRecoveryStatus(phase: .recovering, requests: 2)
        status.thermalAlertAt = 3
        status.batteryHoldSince = 4
        let decoded = try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded, status)
    }

    func testLowPowerModeIsReadPerPowerSource() {
        let output = """
        Battery Power:
         Sleep On Power Button 1
         lowpowermode         1
         displaysleep         2
        AC Power:
         Sleep On Power Button 1
         lowpowermode         0
         displaysleep         10
        """
        XCTAssertEqual(SystemProbe.lowPowerMode(in: output, section: "Battery Power"), 1)
        XCTAssertEqual(SystemProbe.lowPowerMode(in: output, section: "AC Power"), 0)
        XCTAssertNil(SystemProbe.lowPowerMode(in: "AC Power:\n displaysleep 10\n", section: "AC Power"))
    }

    func testRoundTrip() throws {
        let status = Status(updatedAt: 1, version: TetherPaths.version, enabled: true, power: .battery,
                            lidClosed: true, sleepDisabled: false, lastEvent: .lidSleep, lastEventAt: 2)
        let decoded = try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded, status)
    }

    func testWorkSessionNegotiationAndAcknowledgementSurviveIPCEncoding() throws {
        var status = Status(updatedAt: 1, version: TetherPaths.version, enabled: true, power: .ac,
                            lidClosed: true, sleepDisabled: true, lastEvent: nil, lastEventAt: nil)
        status.workSessionCoordinatorVersion = 1
        status.nativeDisplayVerified = true
        status.workSession = WorkSessionLease(sessionID: UUID(), sequence: 12, power: .ac,
            expiry: 190, reasons: [.automatic, .manual], settings: IdleSessionSettings())
        let data = try JSONEncoder().encode(status)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["workSessionCoordinatorVersion"] as? Int, 1)
        XCTAssertNotNil(json["workSession"])
        XCTAssertEqual(try JSONDecoder().decode(Status.self, from: data), status)
        let old = Data(#"{"updatedAt":1,"version":"old","enabled":false,"power":"ac","lidClosed":false,"sleepDisabled":false}"#.utf8)
        let decodedOld = try JSONDecoder().decode(Status.self, from: old)
        XCTAssertNil(decodedOld.workSessionCoordinatorVersion)
        XCTAssertNil(decodedOld.workSession)
    }
}

final class DateTextTests: XCTestCase {
    private let saved = Localization.current
    override func tearDown() { Localization.current = saved }

    /// Dates follow Tether's language, not the Mac's, so English never shows "9월".
    func testDatesFollowTheAppLanguage() {
        let date = Date(timeIntervalSince1970: 1_790_395_200)  // late September 2026
        Localization.current = .english
        XCTAssertTrue(Texts.dateTime(date).contains("Sep"), Texts.dateTime(date))
        Localization.current = .korean
        XCTAssertTrue(Texts.dateTime(date).contains("9월"), Texts.dateTime(date))
        XCTAssertFalse(Texts.time(date).isEmpty)
    }
}
