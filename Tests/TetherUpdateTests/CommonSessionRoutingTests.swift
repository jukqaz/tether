import XCTest
import Sparkle
@testable import Tether
import TetherCore

private final class CommonMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Float, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func register(defaults: [String: Any]) { registered.merge(defaults) { _, new in new } }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func float(forKey key: String) -> Float { object(forKey: key) as? Float ?? 0 }
    override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
    override func persistentDomain(forName name: String) -> [String: Any]? { values }
    override func setPersistentDomain(_ domain: [String: Any], forName name: String) { values = domain }
    override func removePersistentDomain(forName name: String) { values.removeAll() }
}

private final class CommonAssertionFixture: IdleAssertionBackend {
    var creates = 0
    var releases = 0
    var releaseCode: Int32 = 0
    private let native: IdleAssertionBackend?
    private(set) var createdID: UInt32?
    init(native: IdleAssertionBackend? = nil) { self.native = native }
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        creates += 1
        let result = native?.create(timeout: timeout) ?? (code: 0, id: UInt32(27))
        createdID = result.id; return result
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { native?.renew(id: id, timeout: timeout) ?? 0 }
    func level(id: UInt32) -> Int? {
        if let native { return native.level(id: id) }
        return 255
    }
    func release(id: UInt32) -> Int32 {
        releases += 1
        return releaseCode == 0 ? native?.release(id: id) ?? 0 : releaseCode
    }
}

@MainActor
private final class CommonServiceFixture {
    var requests: [ServiceRequest] = []
    var gate = WorkSessionLeaseGate()
    var rejected = false
    var reason: String?
    var control = Control()
    var revision: UInt64 = 1
    var coordinated = true
    var coordinatorVersion: Int? = WorkSessionLease.coordinatorVersion
    var helperBuild = TetherPaths.build
    var helperVersion = TetherPaths.version
    var sendsBridge = true
    var appPID = getpid()
    var protectionError: String?
    var preparation: WorkSessionPreparation?
    var stopRequested = false
    var connected = true
    var power = PowerSource.ac
    var rejectDetach = false
    var omitDetachEffect = false
    var nativeDisplayVerified: Bool? = false
    var displayTopology = DisplayTopology.none
    var lid: Bool? = false
    var sleepOverrideReadable = true
    var wake: Bool? = true
    var missingGrantError = "invalidWorkLease"
    var preparationFailure: String?
    var systemPowerObservationAvailable: Bool? = true
    var acknowledgesManualExtensions = false

    // Only consume the helper grant. Receipt validation belongs to the controller
    // and IPC tests; the app connection intentionally remains alive here.
    func consumeWorkGrant() {
        gate.end(); preparation = nil
    }

    func perform(_ source: ServiceRequest) throws -> ServiceReply {
        // Use the wire format, so tests do not bypass optional-field serialization.
        let request = try JSONDecoder().decode(ServiceRequest.self, from: JSONEncoder().encode(source))
        requests.append(request)
        switch request.action {
        case .prepareWorkSession:
            if let preparationFailure { throw ServiceFailure(preparationFailure) }
            guard request.epoch == "common-fixture", request.revision == revision else { throw ServiceFailure("staleRevision") }
            guard let lease = request.workSession, lease.reasons.isEmpty, lease.isValid(now: ContinuousTime.now) else {
                throw ServiceFailure("invalidWorkLease")
            }
            preparation = WorkSessionPreparation(sessionID: lease.sessionID, epoch: "common-fixture",
                revision: revision, expiresAt: ContinuousTime.now + IdleSessionPolicy.healthTTL)
            connected = true
        case .attachWorkSession, .syncWorkSession:
            if systemPowerObservationAvailable == false, request.workSession?.reasons.isEmpty == false {
                throw ServiceFailure("powerObservationUnavailable")
            }
            if request.action == .syncWorkSession, gate.current == nil { throw ServiceFailure(missingGrantError) }
            if rejected { throw ServiceFailure("invalidWorkLease") }
            if request.action == .attachWorkSession {
                guard request.epoch == "common-fixture", request.revision == revision else { throw ServiceFailure("staleRevision") }
                guard preparation?.sessionID == request.workSession?.sessionID else { throw ServiceFailure("invalidWorkLease") }
            }
            guard let lease = request.workSession,
                  gate.accept(lease, now: ContinuousTime.now, attaching: request.action == .attachWorkSession) else {
                throw ServiceFailure("invalidWorkLease")
            }
            control.enabled = lease.configuration.enabled && lease.configuration.automaticEnabled
            control.powerCondition = lease.configuration.condition
            control.automaticHoldMinutes = lease.configuration.automaticMinutes; control.limits = lease.configuration.limits
            coordinated = true; preparation = nil
        case .resume: reason = nil
        case .attachApp: connected = true; appPID = getpid()
        case .detachApp:
            guard connected else { throw ServiceFailure("notOwner") }
            if rejectDetach { throw ServiceFailure("powerVerificationFailed") }
            if !omitDetachEffect { gate.end(); preparation = nil; connected = false }
        case .snapshot: break
        default: XCTFail("Unexpected legacy command: \(request.action)")
        }
        return try JSONDecoder().decode(ServiceReply.self, from: JSONEncoder().encode(reply(id: request.id)))
    }
    func reply(id: UUID = UUID()) -> ServiceReply {
        let holding = reason == nil && !gate.reasons(now: ContinuousTime.now, power: power).isEmpty
        var status = Status(updatedAt: Date().timeIntervalSince1970, version: helperVersion,
            enabled: control.enabled, power: power, lidClosed: lid ?? false, sleepDisabled: holding && nativeDisplayVerified != true,
            lastEvent: nil, lastEventAt: nil, fullWake: wake, thermal: 0, batteryPercent: 80)
        status.lidObservationAvailable = lid != nil
        status.sleepOverrideObservationAvailable = sleepOverrideReadable
        status.build = helperBuild; status.workSessionCoordinatorVersion = coordinatorVersion
        status.systemPowerObservationAvailable = systemPowerObservationAvailable
        status.workSession = gate.current; status.ownsOverride = holding && nativeDisplayVerified != true
        status.appConnected = connected; status.appPID = connected ? appPID : nil; status.displayTopology = displayTopology
        status.externalDisplay = displayTopology.mayHaveExternal; status.nativeDisplayVerified = nativeDisplayVerified
        var protection = ProtectionState(); if let reason { protection.block(reason) }
        var value = ServiceReply(id: id, ok: true, epoch: "common-fixture", revision: revision, control: control,
            protection: ProtectionStatus(reason: reason, error: protectionError, dryRun: true))
        value.status = status
        value.workSessionBridge = WorkSessionBridge(coordinated: coordinated, automaticBudget: protection,
            manualBudget: nil, stopRequested: stopRequested)
        if acknowledgesManualExtensions, let lease = gate.current, let preparation = lease.extensionPreparation {
            value.workSessionBridge?.extensionPreparationReceipt = WorkSessionExtensionPreparationReceipt(
                sessionID: lease.sessionID, sequence: lease.sequence, observedAt: ContinuousTime.now,
                preparation: preparation)
        }
        if !sendsBridge {
            // Actual build 49 lacks the optional common/observation fields.
            value.workSessionBridge = nil; value.status?.fullWake = nil
            value.status?.lidObservationAvailable = nil; value.status?.sleepOverrideObservationAvailable = nil
            value.status?.systemPowerObservationAvailable = nil
        }
        value.workSessionPreparation = preparation
        return value
    }
}

@MainActor
private final class CommonRemovalFixture {
    let defaults: UserDefaults
    let domain: String
    var events: [String] = []
    var failureAt: String?
    var cancelAuthorization = false
    var beforeHelper: (() -> Void)?
    var beforeRecycle: (() async -> Void)?
    var helperPresent = true
    var loginItemPresent = true
    var cliPresent = true
    var appPresent = true
    var terminated = false

    init(defaults: UserDefaults, domain: String) {
        self.defaults = defaults; self.domain = domain
    }

    private func step(_ name: String) throws {
        events.append(name)
        if name == "removeHelper", cancelAuthorization { throw SystemIntegration.Failure.cancelled }
        if failureAt == name { throw SystemIntegration.Failure.message("Injected \(name) failure") }
    }

    var effects: AppModel.RemovalEffects {
        .init(removeHelper: {
            self.beforeHelper?()
            try self.step("removeHelper"); self.helperPresent = false
        }, removeLoginItem: {
            try self.step("removeLoginItem"); self.loginItemPresent = false
        }, removeUserCLI: {
            try self.step("removeUserCLI"); self.cliPresent = false
        }, recycleApp: {
            try self.step("recycleApp")
            await self.beforeRecycle?()
            self.appPresent = false
        }, removePreferences: {
            self.events.append("removePreferences")
            self.defaults.removePersistentDomain(forName: self.domain)
        }, terminate: {
            self.events.append("terminate"); self.terminated = true
        })
    }
}

