import XCTest
@testable import TetherCore

final class HealthChecksTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func healthy() -> HealthChecks.Evidence {
        var e = HealthChecks.Evidence()
        e.helperInstalled = true; e.watchdogInstalled = true; e.watchdogRegistration = .registered
        e.boot = "test-boot"; e.temperature = 30
        e.watchdogReceipt = WatchdogReceipt(checkedAt: now.timeIntervalSince1970 - 10, boot: e.boot, exitStatus: 0)
        e.snapshot = Snapshot(power: .ac, lidClosed: false, sleepDisabled: true, fullWake: true)
        var reply = ServiceReply(id: UUID(), ok: true, epoch: "epoch", revision: 1, control: Control(),
                                 protection: ProtectionStatus(reason: nil, error: nil, dryRun: false))
        reply.control.enabled = true
        var status = Status(updatedAt: now.timeIntervalSince1970 - 1, version: TetherPaths.version,
                            enabled: true, power: .ac, lidClosed: false, sleepDisabled: true,
                            lastEvent: nil, lastEventAt: nil)
        status.build = TetherPaths.build; status.appConnected = true; status.ownsOverride = true
        status.lidObservationAvailable = true; status.sleepOverrideObservationAvailable = true; status.fullWake = true
        status.displayTopology = DisplayTopology.none; reply.status = status; e.reply = reply
        return e
    }
    private func checks(_ e: HealthChecks.Evidence) -> [HealthCheck] { HealthChecks.evaluate(e, now: now, language: .english) }
    private func result(_ name: String, _ e: HealthChecks.Evidence) -> HealthCheck.Result? { checks(e).first { $0.name == name }?.result }

    func testDesktopCommonWorkDoesNotRequireHelperOrWatchdog() {
        var e = HealthChecks.Evidence()
        e.capabilities = MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false)
        e.userSessionRequested = true; e.userSession = diagnosticCommonReply(now: now)
        XCTAssertEqual(result("Common work session", e), .ok)
        XCTAssertEqual(result("Lid support", e), .ok)
        XCTAssertNil(result("Helper installation", e)); XCTAssertNil(result("Watchdog", e))
        XCTAssertTrue(checks(e).allSatisfy { $0.result == .ok })
        e.userSession?.status?.enabled = false; e.userSession?.status?.holding = false
        XCTAssertEqual(result("Common work session", e), .ok)
        XCTAssertTrue(checks(e).contains { $0.detail.contains("off choice") })
    }

    func testUnknownLidCapabilityDoesNotTurnCommonWorkIntoInstallationFailure() {
        var e = HealthChecks.Evidence()
        e.capabilities = MacCapabilities(supportedPlatform: true, internalBattery: nil, lid: nil)
        e.userSessionRequested = true; e.userSession = diagnosticCommonReply(now: now)
        e.userSession?.lidSupport = .unavailable
        XCTAssertEqual(result("Common work session", e), .ok)
        XCTAssertEqual(result("Lid support", e), .warning)
        XCTAssertNil(result("Helper installation", e))
        e.userSession?.status?.error = "requestVerificationFailed"
        XCTAssertEqual(result("Common work session", e), .failed)
        e.userSession?.status?.error = nil; e.userSession?.status?.blockReason = "thermal"
        XCTAssertEqual(result("Common protection", e), .warning)
    }

    func testMissingIncompatibleAndStaleCommonRepliesCannotUseSavedHelperState() {
        var e = healthy()
        e.capabilities = MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false)
        e.userSessionRequested = true
        XCTAssertEqual(result("Common work session", e), .failed)
        for change in 0..<5 {
            e.userSession = diagnosticCommonReply(now: now)
            switch change {
            case 0: e.userSession?.build -= 1
            case 1: e.userSession?.version = 2
            case 2: e.userSession?.observedAt = now.timeIntervalSince1970 - 90
            case 3: e.userSession?.observedAt = now.timeIntervalSince1970 + 1
            default: e.userSession?.ok = false
            }
            XCTAssertEqual(result("Common work session", e), .failed)
            XCTAssertNil(result("Sleep setting", e))
        }
    }

    func testCommonLidPolicyDoesNotUseLegacyDisabledAutomaticSetting() {
        var e = healthy()
        e.capabilities = MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true)
        e.userSessionRequested = true; e.userSession = diagnosticCommonReply(now: now)
        e.userSession?.lidSupport = .active; e.userSession?.helperBuild = TetherPaths.build; e.userSession?.helperConnected = true
        e.reply?.control.enabled = false
        XCTAssertEqual(result("Sleep setting", e), .ok)
        XCTAssertEqual(result("Lid support", e), .ok)
    }

    func testCommonRequestVerdictSeparatesActiveIntentFromWaitingOffAndProtection() {
        let cases: [(manual: Bool, automatic: Bool, enabled: Bool, block: String?, expected: HealthCheck.Result)] = [
            (true, false, true, nil, .warning),
            (false, true, true, nil, .warning),
            (false, false, true, nil, .ok),
            (false, false, false, nil, .ok),
            (false, false, true, "thermal", .ok)
        ]
        for item in cases {
            var e = HealthChecks.Evidence()
            e.capabilities = MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false)
            e.userSessionRequested = true; e.userSession = diagnosticCommonReply(now: now)
            e.userSession?.status?.manualActive = item.manual
            e.userSession?.status?.automaticEnabled = item.automatic
            e.userSession?.status?.automaticActive = item.automatic
            e.userSession?.status?.enabled = item.enabled
            e.userSession?.status?.blockReason = item.block
            e.userSession?.status?.pendingBatteryMinutes = nil
            e.userSession?.status?.holding = false
            XCTAssertNil(e.userSession?.status?.error)
            XCTAssertEqual(result("Common work session", e), item.expected)
            XCTAssertFalse(checks(e).contains { $0.result == .failed })
            if item.block != nil { XCTAssertEqual(result("Common protection", e), .warning) }
        }
        var e = HealthChecks.Evidence()
        e.capabilities = MacCapabilities(supportedPlatform: true, internalBattery: true, lid: nil)
        e.userSessionRequested = true; e.userSession = diagnosticCommonReply(now: now)
        e.userSession?.lidSupport = .unavailable
        e.userSession?.status?.manualActive = false; e.userSession?.status?.holding = false
        e.userSession?.status?.pendingBatteryMinutes = 3
        XCTAssertEqual(result("Common work session", e), .ok)
        XCTAssertFalse(checks(e).contains { $0.result == .failed })
    }

    func testUnknownOSOrHelperObservationCannotPassSleepRule() {
        for missing in 0..<6 {
            var e = healthy()
            e.capabilities = MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true)
            e.userSessionRequested = true; e.userSession = diagnosticCommonReply(now: now)
            e.userSession?.lidSupport = .inactive
            e.userSession?.status?.manualActive = false; e.userSession?.status?.holding = false
            e.userSession?.status?.pendingBatteryMinutes = nil
            e.snapshot.sleepDisabled = false; e.reply?.status?.sleepDisabled = false
            e.reply?.status?.ownsOverride = false
            switch missing {
            case 0: e.snapshot.observedLidClosed = nil
            case 1: e.snapshot.observedSleepDisabled = nil
            case 2: e.snapshot.observedFullWake = nil
            case 3: e.reply?.status?.lidObservationAvailable = false
            case 4: e.reply?.status?.sleepOverrideObservationAvailable = false
            default: e.reply?.status?.fullWake = nil
            }
            XCTAssertEqual(result("Sleep setting", e), .warning, "missing observation \(missing)")
        }
    }

    func testPendingLidDoesNotHideIndependentRecordingOrTemperatureChecks() {
        var e = healthy()
        e.capabilities = MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true)
        e.userSessionRequested = true; e.userSession = diagnosticCommonReply(now: now)
        e.userSession?.lidSupport = .pending
        e.reply?.control.debugLog = true; e.reply?.control.debugLogUntil = now.timeIntervalSince1970 + 60
        XCTAssertEqual(result("Sleep setting", e), .warning)
        XCTAssertEqual(result("Detailed recording", e), .ok)
        XCTAssertEqual(result("Battery temperature", e), .ok)
        XCTAssertEqual(result("Common work session", e), .ok)
    }

    func testDisagreeingOSAndHelperValuesDoNotPassSleepRule() {
        for disagreement in 0..<2 {
            var e = healthy()
            if disagreement == 0 { e.reply?.status?.sleepDisabled = false }
            else { e.reply?.status?.lidClosed = true }
            XCTAssertEqual(result("Sleep setting", e), .warning)
            XCTAssertTrue(checks(e).contains { $0.detail.contains("no rule verdict") })
        }
    }

    func testHealthyRequiresLiveReplyMatchingBuildAndRecentWatchdogReceipt() {
        XCTAssertTrue(checks(healthy()).allSatisfy { $0.result == .ok })
    }

    func testDisplaySettingAloneNeverPassesDisplayObservation() {
        var e = healthy(); e.snapshot.lidClosed = true; e.reply?.status?.lidClosed = true
        XCTAssertEqual(result("Display sleep", e), .warning)
        e.reply?.status?.displaySleeping = true
        e.reply?.status?.displayRecovery = DisplayRecoveryStatus(phase: .recovering, requests: 2)
        XCTAssertEqual(result("Display sleep", e), .warning)
        e.reply?.status?.displayRecovery = DisplayRecoveryStatus(phase: .asleep, requests: 2)
        XCTAssertEqual(result("Display sleep", e), .ok)
        e.reply?.status?.displaySleeping = false
        XCTAssertEqual(result("Display sleep", e), .warning)
        e.reply?.status?.updatedAt = now.timeIntervalSince1970 - 100
        XCTAssertNil(result("Display sleep", e))
    }

    func testPastClosedLidRecoveryDoesNotWarnAboutOpenOrReleasedWork() {
        for change in 0..<6 {
            var e = healthy()
            e.reply?.status?.lidClosed = true
            e.reply?.status?.displayRecovery = DisplayRecoveryStatus(phase: .stopped, requests: 3)
            switch change {
            case 0: e.reply?.status?.lidClosed = false
            case 1: e.reply?.status?.ownsOverride = false
            case 2: e.reply?.status?.appConnected = false
            case 3: e.reply?.status?.fullWake = false
            case 4: e.reply?.status?.lidObservationAvailable = false
            default: e.reply?.status?.sleepDisabled = false
            }
            XCTAssertNil(result("Display sleep", e), "case \(change)")
        }
        var e = healthy()
        e.reply?.status?.lidClosed = true
        e.reply?.status?.displayRecovery = DisplayRecoveryStatus(phase: .stopped, requests: 3)
        XCTAssertEqual(result("Display sleep", e), .warning)
    }

    func testExternalDisplayUsesCurrentPanelObservationInsteadOfOldRecoveryPhase() {
        for topology in [DisplayTopology.virtualOnly, .externalWithVirtual, .externalUnverified] {
            var e = healthy()
            e.reply?.status?.lidClosed = true
            e.reply?.status?.displayTopology = topology
            e.reply?.status?.displayRecovery = DisplayRecoveryStatus(phase: .asleep, requests: 2)
            for sleeping in [true as Bool?, false, nil] {
                e.reply?.status?.displaySleeping = sleeping
                XCTAssertEqual(result("Display sleep", e), sleeping == true ? .ok : .warning)
                if sleeping != true {
                    XCTAssertFalse(checks(e).first { $0.name == "Display sleep" }!.detail.contains("reports the display asleep"))
                }
            }
        }
    }

    func testMissingLiveReplyNeverClaimsRespondingOrEvaluatesPolicy() {
        var e = healthy(); e.reply = nil; e.serviceError = "unavailable"
        XCTAssertEqual(result("Helper connection", e), .failed)
        XCTAssertNil(result("Sleep setting", e))
    }
    func testSameVersionDifferentOrMissingBuildRequiresUpdate() {
        for build in [nil, TetherPaths.build - 1] {
            var e = healthy(); e.reply?.status?.build = build
            XCTAssertEqual(result("Helper version", e), .failed)
            XCTAssertNil(result("Sleep setting", e))
        }
    }
    func testBothWireAndProtectionProtocolMustMatch() {
        var e = healthy(); e.reply?.version = 3
        XCTAssertEqual(result("Helper connection", e), .failed)
        e = healthy(); e.reply?.protection?.protocolVersion = 3
        XCTAssertEqual(result("Helper connection", e), .failed)
        e = healthy(); e.reply?.protection = nil
        XCTAssertEqual(result("Helper connection", e), .failed)
        e = healthy(); e.reply?.ok = false
        XCTAssertEqual(result("Helper connection", e), .failed)
    }
    func testStaleFutureMissingAndNonfiniteObservationsCannotPass() {
        for timestamp in [nil, now.timeIntervalSince1970 - 90, now.timeIntervalSince1970 + 1, .infinity, .nan] {
            var e = healthy(); e.reply?.status?.updatedAt = timestamp ?? 0
            if timestamp == nil { e.reply?.status = nil }
            XCTAssertEqual(result("Helper observations", e), .warning)
            XCTAssertNil(result("Sleep setting", e))
        }
    }
    func testWatchdogFilesDoNotProveRegistrationOrExecution() {
        var e = healthy(); e.watchdogRegistration = .missing
        XCTAssertEqual(result("Watchdog", e), .warning)
        e.watchdogRegistration = .unavailable
        XCTAssertEqual(result("Watchdog", e), .warning)
        e.watchdogRegistration = .registered; e.watchdogReceipt = nil
        XCTAssertEqual(result("Watchdog", e), .warning)
    }
    func testPreviousBootStaleFutureOrFailedWatchdogReceipts() {
        var e = healthy(); e.watchdogReceipt?.boot = "old-boot"
        XCTAssertEqual(result("Watchdog", e), .warning)
        for age in [-10.0, 90, 200] {
            e = healthy(); e.watchdogReceipt?.checkedAt = now.timeIntervalSince1970 - age
            XCTAssertEqual(result("Watchdog", e), .warning)
        }
        e = healthy(); e.watchdogReceipt?.exitStatus = 1
        XCTAssertEqual(result("Watchdog", e), .failed)
    }
    func testAppDisconnectedAndProtectionStopYieldSleepNormally() {
        var e = healthy(); e.reply?.status?.appConnected = false; e.snapshot.sleepDisabled = false
        e.reply?.status?.sleepDisabled = false
        XCTAssertEqual(result("Sleep setting", e), .ok)
        XCTAssertEqual(result("App session", e), .warning)
        XCTAssertTrue(checks(e).contains { $0.detail.contains("saved preferences") })
        e = healthy(); e.reply?.protection?.blockReason = "heat"; e.snapshot.sleepDisabled = false
        e.reply?.status?.sleepDisabled = false
        XCTAssertEqual(result("Sleep setting", e), .ok)
        XCTAssertEqual(result("Protection", e), .warning)
    }
    func testDisabledAppMayDisconnectButMissingSessionEvidenceNeverPasses() {
        var e = healthy(); e.reply?.control.enabled = false; e.reply?.status?.appConnected = false
        e.snapshot.sleepDisabled = false
        e.reply?.status?.sleepDisabled = false
        XCTAssertEqual(result("App session", e), .ok)
        e.reply?.status?.appConnected = nil
        XCTAssertEqual(result("App session", e), .warning)
        e.reply?.status?.updatedAt = now.timeIntervalSince1970 - 90
        XCTAssertNil(result("App session", e))
    }
    func testForeignOverrideIsNotOurSuccess() {
        var e = healthy(); e.reply?.status?.ownsOverride = false
        XCTAssertEqual(result("Sleep setting", e), .warning)
        XCTAssertTrue(checks(e).contains { $0.detail.contains("does not own") })
    }
    func testNativeDisplayHandoffAndTransitionsAreNotFalseFailures() {
        var e = healthy(); e.snapshot = Snapshot(power: .ac, lidClosed: true, sleepDisabled: false, externalDisplay: true)
        e.snapshot.nativeDisplayVerified = true
        e.reply?.status?.lidClosed = true; e.reply?.status?.displayTopology = .externalUnverified
        e.reply?.status?.sleepDisabled = false
        XCTAssertEqual(result("Sleep setting", e), .ok)
        e.snapshot.power = .battery
        XCTAssertEqual(result("Sleep setting", e), .warning)
        XCTAssertTrue(checks(e).contains { $0.detail.contains("no rule verdict") })
    }
    func testExpiredTimerAndPendingSleepDoNotDemandOverride() {
        var e = healthy(); e.snapshot.power = .battery; e.snapshot.sleepDisabled = false
        e.reply?.status?.sleepDisabled = false
        e.reply?.status?.power = .battery; e.reply?.status?.batteryHoldUntil = now.timeIntervalSince1970 - 1
        XCTAssertEqual(result("Sleep setting", e), .ok)
        e = healthy(); e.reply?.control.sleepNowRequest = now.timeIntervalSince1970; e.snapshot.sleepDisabled = false
        e.reply?.status?.sleepDisabled = false
        XCTAssertEqual(result("Sleep setting", e), .ok)
    }
    func testApplyFailureAndUnsupportedSchemaRemainVisible() {
        var e = healthy(); e.reply?.protection?.lastError = "pmsetFailed"
        XCTAssertEqual(result("Power changes", e), .failed)
        e = healthy(); e.reply?.control.schemaVersion = 999
        XCTAssertEqual(result("Settings format", e), .failed)
        XCTAssertNil(result("Sleep setting", e))
    }
    func testExpiredDebugRecordingIsNotReportedActive() {
        var e = healthy(); e.reply?.control.debugLog = true; e.reply?.control.debugLogUntil = now.timeIntervalSince1970 - 1
        XCTAssertNil(result("Detailed recording", e))
        e.reply?.control.debugLogUntil = now.timeIntervalSince1970 + 60
        XCTAssertEqual(result("Detailed recording", e), .ok)
    }
}

func diagnosticCommonReply(now: Date) -> UserSessionReply {
    let status = UserSessionStatus(power: .ac, thermal: 0, batteryPercent: nil, limits: nil,
        enabled: true, automaticEnabled: false, automaticActive: false, powerCondition: .ac,
        automaticMinutes: 60, batteryHoldUntil: nil, pendingBatteryMinutes: 3, manualActive: true,
        holding: true, until: nil, blockReason: nil, error: nil, canStart: true, manualBatteryRemaining: 7200,
        manualEndReason: nil, manualMaximumMinutes: 120, canStartBatteryHold: false, batteryRemaining: 14400)
    var reply = UserSessionReply(id: UUID(), epoch: UUID(), revision: 4, ok: true, status: status)
    reply.observedAt = now.timeIntervalSince1970 - 1; reply.lidSupport = .notRequired
    return reply
}
