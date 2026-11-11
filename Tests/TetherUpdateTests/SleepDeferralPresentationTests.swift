import XCTest
@testable import Tether
import TetherCore

private final class SleepDeferralMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func register(defaults: [String: Any]) { registered.merge(defaults) { _, new in new } }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
}

private final class SleepDeferralAssertionBackend: IdleAssertionBackend {
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { (0, 41) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { 0 }
}

final class SleepDeferralPresentationTests: XCTestCase {
    private static let portable = MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true)
    private let endedTitle = L("Tether hold ended", "Tether 유지 종료")

    @MainActor
    private func fixture(common: Bool = true, reason: String = "otherRequests",
                         capabilities: MacCapabilities = SleepDeferralPresentationTests.portable,
                         mutateStatus: (inout Status) -> Void = { _ in },
                         mutateSession: (UserSessionController) -> Void = { _ in }) -> (UserSessionController?, AppModel) {
        let defaults = SleepDeferralMemoryDefaults()
        let controller = common ? UserSessionController(defaults: defaults,
            backend: SleepDeferralAssertionBackend(), guiProbe: nil, environmentProbe: nil) : nil
        controller?.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                           now: ContinuousTime.now, batteryPercent: 80)
        if let controller { mutateSession(controller) }
        var status = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
            enabled: true, power: .battery, lidClosed: true, sleepDisabled: false,
            lastEvent: nil, lastEventAt: nil, fullWake: true, thermal: 0, batteryPercent: 80)
        status.build = TetherPaths.build
        status.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
        status.systemPowerObservationAvailable = true
        status.displayTopology = DisplayTopology.none; status.externalDisplay = false
        status.ownsOverride = false; status.appConnected = true
        status.appPID = ProcessInfo.processInfo.processIdentifier
        status.guiSessionAuthority = .confirmed; status.sleepDeferralReason = reason
        status.protection = ProtectionStatus(reason: nil, error: nil, dryRun: true)
        mutateStatus(&status)
        var reply = ServiceReply(id: UUID(), ok: true, epoch: "sleep-deferral-preview", revision: 1,
            control: Control(), protection: status.protection)
        reply.status = status
        let model = AppModel(preview: true, capabilities: capabilities,
            previewSession: controller, previewWorkService: { _ in reply },
            previewHelperReply: reply, previewDefaults: defaults)
        return (controller, model)
    }

    @MainActor
    func testCommonAndHelperOnlyRoutesShareConfirmedDeferralDescription() {
        for common in [true, false] {
            for reason in ["otherRequests", "observationUnavailable"] {
                let (controller, model) = fixture(common: common, reason: reason)
                defer { _ = controller?.end() }
                XCTAssertEqual(model.usesUserSession, common)
                XCTAssertEqual(model.presentation.title, endedTitle)
                XCTAssertEqual(model.presentation.subtitle, model.status?.sleepDeferralSummary)
                XCTAssertFalse(model.workSessionHolding)
            }
        }
    }

    @MainActor
    func testOldFutureAndInvalidHelperObservationsNeverDescribeCurrentDeferral() {
        let now = Date().timeIntervalSince1970
        for common in [true, false] {
            for timestamp in [now - 31, now + 60, Double.infinity, Double.nan] {
                let (controller, model) = fixture(common: common, mutateStatus: { $0.updatedAt = timestamp })
                defer { _ = controller?.end() }
                XCTAssertNotEqual(model.presentation.title, endedTitle)
            }
        }
    }

    @MainActor
    func testExpiredManualRequestDoesNotHideConfirmedDeferralObservations() {
        for reason in ["otherRequests", "observationUnavailable"] {
            let (controller, model) = fixture(reason: reason, mutateSession: {
                let now = ContinuousTime.now
                XCTAssertTrue($0.start(duration: ManualSessionPolicy.batteryMaximum, now: now))
                $0.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                          now: now + ManualSessionPolicy.batteryMaximum + 1, batteryPercent: 80)
            })
            defer { _ = controller?.end() }
            XCTAssertFalse(controller?.status.manualActive ?? true)
            XCTAssertNil(controller?.status.manualContinuousDeadline)
            // v3 budgets belong to each immutable request. Expiry consumes the
            // old request; a new explicit Start may create a fresh bounded one.
            XCTAssertEqual(controller?.status.manualBatteryRemaining, ManualSessionPolicy.batteryMaximum)
            XCTAssertTrue(controller?.status.canStart == true)
            XCTAssertNil(controller?.status.blockReason)
            XCTAssertTrue(controller?.hasConfirmedSessionAuthority == true)
            XCTAssertFalse(model.workSessionHolding)
            XCTAssertEqual(model.presentation.title, endedTitle)
            XCTAssertEqual(model.presentation.subtitle, model.status?.sleepDeferralSummary)
        }
    }

    @MainActor
    func testDeferralNeedsCurrentOwnedHelperAndConfirmedReleaseObservations() {
        let changes: [(String, (inout Status) -> Void)] = [
            ("override retained", { $0.ownsOverride = true }),
            ("override ownership unavailable", { $0.ownsOverride = nil }),
            ("sleep still disabled", { $0.sleepDisabled = true }),
            ("sleep setting unavailable", { $0.sleepOverrideObservationAvailable = false }),
            ("sleep setting omitted", { $0.sleepOverrideObservationAvailable = nil }),
            ("lid open", { $0.lidClosed = false }),
            ("lid unavailable", { $0.lidObservationAvailable = nil }),
            ("dark wake", { $0.fullWake = false }),
            ("wake unavailable", { $0.fullWake = nil }),
            ("power unavailable", { $0.power = .unknown }),
            ("power changed", { $0.power = .ac }),
            ("sleep events unavailable", { $0.systemPowerObservationAvailable = false }),
            ("sleep events omitted", { $0.systemPowerObservationAvailable = nil }),
            ("GUI authority unavailable", { $0.guiSessionAuthority = .unavailable }),
            ("GUI authority revoked", { $0.guiSessionAuthority = .revoked }),
            ("GUI authority omitted", { $0.guiSessionAuthority = nil }),
            ("app disconnected", { $0.appConnected = false }),
            ("owner omitted", { $0.appPID = nil }),
            ("different owner", { $0.appPID = ProcessInfo.processInfo.processIdentifier + 1 }),
            ("old build", { $0.build = TetherPaths.build - 1 }),
            ("old protocol", { $0.protection?.protocolVersion = 1 }),
            ("old coordinator", { $0.workSessionCoordinatorVersion = nil }),
            ("root ownership blocked", { $0.protection?.blockReason = "ownershipUnreadable" }),
            ("root release error", { $0.protection?.lastError = "powerVerificationFailed" }),
            ("unknown deferral", { $0.sleepDeferralReason = "/Users/alice/private-prompt" })
        ]
        for (label, change) in changes {
            let (controller, model) = fixture(mutateStatus: change)
            defer { _ = controller?.end() }
            XCTAssertNotEqual(model.presentation.title, endedTitle, label)
            XCTAssertFalse(model.presentation.subtitle.contains("/Users/alice/private-prompt"), label)
        }
    }

    @MainActor
    func testProtectionOffAndActiveWorkTakePriorityOverDeferral() {
        let (protected, safety) = fixture(mutateSession: {
            $0.update(power: .battery, thermal: 3, fullWake: true, controllingUser: true,
                      now: ContinuousTime.now, batteryPercent: 80)
        })
        defer { _ = protected?.end() }
        XCTAssertEqual(safety.presentation.title, L("Stopped for protection", "보호를 위해 중지됨"))
        XCTAssertEqual(safety.presentation.subtitle, protectionReason("thermal"))

        let (disabled, off) = fixture(mutateSession: { _ = $0.setEnabled(false) })
        defer { _ = disabled?.end() }
        XCTAssertEqual(off.presentation.title, L("All keep-awake stopped", "모두 중지됨"))
        XCTAssertEqual(off.presentation.subtitle,
            L("Resume rechecks automatic conditions. Ended manual keep-awake does not restart.",
              "중지를 해제하면 자동 조건을 다시 확인합니다. 종료된 수동 유지는 다시 시작하지 않습니다."))
        XCTAssertTrue(off.workPaused)

        let (active, work) = fixture(mutateSession: { XCTAssertTrue($0.start(duration: 600)) })
        defer { _ = active?.end() }
        XCTAssertTrue(work.workSessionHolding)
        XCTAssertEqual(work.presentation.title, L("Manual keep-awake active", "수동 유지 중"))

        let (uncontrolled, authority) = fixture(mutateSession: {
            $0.update(power: .battery, thermal: 0, fullWake: true, controllingUser: false,
                      now: ContinuousTime.now, batteryPercent: 80)
        })
        defer { _ = uncontrolled?.end() }
        XCTAssertFalse(uncontrolled?.hasConfirmedSessionAuthority ?? true)
        XCTAssertNotEqual(authority.presentation.title, endedTitle)
    }

    @MainActor
    func testUnsupportedAndNonLidPlatformsDoNotUseClosedLidDeferral() {
        for capabilities in [
            MacCapabilities(supportedPlatform: false, internalBattery: true, lid: true),
            MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false),
            MacCapabilities(supportedPlatform: true, internalBattery: nil, lid: nil)
        ] {
            let (controller, model) = fixture(capabilities: capabilities)
            defer { _ = controller?.end() }
            XCTAssertNotEqual(model.presentation.title, endedTitle)
        }
    }
}