final class CommonSessionRoutingTests: XCTestCase {
    private static let portable = MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true)
    private static let unreadable = MacCapabilities(supportedPlatform: true, internalBattery: nil, lid: nil)

    @MainActor
    func testUnavailableRootSleepEventsYieldOnlyConfirmedGeneralWorkAndKeepOffAndSleepBoundaries() async throws {
        for enabled in [false, true] {
            let defaults = CommonMemoryDefaults()
            let backend = CommonAssertionFixture()
            let service = CommonServiceFixture()
            service.coordinated = false; service.connected = false
            service.control.enabled = enabled; service.control.powerCondition = .ac
            service.systemPowerObservationAvailable = false
            weak var destination: AppModel?
            let model = AppModel(preview: true, capabilities: Self.portable,
                previewSessionBackend: backend, previewWorkService: { request in
                    // Production rereads the environment before preparing general
                    // work. Supply those facts without calling this Mac's sensors
                    // or creating a real assertion from an offscreen preview.
                    if request.action == .prepareWorkSession {
                        destination?.userSession?.update(power: .ac, thermal: 0, fullWake: true,
                            controllingUser: true, now: ContinuousTime.now, batteryPercent: 80)
                    }
                    return try service.perform(request)
                },
                previewHelperReply: service.reply(), previewDefaults: defaults)
            destination = model
            await wait { model.usesUserSession && service.requests.contains(where: { $0.action == .detachApp }) && !model.lidCommandPending }
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            let now = ContinuousTime.now
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now, batteryPercent: 80)
            XCTAssertEqual(model.workSessionHolding, enabled)
            XCTAssertFalse(model.coordinatingLid); XCTAssertFalse(model.clamshellActive)
            XCTAssertFalse(service.connected); XCTAssertNil(service.gate.current)
            XCTAssertTrue(service.requests.contains(where: { $0.action == .prepareWorkSession }))
            XCTAssertFalse(service.requests.contains(where: { [.attachWorkSession, .syncWorkSession].contains($0.action) }))
            XCTAssertNotNil(model.coordinatedLidError)
            if !enabled {
                XCTAssertFalse(controller.start(duration: 600, now: now + 1))
                XCTAssertTrue(controller.setEnabled(true))
            }
            XCTAssertTrue(controller.start(duration: 600, now: now + 1))
            controller.observeSystemSleep(observedAt: now + 2)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now + 3, batteryPercent: 80)
            XCTAssertFalse(controller.status.manualActive)
            XCTAssertNil(controller.status.until)
            XCTAssertEqual(controller.status.holding, enabled)
            let requestCount = service.requests.count
            model.refresh()
            await wait { service.requests.count > requestCount && !model.lidCommandPending }
            XCTAssertEqual(service.requests.count, requestCount + 1) // Read-only refresh; no repeated preparation.
            XCTAssertFalse(model.coordinatingLid)
        }
    }

    @MainActor
    func testUnavailableRootSleepEventsRequireReleaseAndPreserveLateProtection() async throws {
        for rejectRelease in [false, true] {
            let defaults = CommonMemoryDefaults()
            let backend = CommonAssertionFixture()
            let service = CommonServiceFixture()
            service.coordinated = false; service.connected = false
            service.systemPowerObservationAvailable = false; service.rejectDetach = rejectRelease
            weak var destination: AppModel?
            let model = AppModel(preview: true, capabilities: Self.portable,
                previewSessionBackend: backend, previewWorkService: { request in
                    if request.action == .prepareWorkSession {
                        destination?.userSession?.update(power: .ac, thermal: 0, fullWake: true,
                            controllingUser: true, now: ContinuousTime.now, batteryPercent: 80)
                    }
                    if request.action == .detachApp && !rejectRelease { service.reason = "thermal" }
                    return try service.perform(request)
                }, previewHelperReply: service.reply(), previewDefaults: defaults)
            destination = model
            await wait { service.requests.contains(where: { $0.action == .detachApp }) && !model.lidCommandPending }
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            XCTAssertFalse(model.workSessionHolding); XCTAssertEqual(backend.creates, 0)
            XCTAssertEqual(model.coordinatingLid, rejectRelease)
            XCTAssertEqual(service.connected, rejectRelease)
            if !rejectRelease { XCTAssertEqual(controller.status.blockReason, "thermal") }
        }
    }

    @MainActor
    func testRootObservationGapDoesNotEndGeneralWorkOrChangeManualDeadline() async throws {
        let (name, defaults, backend, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        model.startManualSession(minutes: 10)
        await wait { model.clamshellActive && service.gate.current?.manualDeadline != nil && !model.lidCommandPending }
        let deadline = controller.status.until, rootDeadline = service.gate.current?.manualDeadline
        let session = controller.sessionID
        service.lid = nil; service.sleepOverrideReadable = false; service.wake = nil
        model.refresh()
        await wait { model.snapshot.observedFullWake == nil && !model.lidCommandPending }
        XCTAssertNil(model.snapshot.observedLidClosed); XCTAssertNil(model.snapshot.observedSleepDisabled)
        XCTAssertFalse(model.clamshellActive); XCTAssertTrue(model.workSessionHolding)
        XCTAssertNotNil(model.lidObservationNotice)
        XCTAssertEqual(controller.sessionID, session); XCTAssertEqual(controller.status.until, deadline)
        XCTAssertEqual(service.gate.current?.manualDeadline, rootDeadline)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
        service.lid = false; service.sleepOverrideReadable = true; service.wake = true
        model.refresh()
        await wait { model.clamshellActive && !model.lidCommandPending }
        XCTAssertNil(model.lidObservationNotice)
        XCTAssertEqual(controller.sessionID, session); XCTAssertEqual(controller.status.until, deadline)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
    }

    @MainActor
    func testUnknownRootReadCannotReportNativeHandoff() async {
        let (name, defaults, _, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        model.startManualSession(minutes: 10)
        await wait { model.workSessionHolding && !model.lidCommandPending }
        service.nativeDisplayVerified = true; service.displayTopology = .externalUnverified
        service.wake = nil; service.lid = nil
        model.refresh()
        await wait { model.snapshot.observedFullWake == nil && !model.lidCommandPending }
        XCTAssertFalse(model.snapshot.usesNativeClamshell)
        XCTAssertTrue(model.workSessionHolding)
    }

    @MainActor
    func testNativeDisplayHandoffAndVirtualReturnKeepTheSameGeneralSessionAndDeadline() async throws {
        let (name, defaults, backend, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        model.startManualSession(minutes: 10)
        await wait { model.clamshellActive && service.gate.current?.manualDeadline != nil && !model.lidCommandPending }
        let deadline = controller.status.until, session = controller.sessionID
        let rootDeadline = service.gate.current?.manualDeadline
        service.nativeDisplayVerified = true; service.displayTopology = .externalWithVirtual
        model.refresh()
        await wait { model.snapshot.usesNativeClamshell && !model.lidCommandPending }
        XCTAssertFalse(model.clamshellActive); XCTAssertTrue(model.workSessionHolding)
        XCTAssertEqual(controller.status.until, deadline); XCTAssertEqual(controller.sessionID, session)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
        XCTAssertEqual(service.gate.current?.manualDeadline, rootDeadline)
        service.nativeDisplayVerified = false; service.displayTopology = .virtualOnly
        model.refresh()
        await wait { model.clamshellActive && !model.lidCommandPending }
        XCTAssertFalse(model.snapshot.usesNativeClamshell); XCTAssertTrue(model.workSessionHolding)
        XCTAssertEqual(controller.status.until, deadline); XCTAssertEqual(controller.sessionID, session)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
        service.nativeDisplayVerified = nil; service.displayTopology = .externalUnverified
        model.refresh()
        await wait { !model.lidCommandPending }
        XCTAssertFalse(model.snapshot.usesNativeClamshell)
    }

    @MainActor
    func testRuntimeSuccessfulDetachAckNeedsObservedReleaseBeforeRecovery() async {
        var observed = Self.portable
        let (name, defaults, _, controller, service, model) = fixture(capabilityProbe: { observed })
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        model.startManualSession(minutes: 10)
        await wait { model.clamshellActive && !model.lidCommandPending }
        service.omitDetachEffect = true
        observed = Self.unreadable; model.refresh()
        await wait { service.requests.contains { $0.action == .detachApp } }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.lidReleasePending); XCTAssertFalse(model.clamshellActive)
        XCTAssertNotNil(model.coordinatedLidError); XCTAssertTrue(model.workSessionHolding)
        XCTAssertTrue(model.generalSessionDetail.contains("확인"))
        let receipt = model.userCommandReply(UserSessionRequest())
        XCTAssertEqual(receipt.lidSupport, .pending); XCTAssertNotNil(receipt.lidError)
        XCTAssertTrue(receipt.status?.holding == true)
        observed = Self.portable; model.refresh()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.requests.filter { $0.action == .prepareWorkSession }.count, 1)
        service.omitDetachEffect = false; model.refresh()
        await wait { model.clamshellActive && !model.lidCommandPending }
    }

    @MainActor
    func testRuntimeAlreadyDetachedPeerNeedsFreshProofInsteadOfRepeatingAMutation() async throws {
        var observed = Self.portable
        let (name, defaults, backend, controller, service, model) = fixture(capabilityProbe: { observed })
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        model.startManualSession(minutes: 10)
        await wait { model.clamshellActive && !model.lidCommandPending }
        _ = try service.perform(ServiceRequest(.detachApp))
        observed = Self.unreadable; model.refresh()
        await wait { !model.lidCommandPending }
        XCTAssertNil(model.coordinatedLidError); XCTAssertEqual(service.requests.last?.action, .snapshot)
        XCTAssertFalse(service.connected); XCTAssertTrue(model.workSessionHolding)
        XCTAssertEqual(backend.releases, 0)
    }

    @MainActor
    func testRuntimeRecoveryAddsLidSupportWithoutRecreatingGeneralWork() async {
        var observed = Self.unreadable
        let (name, defaults, backend, controller, service, model) = fixture(
            initialCapabilities: observed, capabilityProbe: { observed })
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        model.startManualSession(minutes: 10)
        let deadline = model.manualSessionUntil
        XCTAssertTrue(model.workSessionHolding); XCTAssertEqual(service.requests.count, 0)
        observed = Self.portable; model.refresh()
        await wait { model.clamshellActive }
        XCTAssertEqual(model.capabilities, Self.portable)
        XCTAssertTrue(model.userSession === controller); XCTAssertEqual(model.manualSessionUntil, deadline)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
        XCTAssertEqual(service.requests.filter { $0.action == .prepareWorkSession }.count, 1)
        XCTAssertEqual(service.gate.current?.sessionID, controller.sessionID)
    }

    @MainActor
    func testRuntimeCapabilityLossReleasesOnlyLidAndRecoveryKeepsTheOriginalDeadline() async {
        for unavailable in [Self.unreadable,
                            MacCapabilities(supportedPlatform: true, internalBattery: true, lid: nil),
                            MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false)] {
            var observed = Self.portable
            let (name, defaults, backend, controller, service, model) = fixture(capabilityProbe: { observed })
            defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
            await wait { service.gate.current != nil }
            model.startManualSession(minutes: 10)
            await wait { model.clamshellActive }
            let deadline = model.manualSessionUntil
            observed = unavailable; model.refresh()
            await wait { !service.connected && !model.lidCommandPending }
            XCTAssertEqual(model.capabilities, unavailable); XCTAssertFalse(model.clamshellActive)
            XCTAssertTrue(model.workSessionHolding); XCTAssertTrue(model.userSession === controller)
            XCTAssertEqual(model.manualSessionUntil, deadline); XCTAssertEqual(backend.releases, 0)
            XCTAssertNil(service.gate.current)
            observed = Self.portable; model.refresh()
            await wait { model.clamshellActive }
            XCTAssertEqual(model.manualSessionUntil, deadline); XCTAssertEqual(backend.creates, 1)
            let prepares = service.requests.filter { $0.action == .prepareWorkSession }.count
            let detaches = service.requests.filter { $0.action == .detachApp }.count
            for _ in 0..<3 { model.refresh(); await Task.yield() }
            await wait { !model.lidCommandPending }
            XCTAssertEqual(service.requests.filter { $0.action == .prepareWorkSession }.count, prepares)
            XCTAssertEqual(service.requests.filter { $0.action == .detachApp }.count, detaches)
            XCTAssertEqual(prepares, 2); XCTAssertEqual(detaches, 1)
        }
    }

    @MainActor
    func testRuntimeLossBeforePreparationAckCannotAttachAnOldLease() async {
        var observed = Self.portable
        var destination: AppModel?
        var changed = false
        let (name, defaults, backend, controller, service, model) = fixture(capabilityProbe: { observed }, serviceHook: { request, _ in
            if request.action == .prepareWorkSession, !changed {
                changed = true; observed = Self.unreadable; destination?.refresh()
            }
        })
        destination = model
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { changed && !model.lidCommandPending }
        XCTAssertEqual(model.capabilities, Self.unreadable); XCTAssertFalse(service.connected)
        XCTAssertEqual(service.requests.filter { $0.action == .attachWorkSession }.count, 0)
        XCTAssertNil(service.preparation); XCTAssertNil(service.gate.current)
        XCTAssertEqual(backend.creates, 0); XCTAssertTrue(model.userSession === controller)
    }

    @MainActor
    func testRuntimeLossBeforeAttachAckDrainsTheAlreadyAcceptedRootGrant() async {
        var observed = Self.portable
        var destination: AppModel?
        var changed = false
        let (name, defaults, backend, controller, service, model) = fixture(capabilityProbe: { observed }, serviceHook: { request, _ in
            if request.action == .attachWorkSession, !changed {
                changed = true; observed = Self.unreadable; destination?.refresh()
            }
        })
        destination = model
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        model.startManualSession(minutes: 10)
        let deadline = model.manualSessionUntil
        await wait { changed && !model.lidCommandPending }
        XCTAssertEqual(model.capabilities, Self.unreadable); XCTAssertFalse(service.connected)
        XCTAssertNil(service.gate.current); XCTAssertFalse(model.clamshellActive)
        XCTAssertTrue(model.workSessionHolding); XCTAssertEqual(model.manualSessionUntil, deadline)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
        XCTAssertEqual(service.requests.filter { $0.action == .attachWorkSession }.count, 1)
        XCTAssertEqual(service.requests.last?.action, .detachApp)
    }

    @MainActor
    func testRuntimeLossAndImmediateRecoveryInvalidateTheEarlierPreparation() async {
        var observed = Self.portable
        var destination: AppModel?
        var changed = false
        let (name, defaults, backend, controller, service, model) = fixture(capabilityProbe: { observed }, serviceHook: { request, _ in
            if request.action == .prepareWorkSession, !changed {
                changed = true
                observed = Self.unreadable; destination?.refresh()
                observed = Self.portable; destination?.refresh()
            }
        })
        destination = model
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        model.startManualSession(minutes: 10)
        let deadline = model.manualSessionUntil
        await wait { model.clamshellActive && !model.lidCommandPending }
        let actions = service.requests.map(\.action)
        let prepares = actions.indices.filter { actions[$0] == .prepareWorkSession }
        XCTAssertEqual(prepares.count, 2)
        if prepares.count == 2, let detach = actions.firstIndex(of: .detachApp) {
            XCTAssertLessThan(prepares[0], detach); XCTAssertLessThan(detach, prepares[1])
        } else { XCTFail("A stale preparation must be detached before preparing again") }
        XCTAssertEqual(actions.filter { $0 == .attachWorkSession }.count, 1)
        XCTAssertTrue(model.userSession === controller); XCTAssertEqual(model.manualSessionUntil, deadline)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
    }

    @MainActor
    func testRuntimeRecoveryCannotRenewUntilFailedOwnReleaseIsConfirmed() async {
        var observed = Self.portable
        let (name, defaults, backend, controller, service, model) = fixture(capabilityProbe: { observed })
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        model.startManualSession(minutes: 10)
        await wait { model.clamshellActive && !model.lidCommandPending }
        let deadline = model.manualSessionUntil
        service.rejectDetach = true
        observed = Self.unreadable; model.refresh()
        await wait { service.requests.contains { $0.action == .detachApp } && model.coordinatedLidError != nil }
        let accepted = service.gate.current
        XCTAssertNotNil(accepted?.expiry); XCTAssertFalse(model.clamshellActive)
        observed = Self.portable; model.refresh()
        await wait { service.requests.filter { $0.action == .detachApp }.count >= 2 }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(service.gate.current, accepted, "No root renewal is allowed while release is unconfirmed")
        XCTAssertEqual(service.requests.filter { $0.action == .prepareWorkSession }.count, 1)
        XCTAssertTrue(model.workSessionHolding); XCTAssertEqual(model.manualSessionUntil, deadline)
        service.rejectDetach = false; model.refresh()
        await wait { model.clamshellActive && !model.lidCommandPending }
        XCTAssertEqual(service.requests.filter { $0.action == .prepareWorkSession }.count, 2)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
    }

    @MainActor
    func testRuntimeBatteryTransitionsPreserveConsumptionSuppressionAndExplicitOff() async throws {
        var observed = Self.portable
        let (name, defaults, backend, controller, service, model) = fixture(capabilityProbe: { observed }, power: .battery)
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        model.setPowerCondition(.any); model.setAutomaticMinutes(30)
        model.setAutomaticEnabled(true); model.startManualSession(minutes: 10)
        await wait { model.clamshellActive && !model.lidCommandPending }
        let deadline = model.manualSessionUntil; let reservation = model.batteryHoldUntil
        let saved = try JSONDecoder().decode(IdleSessionSettings.self, from: XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey)))
        observed = Self.unreadable; model.refresh()
        await wait { !service.connected && !model.lidCommandPending }
        observed = Self.portable; model.refresh()
        await wait { model.clamshellActive && !model.lidCommandPending }
        let recovered = try JSONDecoder().decode(IdleSessionSettings.self, from: XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey)))
        XCTAssertEqual(model.manualSessionUntil, deadline); XCTAssertEqual(model.batteryHoldUntil, reservation)
        XCTAssertNil(saved.automaticBatteryBudget); XCTAssertNil(saved.manualBatteryBudget)
        XCTAssertEqual(saved.runtimeMarkers?.automaticActivation?.batteryConsumed, true,
            "Explicit battery automation captures one first-use allowance; capability recovery must not refill it")
        XCTAssertEqual(recovered.runtimeMarkers, saved.runtimeMarkers)
        XCTAssertEqual(recovered.automaticBatteryBudget, saved.automaticBatteryBudget)
        XCTAssertEqual(recovered.manualBatteryBudget, saved.manualBatteryBudget)
        XCTAssertEqual(recovered.batterySuppressed, saved.batterySuppressed)
        XCTAssertEqual(recovered.automaticSuppressed, saved.automaticSuppressed)
        model.setEnabled(false)
        await wait { !model.lidCommandPending }
        observed = Self.unreadable; model.refresh()
        await wait { !service.connected && !model.lidCommandPending }
        observed = Self.portable; model.refresh()
        await wait { service.connected && !model.lidCommandPending }
        XCTAssertFalse(model.enabled); XCTAssertFalse(model.manualSessionActive); XCTAssertFalse(model.workSessionHolding)
        XCTAssertNil(model.batteryHoldUntil); XCTAssertNil(service.gate.current?.expiry)
        XCTAssertEqual(service.gate.current?.reasons, [])
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 1)
    }

    @MainActor
    func testKnownLegacyRootOffPreventsEarlyGeneralAcquisitionAndExplicitResumeAllowsManual() async throws {
        for startManual in [false, true] {
            let name = "TetherLegacyOff." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            var saved = IdleSessionSettings(); saved.version = 3; saved.automaticEnabled = true
            defaults.set(try JSONEncoder().encode(saved), forKey: UserSessionController.preferenceKey)
            let backend = CommonAssertionFixture()
            let service = CommonServiceFixture(); service.coordinated = false
            service.control.enabled = false; service.control.powerCondition = .ac
            let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil,
                legacyControl: service.control, requiresRootHandoff: true)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            XCTAssertEqual(backend.creates, 0); XCTAssertFalse(controller.status.holding)
            XCTAssertFalse(controller.start(duration: nil))
            if startManual {
                XCTAssertTrue(controller.setEnabled(true)); XCTAssertTrue(controller.start(duration: nil))
            }
            let model = AppModel(preview: true, capabilities: Self.portable,
                previewSession: controller, previewWorkService: { try service.perform($0) },
                previewHelperReply: service.reply(), previewDefaults: defaults)
            await wait { service.gate.current != nil }
            XCTAssertEqual(model.enabled, startManual); XCTAssertEqual(model.workSessionHolding, startManual)
            XCTAssertEqual(model.manualSessionActive, startManual)
            XCTAssertEqual(backend.creates, startManual ? 1 : 0)
            XCTAssertFalse(controller.status.automaticEnabled)
            _ = controller.end(); defaults.removePersistentDomain(forName: name)
        }
    }

    @MainActor
    func testDelayedSuccessfulPreparationIsRecheckedBeforeNativeActivation() async {
        let name = "TetherDelayedPrepareAck." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = CommonAssertionFixture()
        let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, requiresRootHandoff: true)
        defer { _ = controller.end() }
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        let service = CommonServiceFixture(); service.coordinated = false
        var changedAfterAcknowledgement = false
        let model = AppModel(preview: true,
            capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller, previewWorkService: { request in
                let reply = try service.perform(request)
                if request.action == .prepareWorkSession, !changedAfterAcknowledgement {
                    changedAfterAcknowledgement = true
                    service.control.enabled = false; service.revision += 1; service.stopRequested = true
                }
                return reply
            }, previewHelperReply: service.reply(), previewDefaults: defaults)
        await wait { service.gate.current != nil }
        XCTAssertEqual(service.requests.filter { $0.action == .prepareWorkSession }.count, 2)
        XCTAssertEqual(backend.creates, 0, "An old successful ACK must not briefly create native work")
        XCTAssertFalse(model.enabled); XCTAssertFalse(model.workSessionHolding)
        XCTAssertFalse(service.control.enabled); XCTAssertEqual(service.gate.current?.reasons, [])
    }
    @MainActor
    func testStalePreparationCannotActivateAnOldRootChoiceAfterANewerStop() async throws {
        let name = "TetherPreparedHandoff." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var previous = IdleSessionSettings(); previous.version = 2; previous.automaticEnabled = true
        defaults.set(try JSONEncoder().encode(previous), forKey: UserSessionController.preferenceKey)
        let backend = CommonAssertionFixture()
        let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, requiresRootHandoff: true)
        defer { _ = controller.end() }
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        let service = CommonServiceFixture(); service.coordinated = false
        var releasePreparation = false
        var enteredPreparation = false
        let model = AppModel(preview: true,
            capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller, previewWorkService: { request in
                if request.action == .prepareWorkSession, !enteredPreparation {
                    enteredPreparation = true
                    while !releasePreparation { await Task.yield() }
                }
                return try service.perform(request)
            }, previewHelperReply: service.reply(), previewDefaults: defaults)
        await wait { enteredPreparation }
        XCTAssertEqual(backend.creates, 1); XCTAssertTrue(model.workSessionHolding)
        service.control.enabled = false; service.revision += 1
        releasePreparation = true
        await wait { service.gate.current != nil }
        XCTAssertEqual(service.requests.filter { $0.action == .prepareWorkSession }.count, 2)
        XCTAssertFalse(model.enabled); XCTAssertFalse(model.workSessionHolding)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 1)
        XCTAssertEqual(service.gate.current?.reasons, [])
        XCTAssertFalse(service.control.enabled)
    }

    @MainActor
    func testAnExistingUneditedGeneralControllerAdoptsOnlyConfirmedExplicitLegacyChoices() async throws {
        for condition: PowerCondition? in [.battery, nil] {
            let name = "TetherLateHandoff." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let backend = CommonAssertionFixture()
            let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil)
            defer { _ = controller.end() }
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            let service = CommonServiceFixture(); service.coordinated = false
            service.control.powerCondition = condition; service.control.automaticHoldMinutes = 180
            service.control.limits = UserLimits(batteryFloor: 40, maxHoldHours: 2)
            let model = AppModel(preview: true, capabilities: Self.portable,
                previewSession: controller, previewWorkService: { try service.perform($0) },
                previewHelperReply: service.reply(), previewDefaults: defaults)
            await wait { service.gate.current != nil }
            XCTAssertTrue(model.userSession === controller, "Executor availability must not reconstruct an active policy")
            XCTAssertFalse(controller.status.automaticEnabled, "Legacy battery-only and both-power automatic choices do not create a new AC-only opt-in")
            XCTAssertEqual(model.powerCondition, .ac)
            XCTAssertEqual(model.automaticHoldMinutes, 120); XCTAssertEqual(model.batteryFloor, 40)
            XCTAssertFalse(model.workSessionHolding); XCTAssertEqual(backend.creates, 0)
            let saved = try JSONDecoder().decode(IdleSessionSettings.self,
                from: XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey)))
            XCTAssertEqual(saved.legacyRootConfigurationPending, false)
            XCTAssertNil(saved.manualBatteryBudget); XCTAssertNil(model.manualSessionUntil)
        }
    }

    @MainActor
    func testGuiOffDuringPreparationWinsAndRemainsOffAfterRestart() async throws {
        let name = "TetherOffDuringHandoff." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = CommonAssertionFixture()
        let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, requiresRootHandoff: true)
        defer { _ = controller.end() }
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        let service = CommonServiceFixture(); service.coordinated = false
        var releasePreparation = false; var enteredPreparation = false
        let model = AppModel(preview: true,
            capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller, previewWorkService: { request in
                if request.action == .prepareWorkSession {
                    enteredPreparation = true
                    while !releasePreparation { await Task.yield() }
                }
                return try service.perform(request)
            }, previewHelperReply: service.reply(), previewDefaults: defaults)
        await wait { enteredPreparation }
        model.setEnabled(false); releasePreparation = true
        await wait { service.gate.current != nil }
        XCTAssertFalse(model.enabled); XCTAssertEqual(backend.creates, 0)
        XCTAssertEqual(service.gate.current?.reasons, []); XCTAssertFalse(service.control.enabled)
        XCTAssertTrue(controller.end())
        let restarted = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil,
            legacyControl: Control(), legacyBridge: WorkSessionBridge(coordinated: false,
                automaticBudget: ProtectionState(), manualBudget: nil))
        restarted.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        XCTAssertFalse(restarted.status.enabled); XCTAssertFalse(restarted.status.holding)
        XCTAssertEqual(backend.creates, 0); XCTAssertTrue(restarted.end())
    }

    @MainActor
    func testPreparationRetriesAreBoundedAndUnverifiedReceiptDoesNotAcquire() async {
        for invalidReceipt in [false, true] {
            let name = "TetherInvalidHandoff." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            let backend = CommonAssertionFixture()
            let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, requiresRootHandoff: true)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            let service = CommonServiceFixture(); service.coordinated = false
            let model = AppModel(preview: true,
                capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: controller, previewWorkService: { request in
                    if request.action == .prepareWorkSession, !invalidReceipt { service.revision += 1 }
                    var reply = try service.perform(request)
                    if request.action == .prepareWorkSession, invalidReceipt { reply.workSessionPreparation?.expiresAt = .infinity }
                    return reply
                }, previewHelperReply: service.reply(), previewDefaults: defaults)
            await wait { model.coordinatedLidError != nil && service.requests.filter { $0.action == .prepareWorkSession }.count == (invalidReceipt ? 1 : 8) }
            XCTAssertNil(service.gate.current); XCTAssertFalse(model.workSessionHolding); XCTAssertEqual(backend.creates, 0)
            _ = controller.end(); defaults.removePersistentDomain(forName: name)
        }
    }

    @MainActor
    func testOtherCommonProtocolVersionsNeverFallBackToLegacyControl() async {
        for version in [1, 2, 3, 4, 5, WorkSessionLease.coordinatorVersion + 1] {
            let name = "TetherProtocolHandoff." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            let backend = CommonAssertionFixture()
            let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            let service = CommonServiceFixture(); service.coordinatorVersion = version
            let model = AppModel(preview: true,
                capabilities: MacCapabilities(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: controller, previewWorkService: { try service.perform($0) },
                previewHelperReply: service.reply(), previewDefaults: defaults)
            model.startUntimedSession()
            XCTAssertTrue(model.workSessionHolding); XCTAssertFalse(model.clamshellActive)
            XCTAssertTrue(model.helperOutdated); XCTAssertFalse(model.coordinatingLid)
            XCTAssertEqual(service.requests.count, 0)
            _ = controller.end(); defaults.removePersistentDomain(forName: name)
        }
    }

    @MainActor
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Common session acknowledgement did not arrive", file: file, line: line)
    }
    @MainActor
    private func fixture(defaults injectedDefaults: UserDefaults? = nil,
                         initialCapabilities: MacCapabilities = CommonSessionRoutingTests.portable,
                         capabilityProbe: (() -> MacCapabilities)? = nil, power: PowerSource = .ac,
                         serviceHook: ((ServiceRequest, ServiceReply) -> Void)? = nil,
                         updateTermination: (() -> Bool)? = nil,
                         native: IdleAssertionBackend? = nil,
                         coordinatorPath: String? = nil) -> (String, UserDefaults, CommonAssertionFixture, UserSessionController, CommonServiceFixture, AppModel) {
        let name = "TetherCommonSessionTests." + UUID().uuidString
        let defaults = injectedDefaults ?? UserDefaults(suiteName: name)!
        let backend = CommonAssertionFixture(native: native)
        let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil)
        controller.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        let service = CommonServiceFixture()
        service.power = power
        let model = AppModel(preview: true,
            capabilities: initialCapabilities,
            previewSession: controller, previewWorkService: { request in
                let reply = try service.perform(request); serviceHook?(request, reply); return reply
            }, previewHelperReply: service.reply(), previewDefaults: defaults, previewCoordinatorPath: coordinatorPath,
            previewCapabilitiesProbe: capabilityProbe,
            previewUpdateTermination: updateTermination)
        return (name, defaults, backend, controller, service, model)
    }

    @MainActor
    func testAppNegotiatesOnceAndKeepsManualAndAutomaticReasonsIndependent() async throws {
        let (name, defaults, backend, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        XCTAssertEqual(service.requests.first?.action, .prepareWorkSession)
        XCTAssertEqual(service.requests.dropFirst().first?.action, .snapshot)
        XCTAssertEqual(service.requests.dropFirst(2).first?.action, .attachWorkSession)
        XCTAssertFalse(model.workSessionHolding); XCTAssertFalse(model.clamshellActive)
        controller.setAutomatic(true)
        await wait { model.clamshellActive }
        model.startUntimedSession()
        await wait { Set(service.gate.current?.reasons ?? []) == Set([.automatic, .manual]) }
        model.endManualSession()
        await wait { service.gate.current?.reasons == [.automatic] }
        XCTAssertTrue(model.workSessionHolding); XCTAssertTrue(model.clamshellActive)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
        controller.setAutomatic(false)
        await wait { service.gate.current?.reasons.isEmpty == true }
        XCTAssertFalse(model.workSessionHolding); XCTAssertFalse(model.clamshellActive)
        XCTAssertEqual(backend.releases, 1)
        let count = service.requests.count
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(service.requests.count, count, "A reply must not cause an endless renewal loop")
        XCTAssertEqual(service.requests.filter { $0.action == .attachWorkSession }.count, 1)
    }

    @MainActor
    func testConsumedHelperGrantReattachesWithoutRecreatingTheGeneralSessionOrManualDeadline() async throws {
        for code in ["invalidWorkLease", "coordinatorRequired", "staleRevision"] {
            let (_, _, backend, controller, service, model) = fixture(defaults: CommonMemoryDefaults())
            defer { _ = controller.end() }
            await wait { service.gate.current != nil && !model.lidCommandPending }
            model.startManualSession(minutes: 10)
            await wait { service.gate.current?.manualDeadline != nil && model.clamshellActive && !model.lidCommandPending }
            let before = try XCTUnwrap(service.gate.current)
            let sessionID = controller.sessionID
            let startedAt = controller.status.manualStartedAt
            let deadline = try XCTUnwrap(controller.status.manualContinuousDeadline)
            let assertionID = backend.createdID
            let requestCount = service.requests.count
            let preparationCount = service.requests.filter { $0.action == .prepareWorkSession }.count
            let attachmentCount = service.requests.filter { $0.action == .attachWorkSession }.count
            service.missingGrantError = code
            service.consumeWorkGrant()
            XCTAssertNil(service.reply().status?.workSession, code)
            XCTAssertTrue(service.reply().status?.appConnected == true, code)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            await wait { service.requests.filter { $0.action == .attachWorkSession }.count == attachmentCount + 1
                && service.gate.current?.sessionID == sessionID && !model.lidCommandPending }
            XCTAssertEqual(service.requests.filter { $0.action == .prepareWorkSession }.count, preparationCount + 1, code)
            XCTAssertEqual(Array(service.requests.dropFirst(requestCount).prefix(5).map(\.action)),
                           [.syncWorkSession, .snapshot, .prepareWorkSession, .snapshot, .attachWorkSession], code)
            let reattached = try XCTUnwrap(service.gate.current)
            XCTAssertEqual(reattached.sessionID, before.sessionID, code)
            XCTAssertEqual(reattached.manualDeadline, before.manualDeadline, code)
            XCTAssertEqual(reattached.reasons, before.reasons, code)
            XCTAssertTrue(model.userSession === controller, code)
            XCTAssertEqual(controller.sessionID, sessionID, code)
            XCTAssertEqual(controller.status.manualStartedAt, startedAt, code)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline, code)
            XCTAssertEqual(model.userSessionStatus?.manualContinuousDeadline, deadline, code)
            XCTAssertTrue(model.workSessionHolding && model.manualSessionActive && model.clamshellActive, code)
            XCTAssertNil(model.coordinatedLidError, code)
            XCTAssertEqual(backend.createdID, assertionID, code)
            XCTAssertEqual(backend.creates, 1, code); XCTAssertEqual(backend.releases, 0, code)
        }
    }

    @MainActor
    func testConsumedHelperGrantRepreparationStopsAfterEightAttemptsWithoutEndingGeneralWork() async throws {
        let (_, _, backend, controller, service, model) = fixture(defaults: CommonMemoryDefaults())
        defer { _ = controller.end() }
        await wait { service.gate.current != nil && !model.lidCommandPending }
        model.startManualSession(minutes: 10)
        await wait { service.gate.current?.manualDeadline != nil && model.clamshellActive && !model.lidCommandPending }
        let sessionID = controller.sessionID
        let startedAt = controller.status.manualStartedAt
        let deadline = try XCTUnwrap(controller.status.manualContinuousDeadline)
        let preparationCount = service.requests.filter { $0.action == .prepareWorkSession }.count
        let attachmentCount = service.requests.filter { $0.action == .attachWorkSession }.count
        service.consumeWorkGrant(); service.preparationFailure = "staleRevision"
        XCTAssertNil(service.reply().status?.workSession)
        XCTAssertTrue(service.reply().status?.appConnected == true)
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        await wait { service.requests.filter { $0.action == .prepareWorkSession }.count == preparationCount + 8
            && model.coordinatedLidError != nil && !model.lidCommandPending }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(service.requests.filter { $0.action == .prepareWorkSession }.count, preparationCount + 8)
        XCTAssertEqual(service.requests.filter { $0.action == .attachWorkSession }.count, attachmentCount)
        XCTAssertNil(service.gate.current)
        XCTAssertTrue(service.connected)
        XCTAssertFalse(model.clamshellActive)
        XCTAssertTrue(model.workSessionHolding && model.manualSessionActive)
        XCTAssertTrue(model.userSession === controller)
        XCTAssertEqual(controller.sessionID, sessionID)
        XCTAssertEqual(controller.status.manualStartedAt, startedAt)
        XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
        XCTAssertEqual(model.userSessionStatus?.manualContinuousDeadline, deadline)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
    }

    @MainActor
    func testRejectedLidRequestDoesNotStopVerifiedGeneralWork() async {
        let (name, defaults, _, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        service.rejected = true
        model.startUntimedSession()
        await wait { model.coordinatedLidError != nil }
        XCTAssertTrue(model.workSessionHolding); XCTAssertTrue(model.manualSessionActive)
        XCTAssertFalse(model.clamshellActive); XCTAssertNil(model.protection?.blockReason)
        if case .lid = model.problem {} else { XCTFail("A lid failure must be shown separately from general work") }
        XCTAssertEqual(service.requests.last?.action, .snapshot)
    }

    @MainActor
    func testLidProtectionKeepsGeneralWorkAndExplicitResumeClearsItButThermalStopsBoth() async {
        let (name, defaults, backend, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        service.reason = "displayConflict"
        model.startUntimedSession()
        await wait { model.coordinatedLidBlockReason == "displayConflict" }
        XCTAssertTrue(model.workSessionHolding); XCTAssertFalse(model.clamshellActive)
        XCTAssertNil(model.protection?.blockReason); XCTAssertNotNil(model.coordinatedLidError)
        model.setEnabled(true)
        await wait { model.clamshellActive }
        XCTAssertTrue(service.requests.contains { $0.action == .resume })
        service.reason = "thermal"
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: ContinuousTime.now)
        await wait { model.protection?.blockReason == "thermal" && !model.workSessionHolding }
        XCTAssertFalse(model.manualSessionActive); XCTAssertFalse(model.clamshellActive)
        XCTAssertEqual(backend.releases, 1)
    }

    @MainActor
    func testQuitRejectedByLidServicePreservesLiveWorkDeadlineAndUsability() async throws {
        for unverifiedAcknowledgement in [false, true] {
            let (name, defaults, backend, controller, service, model) = fixture()
            defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
            await wait { service.gate.current != nil }
            model.startManualSession(minutes: 10)
            await wait { service.gate.current?.manualDeadline != nil }
            let deadline = try XCTUnwrap(controller.status.until)
            let session = controller.sessionID
            let saved = defaults.data(forKey: UserSessionController.preferenceKey)
            service.rejectDetach = !unverifiedAcknowledgement
            service.omitDetachEffect = unverifiedAcknowledgement
            let quit = await model.prepareToQuit()
            XCTAssertFalse(quit)
            XCTAssertTrue(model.acceptingUserCommands)
            XCTAssertNotNil(model.errorText)
            XCTAssertTrue(controller.status.holding)
            XCTAssertTrue(controller.status.manualActive)
            XCTAssertTrue(controller.status.canStart)
            XCTAssertEqual(controller.status.until, deadline)
            XCTAssertEqual(controller.sessionID, session)
            XCTAssertEqual(backend.releases, 0)
            XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), saved)
            XCTAssertFalse(controller.extend(duration: 60))
            XCTAssertEqual(try XCTUnwrap(controller.status.until), deadline)
            XCTAssertEqual(backend.creates, 1)
            service.rejectDetach = false; service.omitDetachEffect = false
            let retried = await model.prepareToQuit()
            XCTAssertTrue(retried)
            XCTAssertNil(service.gate.current)
            XCTAssertEqual(backend.releases, 1)
            XCTAssertFalse(controller.status.holding)
            XCTAssertNil(controller.status.until)
        }
    }

    @MainActor
    func testOwnLidReleaseIsConfirmedWhileGeneralWorkIsStillRunning() async {
        var subject: UserSessionController?
        var assertion: CommonAssertionFixture?
        var detachChecks = 0
        let (name, defaults, backend, controller, service, model) = fixture(serviceHook: { request, _ in
            guard request.action == .detachApp else { return }
            detachChecks += 1
            XCTAssertTrue(subject?.status.holding == true)
            XCTAssertTrue(subject?.status.manualActive == true)
            XCTAssertEqual(assertion?.releases, 0)
        })
        subject = controller; assertion = backend
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        model.startManualSession(minutes: 10)
        await wait { service.gate.current?.manualDeadline != nil }
        let quit = await model.prepareToQuit()
        XCTAssertTrue(quit)
        XCTAssertEqual(detachChecks, 1)
        XCTAssertNil(service.gate.current)
        XCTAssertEqual(backend.releases, 1)
        XCTAssertFalse(controller.status.holding)
    }

    @MainActor
    func testFailedNativeReleaseAfterLidDetachRemainsRetriableWithoutNewRequests() async {
        let (name, defaults, backend, controller, service, model) = fixture()
        defer { backend.releaseCode = 0; _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        model.startManualSession(minutes: 10)
        await wait { service.gate.current?.manualDeadline != nil }
        backend.releaseCode = -7
        let quit = await model.prepareToQuit()
        XCTAssertFalse(quit)
        XCTAssertNotNil(model.errorText)
        XCTAssertNil(service.gate.current)
        XCTAssertFalse(service.connected)
        XCTAssertEqual(service.requests.last?.action, .detachApp)
        XCTAssertEqual(backend.creates, 1)
        backend.releaseCode = 0
        let retried = await model.prepareToQuit()
        XCTAssertTrue(retried)
        XCTAssertEqual(backend.creates, 1)
        XCTAssertEqual(backend.releases, 2)
        XCTAssertFalse(controller.status.holding)
    }

    @MainActor
    func testUpdateSafetyIsRecheckedAfterTheAsynchronousLidReleaseWithoutEndingGeneralWork() async throws {
        for changedLid: Bool? in [true, nil] {
            var lid: Bool? = false
            weak var observedService: CommonServiceFixture?
            let updater = AppUpdater(lidClosed: { lid }) { _ in }
            let sparkle = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: updater, userDriverDelegate: updater)
            let item = try XCTUnwrap(SUAppcastItem(dictionary: ["sparkle:version": "50",
                "enclosure": ["url": "https://example.invalid/Tether.zip", "sparkle:version": "50"]]))
            updater.updater(sparkle.updater, willExtractUpdate: item)
            var detaches = 0
            let (name, defaults, backend, controller, service, model) = fixture(serviceHook: { request, _ in
                if request.action == .detachApp {
                    detaches += 1
                    if detaches == 1 { lid = changedLid; observedService?.lid = changedLid }
                }
            }, updateTermination: { updater.canTerminateForUpdate })
            observedService = service
            defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
            await wait { service.gate.current != nil }
            model.startManualSession(minutes: 10)
            await wait { service.gate.current?.manualDeadline != nil }
            let deadline = try XCTUnwrap(controller.status.until)
            let session = controller.sessionID
            let preparations = service.requests.filter { $0.action == .prepareWorkSession }.count
            let quit = await model.prepareToQuit()
            XCTAssertFalse(quit)
            XCTAssertEqual(detaches, 1)
            if changedLid == true {
                await wait { model.clamshellActive && !model.lidCommandPending }
                XCTAssertEqual(service.gate.current?.sessionID, session)
                XCTAssertEqual(service.requests.filter { $0.action == .prepareWorkSession }.count, preparations + 1)
            } else {
                for _ in 0..<20 { await Task.yield() }
                XCTAssertNil(service.gate.current)
                XCTAssertNotNil(model.coordinatedLidError ?? model.lidObservationNotice)
                XCTAssertEqual(service.requests.filter { $0.action == .prepareWorkSession }.count, preparations)
            }
            XCTAssertTrue(controller.status.holding)
            XCTAssertTrue(controller.status.manualActive)
            XCTAssertEqual(controller.status.until, deadline)
            XCTAssertEqual(controller.sessionID, session)
            XCTAssertEqual(backend.releases, 0)
            XCTAssertTrue(model.acceptingUserCommands)
            lid = false
            let retried = await model.prepareToQuit()
            XCTAssertTrue(retried)
            XCTAssertFalse(controller.status.holding)
            XCTAssertEqual(backend.releases, 1)
            XCTAssertEqual(backend.creates, 1)
        }
    }

    @MainActor
    func testCanceledUpdateRestoresLidSupportWithoutRefillingBatteryTimeOrExtendingTheManualDeadline() async throws {
        var lid: Bool? = false
        weak var observedService: CommonServiceFixture?
        let (name, defaults, backend, controller, service, model) = fixture(power: .battery,
            serviceHook: { request, _ in
                if request.action == .detachApp { lid = true; observedService?.lid = true }
            }, updateTermination: { lid == false })
        observedService = service
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil && !model.lidCommandPending }
        model.startManualSession(minutes: 10)
        await wait { model.clamshellActive && service.gate.current?.manualDeadline != nil && !model.lidCommandPending }
        let initialRemaining = controller.status.manualBatteryRemaining
        // Keep the finite health lease on the actual monotonic clock while
        // observing a small, real interval of already consumed battery allowance.
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        await wait { model.clamshellActive && service.gate.current?.manualDeadline != nil && !model.lidCommandPending }
        let deadline = try XCTUnwrap(controller.status.until)
        let rootDeadline = try XCTUnwrap(service.gate.current?.manualDeadline)
        let remaining = controller.status.manualBatteryRemaining
        XCTAssertLessThan(remaining, initialRemaining)
        let session = controller.sessionID
        let settings = defaults.data(forKey: UserSessionController.preferenceKey)
        let quit = await model.prepareToQuit()
        XCTAssertFalse(quit)
        await wait { model.clamshellActive && !model.lidCommandPending }
        XCTAssertEqual(service.gate.current?.sessionID, session)
        XCTAssertEqual(service.gate.current?.manualDeadline, rootDeadline)
        XCTAssertEqual(controller.status.until, deadline)
        XCTAssertLessThanOrEqual(controller.status.manualBatteryRemaining, remaining)
        XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), settings)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
    }

    @MainActor
    func testCanceledUpdateCannotRestoreLidSupportForLostUserExpiredWorkOrProtection() async {
        for change in ["user", "expiry", "protection", "observation", "rejected"] {
            var lid: Bool? = false
            weak var observedService: CommonServiceFixture?
            weak var observedController: UserSessionController?
            let (name, defaults, backend, controller, service, model) = fixture(serviceHook: { request, _ in
                guard request.action == .detachApp else { return }
                lid = true; observedService?.lid = true
                switch change {
                case "user":
                    observedController?.update(power: .ac, thermal: 0, fullWake: true, controllingUser: false,
                        now: ContinuousTime.now, batteryPercent: 80)
                case "expiry":
                    observedController?.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                        now: ContinuousTime.now + 601, batteryPercent: 80)
                case "protection": observedService?.reason = "displayConflict"
                case "observation": observedService?.lid = nil
                default: observedService?.rejected = true
                }
            }, updateTermination: { lid == false })
            observedService = service; observedController = controller
            defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
            await wait { service.gate.current != nil && !model.lidCommandPending }
            model.startManualSession(minutes: 10)
            await wait { model.clamshellActive && !model.lidCommandPending }
            let preparations = service.requests.filter { $0.action == .prepareWorkSession }.count
            let quit = await model.prepareToQuit()
            XCTAssertFalse(quit)
            for _ in 0..<50 { await Task.yield() }
            XCTAssertNil(service.gate.current, change)
            XCTAssertFalse(model.clamshellActive, change)
            XCTAssertTrue(model.acceptingUserCommands, change)
            XCTAssertNotNil(model.coordinatedLidError ?? model.lidObservationNotice, change)
            let recoveryPreparations = service.requests.filter { $0.action == .prepareWorkSession }.count - preparations
            XCTAssertEqual(recoveryPreparations, change == "rejected" ? 1 : 0, change)
            XCTAssertEqual(backend.creates, 1, change)
            if change == "expiry" {
                XCTAssertFalse(controller.status.manualActive)
                XCTAssertNil(controller.status.until)
            }
        }
    }

    @MainActor
    func testCanceledUpdateRecoveryRechecksTheUserAndDeadlineAfterPreparation() async {
        for change in ["user", "expiry", "protection"] {
            var capabilities = Self.portable
            var lid: Bool? = false
            var canceledQuit = false
            weak var observedService: CommonServiceFixture?
            weak var observedController: UserSessionController?
            let (name, defaults, backend, controller, service, model) = fixture(capabilityProbe: { capabilities }, serviceHook: { request, _ in
                if request.action == .detachApp {
                    canceledQuit = true; lid = true; observedService?.lid = true
                } else if canceledQuit, request.action == .prepareWorkSession {
                    switch change {
                    case "user":
                        observedController?.update(power: .ac, thermal: 0, fullWake: true, controllingUser: false,
                            now: ContinuousTime.now, batteryPercent: 80)
                    case "expiry":
                        observedController?.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                            now: ContinuousTime.now + 601, batteryPercent: 80)
                    default: observedService?.reason = "displayConflict"
                    }
                }
            }, updateTermination: { lid == false })
            observedService = service; observedController = controller
            defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
            await wait { service.gate.current != nil && !model.lidCommandPending }
            model.startManualSession(minutes: 10)
            await wait { model.clamshellActive && !model.lidCommandPending }
            let attachments = service.requests.filter { $0.action == .attachWorkSession }.count
            let quit = await model.prepareToQuit()
            XCTAssertFalse(quit)
            await wait { !model.lidCommandPending }
            XCTAssertNil(service.gate.current, change)
            XCTAssertEqual(service.requests.filter { $0.action == .attachWorkSession }.count, attachments, change)
            XCTAssertNotNil(model.coordinatedLidError, change)
            XCTAssertFalse(model.clamshellActive, change)
            XCTAssertTrue(model.acceptingUserCommands, change)
            XCTAssertEqual(backend.creates, 1, change)
            // A paused recovery must still drain its empty preparation when
            // device observations later disappear, even with no acquire rights.
            capabilities = Self.unreadable
            model.refresh()
            await wait { !model.lidReleasePending }
            XCTAssertFalse(service.connected, change)
            XCTAssertNil(service.preparation, change)
        }
    }

    @MainActor
    func testLegacyAlreadyDetachedSnapshotRechecksUpdateSafetyBeforeApprovingTermination() async {
        for changedLid: Bool? in [true, nil] {
            var lid: Bool? = false
            let name = "TetherLegacyUpdateQuitTests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let service = CommonServiceFixture()
            service.coordinatorVersion = nil; service.connected = false
            let model = AppModel(preview: true, capabilities: Self.portable,
                previewWorkService: { request in
                    let reply = try service.perform(request)
                    if request.action == .snapshot { lid = changedLid }
                    return reply
                }, previewHelperReply: service.reply(), previewDefaults: defaults,
                previewUpdateTermination: { lid == false })
            XCTAssertFalse(model.usesUserSession)
            XCTAssertTrue(model.helperInstalled)
            let quit = await model.prepareToQuit()
            XCTAssertFalse(quit)
            XCTAssertTrue(model.acceptingUserCommands)
            XCTAssertNotNil(model.errorText)
            XCTAssertEqual(service.requests.map(\.action), [.snapshot])
        }
    }

    @MainActor
    func testAnUnsafePendingUpdateDoesNotBeginAnyTerminationMutation() async throws {
        for closed: Bool? in [true, nil] {
            let updater = AppUpdater(lidClosed: { closed }) { _ in }
            let sparkle = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: updater, userDriverDelegate: updater)
            let item = try XCTUnwrap(SUAppcastItem(dictionary: ["sparkle:version": "50",
                "enclosure": ["url": "https://example.invalid/Tether.zip", "sparkle:version": "50"]]))
            updater.updater(sparkle.updater, willExtractUpdate: item)
            let (name, defaults, backend, controller, service, model) = fixture(updateTermination: { updater.canTerminateForUpdate })
            defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
            await wait { service.gate.current != nil }
            model.startManualSession(minutes: 10)
            await wait { service.gate.current?.manualDeadline != nil }
            let deadline = controller.status.until
            let requests = service.requests.count
            let saved = defaults.data(forKey: UserSessionController.preferenceKey)
            let quit = await model.prepareToQuit()
            XCTAssertFalse(quit)
            XCTAssertEqual(service.requests.count, requests)
            XCTAssertEqual(backend.releases, 0)
            XCTAssertTrue(controller.status.holding)
            XCTAssertEqual(controller.status.until, deadline)
            XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), saved)
            XCTAssertTrue(model.acceptingUserCommands)
        }
    }

    @MainActor
    func testAnExpiredTimerDuringFailedQuitIsNotRestoredAsAHealthySession() async {
        var subject: UserSessionController?
        let (name, defaults, backend, controller, service, model) = fixture(serviceHook: { request, _ in
            guard request.action == .detachApp else { return }
            subject?.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now + 601, batteryPercent: 80)
        })
        subject = controller
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        model.startManualSession(minutes: 10)
        await wait { service.gate.current?.manualDeadline != nil }
        service.omitDetachEffect = true
        let quit = await model.prepareToQuit()
        XCTAssertFalse(quit)
        XCTAssertTrue(model.acceptingUserCommands)
        XCTAssertFalse(controller.status.holding)
        XCTAssertFalse(controller.status.manualActive)
        XCTAssertNil(controller.status.until)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 1)
        // The cancelled shutdown preserves normal policy evaluation, not a stale
        // pre-quit snapshot that could resurrect an expired temporary session.
        model.refresh()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(controller.status.manualActive)
        XCTAssertEqual(backend.creates, 1)
        service.omitDetachEffect = false
        let retried = await model.prepareToQuit()
        XCTAssertTrue(retried)
        XCTAssertEqual(backend.releases, 1)
    }

    @MainActor
    func testNativeGeneralRequestSurvivesRejectedQuitAndIsReleasedOnlyAfterConfirmedDetach() async throws {
        guard ProcessInfo.processInfo.environment["TETHER_RUN_LIVE_ASSERTION_TESTS"] == "1" else {
            throw XCTSkip("Set TETHER_RUN_LIVE_ASSERTION_TESTS=1 for bounded live IOKit tests")
        }
        let gui = GUISessionProbe.callerObservation()
        guard gui.login?.uid == getuid(), gui.consoleUID == getuid() else {
            throw XCTSkip("A current native GUI login is required for the live assertion test")
        }
        let native = NativeIdleAssertionBackend()
        let (name, defaults, backend, controller, service, model) = fixture(native: native)
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        // The actual non-root IOKit request is finite; the lid service remains a fixture.
        XCTAssertTrue(controller.start(duration: 15))
        await wait { service.gate.current?.manualDeadline != nil }
        let id = try XCTUnwrap(backend.createdID)
        XCTAssertEqual(native.level(id: id), 255)
        let deadline = controller.status.until, session = controller.sessionID
        service.rejectDetach = true
        let quit = await model.prepareToQuit()
        XCTAssertFalse(quit)
        XCTAssertEqual(native.level(id: id), 255)
        XCTAssertTrue(controller.status.holding)
        XCTAssertEqual(controller.status.until, deadline); XCTAssertEqual(controller.sessionID, session)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
        service.rejectDetach = false
        let retried = await model.prepareToQuit()
        XCTAssertTrue(retried)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 1)
        XCTAssertFalse(controller.status.holding)
        let active = try XCTUnwrap(SystemProbe.sleepBlockerSnapshot())
        XCTAssertFalse(active.contains { $0.pid == getpid() && $0.reason == "Tether work session" })
    }

    @MainActor
    func testFailedQuitKeepsTheLiveCommandSocketAndExclusiveInstanceLock() async throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("tether-quit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent("instance.lock").path
        let socket = directory.appendingPathComponent("commands.sock").path
        let (name, defaults, backend, controller, service, model) = fixture(coordinatorPath: lock)
        defer { model.userCommandService?.stop(); _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        let executable = try XCTUnwrap(ProcessIdentity.capture(pid: getpid())?.executable)
        let owner = GUISessionObservation(login: GUISessionProbe.caller(), consoleUID: getuid())
        XCTAssertTrue(model.hasCoordinatorAuthority)
        XCTAssertTrue(model.startUserCommandService(path: socket, expectedCompanion: executable, ownerProbe: { owner }))
        await wait { service.gate.current != nil }
        model.startManualSession(minutes: 10)
        await wait { service.gate.current?.manualDeadline != nil }
        let deadline = controller.status.until
        service.rejectDetach = true
        let quit = await model.prepareToQuit()
        XCTAssertFalse(quit)
        XCTAssertThrowsError(try AppCoordinatorLease.acquire(at: lock))
        let response = try await Task.detached {
            try UserSessionClient(path: socket, expectedServer: executable).perform(.status)
        }.value
        XCTAssertTrue(response.ok); XCTAssertTrue(response.status?.holding == true)
        XCTAssertEqual(response.status?.until, deadline)
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 0)
        service.rejectDetach = false
        let retried = await model.prepareToQuit()
        XCTAssertTrue(retried)
        XCTAssertFalse(model.acceptingUserCommands)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
        // A quit acknowledgement is still before process death. Another copy must
        // not start writing while the retiring model still holds the descriptor.
        XCTAssertThrowsError(try AppCoordinatorLease.acquire(at: lock))
        XCTAssertEqual(backend.releases, 1)
    }

    @MainActor
    func testQuitWaitsForOwnLidReleaseWithoutWritingScreenOrLockSettings() async throws {
        let (name, defaults, backend, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil }
        model.startUntimedSession()
        await wait { model.clamshellActive }
        let quit = await model.prepareToQuit()
        XCTAssertTrue(quit); XCTAssertFalse(model.clamshellActive)
        XCTAssertEqual(service.requests.last?.action, .detachApp)
        XCTAssertEqual(backend.releases, 1)
        XCTAssertNil(service.gate.current)
        XCTAssertNil(model.manualSessionUntil)
    }

    @MainActor
    func testFullRemovalVerifiesHelperAndNativeReleaseBeforeAnyDeletion() async {
        let (name, defaults, backend, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil && !model.lidCommandPending }
        model.startUntimedSession()
        await wait { model.clamshellActive && !model.lidCommandPending }
        let removal = CommonRemovalFixture(defaults: defaults, domain: name)
        let saved = defaults.persistentDomain(forName: name)! as NSDictionary
        removal.beforeHelper = {
            XCTAssertFalse(service.connected); XCTAssertNil(service.gate.current)
            XCTAssertEqual(service.requests.last?.action, .detachApp)
            XCTAssertEqual(backend.releases, 1); XCTAssertFalse(controller.status.holding)
            XCTAssertFalse(model.acceptingUserCommands)
            XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, saved)
        }

        let removed = await model.uninstallEverything(using: removal.effects)

        XCTAssertTrue(removed)
        XCTAssertEqual(removal.events, ["removeHelper", "removeLoginItem", "removeUserCLI", "recycleApp", "removePreferences", "terminate"])
        XCTAssertFalse(removal.helperPresent); XCTAssertFalse(removal.appPresent)
        XCTAssertTrue((defaults.persistentDomain(forName: name) ?? [:]).isEmpty); XCTAssertTrue(removal.terminated)
        let finalQuit = await model.prepareToQuit()
        XCTAssertTrue(finalQuit, "The final application termination must not repeat the removed helper's IPC")
        XCTAssertEqual(backend.releases, 1)
        XCTAssertEqual(service.requests.filter { $0.action == .detachApp }.count, 1)
    }

    @MainActor
    func testFullRemovalHelperReleaseFailureRetainsEveryArtifact() async {
        for missingEffect in [false, true] {
            let (name, defaults, backend, controller, service, model) = fixture()
            defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
            await wait { service.gate.current != nil && !model.lidCommandPending }
            model.startUntimedSession()
            await wait { model.clamshellActive && !model.lidCommandPending }
            let removal = CommonRemovalFixture(defaults: defaults, domain: name)
            let saved = defaults.persistentDomain(forName: name)! as NSDictionary
            service.rejectDetach = !missingEffect; service.omitDetachEffect = missingEffect

            let removed = await model.uninstallEverything(using: removal.effects)

            XCTAssertFalse(removed); XCTAssertTrue(removal.events.isEmpty)
            XCTAssertTrue(removal.helperPresent); XCTAssertTrue(removal.appPresent)
            XCTAssertTrue(removal.loginItemPresent); XCTAssertTrue(removal.cliPresent)
            XCTAssertFalse(removal.terminated); XCTAssertNotNil(model.errorText)
            XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, saved)
            XCTAssertEqual(backend.releases, 0); XCTAssertTrue(controller.status.holding)
            XCTAssertTrue(model.acceptingUserCommands)
        }
    }

    @MainActor
    func testFullRemovalNativeReleaseFailureRetainsEveryArtifact() async {
        let (name, defaults, backend, controller, service, model) = fixture()
        defer { backend.releaseCode = 0; _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil && !model.lidCommandPending }
        model.startUntimedSession()
        await wait { model.clamshellActive && !model.lidCommandPending }
        let removal = CommonRemovalFixture(defaults: defaults, domain: name)
        let saved = defaults.persistentDomain(forName: name)! as NSDictionary
        backend.releaseCode = -7

        let removed = await model.uninstallEverything(using: removal.effects)

        XCTAssertFalse(removed); XCTAssertTrue(removal.events.isEmpty)
        XCTAssertTrue(removal.helperPresent); XCTAssertTrue(removal.appPresent)
        XCTAssertFalse(removal.terminated); XCTAssertNotNil(model.errorText)
        XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, saved)
        XCTAssertEqual(backend.releases, 1); XCTAssertTrue(model.acceptingUserCommands)
        backend.releaseCode = 0
        let retried = await model.uninstallEverything(using: removal.effects)
        XCTAssertTrue(retried); XCTAssertEqual(backend.releases, 2)
    }

    @MainActor
    func testFullRemovalAuthorizationCancellationPreservesArtifactsAndCanRetryWithoutRecreatingWork() async {
        let (name, defaults, backend, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil && !model.lidCommandPending }
        model.startUntimedSession()
        await wait { model.clamshellActive && !model.lidCommandPending }
        let removal = CommonRemovalFixture(defaults: defaults, domain: name)
        let saved = defaults.persistentDomain(forName: name)! as NSDictionary
        removal.cancelAuthorization = true

        let canceled = await model.uninstallEverything(using: removal.effects)

        XCTAssertFalse(canceled); XCTAssertEqual(removal.events, ["removeHelper"])
        XCTAssertTrue(removal.helperPresent); XCTAssertTrue(removal.appPresent)
        XCTAssertTrue(removal.loginItemPresent); XCTAssertTrue(removal.cliPresent)
        XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, saved)
        XCTAssertFalse(removal.terminated); XCTAssertNotNil(model.errorText)
        XCTAssertFalse(controller.status.holding); XCTAssertFalse(model.acceptingUserCommands)
        removal.cancelAuthorization = false; removal.events = []
        let retried = await model.uninstallEverything(using: removal.effects)
        XCTAssertTrue(retried); XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 1)
        XCTAssertEqual(service.requests.filter { $0.action == .detachApp }.count, 1)
    }

    @MainActor
    func testFullRemovalHelperScriptFailureKeepsSettingsAndAppAndAllowsQuit() async {
        let (name, defaults, _, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil && !model.lidCommandPending }
        let removal = CommonRemovalFixture(defaults: defaults, domain: name)
        let saved = defaults.persistentDomain(forName: name)! as NSDictionary
        removal.failureAt = "removeHelper"

        let removed = await model.uninstallEverything(using: removal.effects)

        XCTAssertFalse(removed); XCTAssertEqual(removal.events, ["removeHelper"])
        XCTAssertTrue(removal.helperPresent); XCTAssertTrue(removal.appPresent)
        XCTAssertFalse(removal.terminated); XCTAssertNotNil(model.errorText)
        XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, saved)
        let quit = await model.prepareToQuit()
        XCTAssertTrue(quit)
    }

    @MainActor
    func testFullRemovalLoginRemovalFailureKeepsSettingsAndApp() async {
        let (name, defaults, _, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil && !model.lidCommandPending }
        let removal = CommonRemovalFixture(defaults: defaults, domain: name)
        let saved = defaults.persistentDomain(forName: name)! as NSDictionary
        removal.failureAt = "removeLoginItem"

        let removed = await model.uninstallEverything(using: removal.effects)

        XCTAssertFalse(removed); XCTAssertEqual(removal.events, ["removeHelper", "removeLoginItem"])
        XCTAssertTrue(removal.loginItemPresent); XCTAssertTrue(removal.appPresent)
        XCTAssertFalse(removal.terminated); XCTAssertNotNil(model.errorText)
        XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, saved)
    }

    @MainActor
    func testFullRemovalRecycleFailureKeepsSettingsAndReportsPartialRemoval() async {
        let (name, defaults, _, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil && !model.lidCommandPending }
        let removal = CommonRemovalFixture(defaults: defaults, domain: name)
        let saved = defaults.persistentDomain(forName: name)! as NSDictionary
        removal.failureAt = "recycleApp"

        let removed = await model.uninstallEverything(using: removal.effects)

        XCTAssertFalse(removed)
        XCTAssertEqual(removal.events, ["removeHelper", "removeLoginItem", "removeUserCLI", "recycleApp"])
        XCTAssertTrue(removal.appPresent); XCTAssertFalse(removal.terminated)
        XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, saved)
        XCTAssertNotNil(model.errorText)
    }

    @MainActor
    func testFullRemovalWaitsForTrashCompletionRejectingConcurrentQuitAndDuplicateRemoval() async {
        let (name, defaults, _, controller, service, model) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil && !model.lidCommandPending }
        let removal = CommonRemovalFixture(defaults: defaults, domain: name)
        let saved = defaults.persistentDomain(forName: name)! as NSDictionary
        var continueRecycle: CheckedContinuation<Void, Never>?
        removal.beforeRecycle = { await withCheckedContinuation { continueRecycle = $0 } }
        let first = Task { await model.uninstallEverything(using: removal.effects) }
        await wait { continueRecycle != nil }

        XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, saved)
        XCTAssertTrue(removal.appPresent); XCTAssertFalse(removal.terminated)
        let duplicate = await model.uninstallEverything(using: removal.effects)
        let prematureQuit = await model.prepareToQuit()
        XCTAssertFalse(duplicate); XCTAssertFalse(prematureQuit)
        XCTAssertEqual(removal.events.filter { $0 == "removeHelper" }.count, 1)
        continueRecycle?.resume()
        let completed = await first.value
        XCTAssertTrue(completed); XCTAssertTrue(removal.terminated)
        XCTAssertTrue((defaults.persistentDomain(forName: name) ?? [:]).isEmpty)
    }

    @MainActor
    private func urlHoldFixture(helper: Bool = false, power: PowerSource = .battery,
                                capabilityProbe: (() -> MacCapabilities)? = nil)
        -> (UserSessionController, CommonServiceFixture, AppModel) {
        let defaults = CommonMemoryDefaults()
        let controller = UserSessionController(defaults: defaults, backend: CommonAssertionFixture(),
            displayBackend: CommonAssertionFixture(), guiProbe: nil, environmentProbe: nil)
        controller.setAllowClosedLid(helper)
        controller.update(power: power, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        let service = CommonServiceFixture()
        service.power = power
        service.acknowledgesManualExtensions = true
        let model: AppModel
        if helper {
            model = AppModel(preview: true, capabilities: Self.portable, previewSession: controller,
                previewWorkService: { try service.perform($0) }, previewHelperReply: service.reply(),
                previewDefaults: defaults, previewCapabilitiesProbe: capabilityProbe)
        } else {
            model = AppModel(preview: true, capabilities: Self.portable, previewSession: controller,
                previewWorkService: { try service.perform($0) }, previewDefaults: defaults,
                previewCapabilitiesProbe: capabilityProbe)
        }
        return (controller, service, model)
    }

    @MainActor
    private func waitForURLHoldExtension(_ condition: () -> Bool,
                                         file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousTime.now + 2
        while !condition(), ContinuousTime.now < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "URL extension acknowledgement did not arrive", file: file, line: line)
    }

    @MainActor
    func testURLHoldAliasesUseTheManualExtensionDeadlineWithoutHelper() async throws {
        for minutes in [15, 30] {
            let (controller, service, model) = urlHoldFixture()
            defer { _ = controller.end() }
            model.startManualSession(minutes: 30)
            let before = try XCTUnwrap(controller.status.manualContinuousDeadline)
            let wallBefore = try XCTUnwrap(model.manualSessionUntil)
            let requestID = controller.manualRequestID
            XCTAssertFalse(model.canExtendHold(minutes: minutes), "The retired battery-hold policy is not the manual policy")
            XCTAssertTrue(model.canExtendManual(by: minutes))

            model.handle(url: try XCTUnwrap(URL(string: "tether://hold/+\(minutes)m")))
            await waitForURLHoldExtension { controller.status.manualContinuousDeadline == before + Double(minutes * 60) }

            XCTAssertEqual(controller.manualRequestID, requestID)
            XCTAssertNotNil(controller.manualExtensionID)
            XCTAssertEqual(try XCTUnwrap(model.manualSessionUntil).timeIntervalSince(wallBefore), Double(minutes * 60), accuracy: 0.01)
            XCTAssertTrue(controller.status.holding)
            XCTAssertTrue(service.requests.isEmpty)
        }
    }

    @MainActor
    func testURLHoldAliasesRequireHelperPreparationBeforeCommittingTheManualExtension() async throws {
        for minutes in [15, 30] {
            let (controller, service, model) = urlHoldFixture(helper: true)
            defer { _ = controller.end() }
            await waitForURLHoldExtension { service.gate.current != nil && !model.lidCommandPending }
            model.startManualSession(minutes: 30)
            await waitForURLHoldExtension { model.clamshellActive && !model.v4ManualApprovalPending && !model.lidCommandPending }
            let before = try XCTUnwrap(controller.status.manualContinuousDeadline)
            let requestID = controller.manualRequestID
            let firstRequest = service.requests.count

            model.handle(url: try XCTUnwrap(URL(string: "tether://hold/+\(minutes)m")))
            await waitForURLHoldExtension {
                controller.status.manualContinuousDeadline == before + Double(minutes * 60)
                    && !model.v4ManualApprovalPending && !controller.manualExtensionPending && !model.lidCommandPending
            }

            let requests = Array(service.requests.dropFirst(firstRequest))
            let preparation = try XCTUnwrap(requests.first { $0.workSession?.extensionPreparation != nil }?.workSession)
            let extensionID = try XCTUnwrap(controller.manualExtensionID)
            XCTAssertEqual(preparation.manualDeadline, before)
            XCTAssertEqual(preparation.extensionPreparation?.currentDeadline, before)
            XCTAssertEqual(preparation.extensionPreparation?.proposedDeadline, before + Double(minutes * 60))
            XCTAssertEqual(preparation.extensionPreparation?.id, extensionID)
            XCTAssertEqual(controller.manualRequestID, requestID)
            XCTAssertEqual(service.gate.current?.manualDeadline, before + Double(minutes * 60))
            XCTAssertEqual(service.gate.current?.manualExtensionID, extensionID)
            XCTAssertTrue(model.clamshellActive)
        }
    }

    @MainActor
    func testURLHoldAliasPreservesTheManualDeadlineWhenHelperPreparationFails() async throws {
        let (controller, service, model) = urlHoldFixture(helper: true)
        defer { _ = controller.end() }
        await waitForURLHoldExtension { service.gate.current != nil && !model.lidCommandPending }
        model.startManualSession(minutes: 30)
        await waitForURLHoldExtension { model.clamshellActive && !model.v4ManualApprovalPending && !model.lidCommandPending }
        let before = try XCTUnwrap(controller.status.manualContinuousDeadline)
        let requestID = controller.manualRequestID
        service.rejected = true

        model.handle(url: try XCTUnwrap(URL(string: "tether://hold/+15m")))
        await waitForURLHoldExtension { model.errorText != nil && !model.v4ManualApprovalPending && !controller.manualExtensionPending }

        XCTAssertTrue(service.requests.contains { $0.workSession?.extensionPreparation != nil })
        XCTAssertEqual(controller.status.manualContinuousDeadline, before)
        XCTAssertEqual(controller.manualRequestID, requestID)
        XCTAssertNil(controller.manualExtensionID)
        XCTAssertEqual(service.gate.current?.manualDeadline, before)
    }

    @MainActor
    func testURLHoldAliasesRejectCapsProtectionAndUnconfirmedInputsWithoutRevivingWork() async throws {
        for scenario in ["cap", "thermal", "unknownPower", "lostAuthority", "batteryCapability", "powerDisconnected", "invalidDuration"] {
            var observed = Self.portable
            let initialPower: PowerSource = scenario == "powerDisconnected" ? .ac : .battery
            let (controller, _, model) = urlHoldFixture(power: initialPower, capabilityProbe: { observed })
            defer { _ = controller.end() }
            model.startManualSession(minutes: scenario == "cap" ? 120 : 30)
            XCTAssertTrue(controller.status.manualActive, scenario)
            switch scenario {
            case "thermal":
                controller.update(power: .battery, thermal: 2, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
            case "unknownPower":
                controller.update(power: .unknown, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
            case "lostAuthority":
                controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: false,
                    now: ContinuousTime.now, batteryPercent: 80)
            case "batteryCapability": observed = Self.unreadable
            case "powerDisconnected":
                controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
                XCTAssertFalse(controller.status.manualActive)
            default: break
            }
            let before = controller.status.manualContinuousDeadline
            let requestID = controller.manualRequestID
            let holding = controller.status.holding

            model.handle(url: try XCTUnwrap(URL(string: "tether://hold/+\(scenario == "invalidDuration" ? 5 : 15)m")))
            for _ in 0..<10 { await Task.yield() }

            XCTAssertEqual(controller.status.manualContinuousDeadline, before, scenario)
            XCTAssertEqual(controller.manualRequestID, requestID, scenario)
            XCTAssertEqual(controller.status.holding, holding, scenario)
            XCTAssertNil(controller.manualExtensionID, scenario)
            XCTAssertFalse(controller.manualExtensionPending, scenario)
            if scenario == "batteryCapability" { XCTAssertNotNil(model.errorText) }
        }
    }

    @MainActor
    func testBatteryProgressUsesOnlyManualDeadlineAndWholeExplicitExtensions() async throws {
        let (name, defaults, _, controller, _, _) = fixture()
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        let model = AppModel(preview: true, capabilities: Self.portable, previewSession: controller)
        controller.setAllowClosedLid(false)
        controller.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        model.setPowerCondition(.battery); model.setAutomaticMinutes(120); model.setAutomaticEnabled(true)
        model.startManualSession(minutes: 30)
        let manualDeadline = try XCTUnwrap(model.manualSessionUntil)
        XCTAssertNil(model.batteryHoldUntil); XCTAssertFalse(model.automaticWorkReasonActive)
        XCTAssertTrue(model.manualSessionActive); XCTAssertFalse(model.canExtendHold(minutes: 60))
        XCTAssertTrue(model.canExtendManual(by: 15))
        XCTAssertTrue(model.extendCommonManualSession(minutes: 15))
        XCTAssertEqual(try XCTUnwrap(model.manualSessionUntil).timeIntervalSince(manualDeadline), 900, accuracy: 1)
        XCTAssertFalse(controller.canExtendBatteryHold(minutes: 15))
    }

    @MainActor
    func testBuild49CanYieldGeneralWorkWithoutAnAdministratorUpdateAndPreservesOffAndBudgets() async throws {
        for enabled in [false, true] {
            let defaults = CommonMemoryDefaults()
            let backend = CommonAssertionFixture()
            let service = CommonServiceFixture()
            service.helperBuild = 49; service.helperVersion = "2026.9.1"
            service.coordinatorVersion = nil; service.sendsBridge = false
            service.control.enabled = enabled; service.control.powerCondition = .ac
            service.control.batteryHoldUntil = enabled ? Date().addingTimeInterval(600).timeIntervalSince1970 : nil
            let model = AppModel(preview: true, capabilities: Self.portable,
                previewSessionBackend: backend,
                previewLegacyObservation: { Snapshot(power: .ac, lidClosed: false, sleepDisabled: false) },
                previewWorkService: { request in
                    let reply = try service.perform(request)
                    if request.action == .detachApp {
                        service.control.batteryHoldUntil = nil; service.control.pendingHoldMinutes = nil
                    }
                    return reply
                }, previewHelperReply: service.reply(), previewDefaults: defaults)
            await wait { model.userSession != nil }
            let controller = try XCTUnwrap(model.userSession)
            defer { _ = controller.end() }
            XCTAssertEqual(service.requests.map(\.action), [.snapshot, .attachApp, .detachApp, .snapshot])
            XCTAssertFalse(service.connected); XCTAssertFalse(model.coordinatingLid)
            XCTAssertTrue(model.helperOutdated); XCTAssertFalse(model.clamshellActive)
            XCTAssertEqual(controller.status.enabled, enabled)
            XCTAssertEqual(controller.status.automaticEnabled, enabled)
            XCTAssertNil(controller.status.until); XCTAssertNil(controller.status.pendingBatteryMinutes)
            XCTAssertFalse(controller.status.manualActive); XCTAssertEqual(backend.creates, 0)
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            XCTAssertEqual(controller.status.holding, enabled)
            let settings = try JSONDecoder().decode(IdleSessionSettings.self,
                from: XCTUnwrap(defaults.data(forKey: UserSessionController.preferenceKey)))
            XCTAssertNil(settings.automaticBatteryBudget); XCTAssertNil(settings.manualBatteryBudget)
            if !enabled {
                XCTAssertFalse(controller.start(duration: nil), "A whole stop requires explicit Resume")
                XCTAssertTrue(controller.setEnabled(true))
            }
            XCTAssertTrue(controller.start(duration: nil), "A new AC manual choice remains independent of the automatic trigger")
            XCTAssertEqual(backend.creates, 1)
            XCTAssertFalse(model.clamshellActive, "General work cannot claim unsupported legacy lid coordination")
        }
    }

    @MainActor
    func testLegacyGeneralHandoffRefusesUnknownContractUnreadableProtectionForeignAppAndUnsafeCurrentFacts() async {
        for invalid in ["oldBuild", "futureBuild", "unknownVersion", "protection", "foreignApp", "closed", "lidUnknown", "wakeUnknown", "darkWake", "overrideUnknown", "powerUnknown"] {
            let defaults = CommonMemoryDefaults()
            let backend = CommonAssertionFixture()
            let service = CommonServiceFixture()
            service.helperBuild = 49; service.helperVersion = "2026.9.1"
            service.coordinatorVersion = nil; service.sendsBridge = false
            var observed = Snapshot(power: .ac, lidClosed: false, sleepDisabled: false)
            switch invalid {
            case "oldBuild": service.helperBuild = 48
            case "futureBuild": service.helperBuild = 51
            case "unknownVersion": service.helperVersion = TetherPaths.version
            case "protection": service.protectionError = "stateUnreadable"
            case "foreignApp": service.appPID = getpid() + 1
            case "closed": observed.observedLidClosed = true
            case "lidUnknown": observed.observedLidClosed = nil
            case "wakeUnknown": observed.observedFullWake = nil
            case "darkWake": observed.observedFullWake = false
            case "overrideUnknown": observed.observedSleepDisabled = nil
            default: observed.power = .unknown
            }
            let model = AppModel(preview: true, capabilities: Self.portable, previewSessionBackend: backend,
                previewLegacyObservation: { observed }, previewWorkService: { try service.perform($0) },
                previewHelperReply: service.reply(), previewDefaults: defaults)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertNil(model.userSession, invalid); XCTAssertTrue(service.requests.isEmpty, invalid)
            XCTAssertEqual(backend.creates, 0, invalid); XCTAssertTrue(service.connected, invalid)
            XCTAssertNil(defaults.data(forKey: UserSessionController.preferenceKey), invalid)
        }
    }

    @MainActor
    func testLegacyGeneralHandoffRechecksFactsAndCleansUpAnAttachWithALostReply() async {
        for lostReply in [false, true] {
            let defaults = CommonMemoryDefaults()
            let backend = CommonAssertionFixture()
            let service = CommonServiceFixture()
            service.helperBuild = 49; service.helperVersion = "2026.9.1"
            service.coordinatorVersion = nil; service.sendsBridge = false
            var observed = Snapshot(power: .ac, lidClosed: false, sleepDisabled: false)
            let model = AppModel(preview: true, capabilities: Self.portable, previewSessionBackend: backend,
                previewLegacyObservation: { observed }, previewWorkService: { request in
                    let reply = try service.perform(request)
                    if request.action == .attachApp {
                        if lostReply { throw ServiceFailure("connectionClosed") }
                        observed.observedLidClosed = true
                    }
                    return reply
                }, previewHelperReply: service.reply(), previewDefaults: defaults)
            await wait { model.coordinatedLidError != nil }
            XCTAssertNil(model.userSession); XCTAssertFalse(service.connected)
            XCTAssertEqual(service.requests.filter { $0.action == .attachApp }.count, 1)
            XCTAssertEqual(service.requests.filter { $0.action == .detachApp }.count, 1)
            XCTAssertEqual(backend.creates, 0)
            XCTAssertNil(defaults.data(forKey: UserSessionController.preferenceKey))
        }
    }

    @MainActor
    func testLegacyGeneralHandoffDoesNotDetachAReplacementHelperOrDiscardNewProtection() async throws {
        for replacement in [false, true] {
            let defaults = CommonMemoryDefaults()
            let backend = CommonAssertionFixture()
            let service = CommonServiceFixture()
            service.helperBuild = 49; service.helperVersion = "2026.9.1"
            service.coordinatorVersion = nil; service.sendsBridge = false
            let model = AppModel(preview: true, capabilities: Self.portable, previewSessionBackend: backend,
                previewLegacyObservation: { Snapshot(power: .ac, lidClosed: false, sleepDisabled: false) },
                previewWorkService: { request in
                    if request.action == .attachApp, replacement {
                        service.helperBuild = TetherPaths.build; service.coordinatorVersion = WorkSessionLease.coordinatorVersion
                        service.helperVersion = TetherPaths.version
                        service.sendsBridge = true
                    }
                    if request.action == .detachApp, !replacement { service.reason = "thermal" }
                    return try service.perform(request)
                }, previewHelperReply: service.reply(), previewDefaults: defaults)
            await wait { model.coordinatedLidError != nil }
            if replacement {
                XCTAssertNil(model.userSession); XCTAssertTrue(service.connected)
                XCTAssertFalse(service.requests.contains { $0.action == .detachApp })
            } else {
                let controller = try XCTUnwrap(model.userSession)
                defer { _ = controller.end() }
                controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
                XCTAssertEqual(controller.status.blockReason, "thermal")
                XCTAssertFalse(controller.status.holding); XCTAssertFalse(controller.start(duration: nil))
            }
            XCTAssertEqual(backend.creates, 0)
        }
    }

    @MainActor
    func testConfirmedCapabilityDetachEndsRootReceiptDependenceWithoutRevivingPreSleepManualWork() async {
        var observed = Self.portable
        let (name, defaults, _, controller, service, model) = fixture(capabilityProbe: { observed })
        defer { _ = controller.end(); defaults.removePersistentDomain(forName: name) }
        await wait { service.gate.current != nil && !model.lidCommandPending }
        model.startManualSession(minutes: 10)
        await wait { service.gate.current?.manualDeadline != nil && !model.lidCommandPending }
        controller.observeSystemSleep(observedAt: ContinuousTime.now)
        XCTAssertFalse(controller.status.holding)
        observed = Self.unreadable
        model.refresh()
        await wait { !service.connected && !model.lidCommandPending }
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        XCTAssertFalse(controller.status.manualActive)
        XCTAssertTrue(controller.start(duration: 60))
        XCTAssertTrue(model.workSessionHolding); XCTAssertFalse(model.clamshellActive)
    }
}
