import Foundation
import XCTest
import TetherCore
@testable import Tether

private final class SessionFeaturesDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func register(defaults: [String: Any]) {
        for (key, value) in defaults where values[key] == nil { values[key] = value }
    }
    override func persistentDomain(forName name: String) -> [String: Any]? { values }
    override func synchronize() -> Bool { true }
}

private final class SessionFeaturesAssertion: IdleAssertionBackend {
    var creates = 0
    private var ids: Set<UInt32> = []
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        creates += 1; let id = UInt32(creates); ids.insert(id); return (0, id)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { ids.contains(id) ? 0 : -1 }
    func level(id: UInt32) -> Int? { ids.contains(id) ? 255 : 0 }
    func release(id: UInt32) -> Int32 { ids.remove(id); return 0 }
}

private final class SessionFeaturesBrightness: ClosedLidDisplayBrightnessBackend {
    let target = ClosedLidDisplayTarget(id: 123, vendor: 456, model: 789)
    var value: Float = 0.7
    var writes: [Float] = []
    var unsupportedIssue: ClosedLidDisplayIssue?
    var support: ClosedLidDisplaySupport {
        if let unsupportedIssue { return .init(availability: .unavailable, issue: unsupportedIssue) }
        return .init(availability: .candidateRequiresPhysicalValidation, target: target)
    }
    func read(target: ClosedLidDisplayTarget) -> Float? { target == self.target ? value : nil }
    func write(_ brightness: Float, target: ClosedLidDisplayTarget) -> Bool {
        guard target == self.target else { return false }
        writes.append(brightness); value = brightness; return true
    }
}

private final class SessionFeaturesJournal: ClosedLidDisplayRecoveryJournaling {
    var record: ClosedLidDisplayRecoveryRecord?
    func load() throws -> ClosedLidDisplayRecoveryRecord? { record }
    func save(_ record: ClosedLidDisplayRecoveryRecord) throws { self.record = record }
    func remove() throws { record = nil }
}

@MainActor
private final class SessionFeaturesFixture {
    let defaults = SessionFeaturesDefaults()
    let system = SessionFeaturesAssertion()
    let display = SessionFeaturesAssertion()
    let brightness = SessionFeaturesBrightness()
    let journal = SessionFeaturesJournal()
    let controller: UserSessionController
    let driver: ClosedLidDisplayDriver
    let model: AppModel

    init(startWork: Bool = false, helperMode: ClosedLidDisplayMode? = nil,
         unsupportedIssue: ClosedLidDisplayIssue? = nil,
         recoveryOriginal: Float? = nil, coordinatorFolder: URL? = nil) throws {
        var settings = IdleSessionSettings()
        settings.legacyRootConfigurationPending = false
        settings.automaticEnabled = false
        settings.allowClosedLid = true
        settings.closedLidDisplayMode = .zeroBrightness
        defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
        brightness.unsupportedIssue = unsupportedIssue
        if let recoveryOriginal {
            brightness.value = 0
            journal.record = .init(target: brightness.target, original: recoveryOriginal, phase: .applied)
        }
        driver = ClosedLidDisplayDriver(backend: brightness, journal: journal)
        controller = UserSessionController(defaults: defaults, backend: system, displayBackend: display,
            guiProbe: nil, environmentProbe: nil, boot: "session-features-fixture")
        controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
            now: ContinuousTime.now, batteryPercent: 80)
        if startWork { XCTAssertTrue(controller.start(duration: 1800)) }
        var reply: ServiceReply?
        if let helperMode {
            let now = ContinuousTime.now
            var status = Status(updatedAt: Date().timeIntervalSince1970, version: TetherPaths.version,
                enabled: false, power: .ac, lidClosed: true, sleepDisabled: true,
                lastEvent: nil, lastEventAt: nil, thermal: 0)
            status.build = TetherPaths.build
            status.workSessionCoordinatorVersion = WorkSessionLease.coordinatorVersion
            status.lidObservationAvailable = true
            status.sleepOverrideObservationAvailable = true
            status.systemPowerObservationAvailable = true
            status.fullWake = true
            status.ownsOverride = true
            status.appConnected = true
            status.externalDisplay = false
            status.displayTopology = .none
            status.workSession = WorkSessionLease(sessionID: controller.sessionID, sequence: 1,
                power: .ac, expiry: now + 30, reasons: [.manual], manualDeadline: now + 1800,
                settings: settings, lidPermit: .init(powerScopes: [.ac]),
                manualRequestID: controller.manualRequestID, closedLidDisplayMode: helperMode)
            var value = ServiceReply(id: UUID(), ok: true, epoch: "session-features-fixture", revision: 1,
                control: Control(), protection: .init(reason: nil, error: nil, dryRun: true))
            value.status = status
            value.workSessionBridge = .init(coordinated: true, automaticBudget: ProtectionState(), manualBudget: nil)
            reply = value
        }
        model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: controller,
            previewWorkService: { _ in throw ServiceFailure("session-features-fixture-isolated") },
            previewHelperReply: reply, previewDefaults: defaults,
            previewCoordinatorPath: coordinatorFolder?.appendingPathComponent("owner.lock").path,
            previewCommandPath: coordinatorFolder?.appendingPathComponent("commands.sock").path,
            previewHelperFiles: { [] }, previewClosedLidDisplayDriver: driver)
        model.updateSessionFeatures(controller.status)
    }

    func close() { _ = controller.end(); model.finishSessionFeatures() }
}

/// Model-to-driver wiring only. All assertions, brightness values and journals are injected.
final class SessionFeaturesModelTests: XCTestCase {
    @MainActor
    func testMenuShowsAndRetriesBrightnessRecoveryWithoutStartingWorkOrChangingSettings() throws {
        let fixture = try SessionFeaturesFixture(unsupportedIssue: .externalDisplayPresent, recoveryOriginal: 0.8)
        defer { fixture.close() }
        let panel = TetherPanel(model: fixture.model)
        let saved = fixture.defaults.data(forKey: UserSessionController.preferenceKey)
        XCTAssertTrue(panel.showsDisplayRecoveryWarning)
        XCTAssertTrue(panel.canRetryDisplayRecovery)
        panel.retryDisplayRecovery()
        XCTAssertTrue(panel.showsDisplayRecoveryWarning, "A failed retry must retain the recovery warning")
        XCTAssertTrue(fixture.brightness.writes.isEmpty)
        fixture.brightness.unsupportedIssue = nil
        panel.retryDisplayRecovery()
        XCTAssertFalse(panel.showsDisplayRecoveryWarning)
        XCTAssertEqual(fixture.brightness.writes, [0.8])
        XCTAssertNil(fixture.journal.record)
        XCTAssertFalse(fixture.controller.status.holding)
        XCTAssertEqual(fixture.system.creates, 0)
        XCTAssertEqual(fixture.display.creates, 0)
        XCTAssertEqual(fixture.defaults.data(forKey: UserSessionController.preferenceKey), saved)
    }

    @MainActor
    func testLostCoordinatorCannotRestoreOverANewOwnersBrightness() throws {
        let folder = URL(fileURLWithPath: "/tmp/tbd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try SessionFeaturesFixture(startWork: true, helperMode: .zeroBrightness,
                                                  coordinatorFolder: folder)
        defer { fixture.close() }
        XCTAssertNil(fixture.model.coordinatorStartFailure)
        XCTAssertTrue(fixture.model.hasCoordinatorAuthority)
        XCTAssertEqual(fixture.brightness.writes, [0])
        let path = folder.appendingPathComponent("owner.lock")
        try FileManager.default.removeItem(at: path)
        try Data().write(to: path)
        XCTAssertFalse(fixture.model.hasCoordinatorAuthority)
        let nextOwnersRecord = ClosedLidDisplayRecoveryRecord(target: fixture.brightness.target, original: 0.45, phase: .applied)
        fixture.journal.record = nextOwnersRecord
        fixture.model.updateSessionFeatures(fixture.controller.status)
        fixture.model.finishSessionFeatures()
        XCTAssertEqual(fixture.brightness.writes, [0], "An obsolete owner must not write shared brightness")
        XCTAssertEqual(fixture.journal.record, nextOwnersRecord)
        XCTAssertTrue(fixture.driver.hasRecoveryDebt)
    }
    @MainActor
    func testStartupBindingRestoresPriorBrightnessWithoutRestoringWork() throws {
        let fixture = try SessionFeaturesFixture(recoveryOriginal: 0.8); defer { fixture.close() }
        XCTAssertEqual(fixture.brightness.writes, [0.8])
        XCTAssertNil(fixture.journal.record)
        XCTAssertFalse(fixture.driver.hasRecoveryDebt)
        XCTAssertFalse(fixture.controller.status.manualActive)
        XCTAssertFalse(fixture.controller.status.automaticActive)
        XCTAssertFalse(fixture.controller.status.holding)
        XCTAssertEqual(fixture.system.creates, 0)
        XCTAssertEqual(fixture.display.creates, 0)
    }

    @MainActor
    func testSavedZeroSelectionDoesNotClaimApplicationOrWriteWithoutHelperAcknowledgement() throws {
        for helperMode in [ClosedLidDisplayMode?.none, .some(.off)] {
            let fixture = try SessionFeaturesFixture(startWork: true, helperMode: helperMode)
            defer { fixture.close() }
            XCTAssertEqual(fixture.model.v3Settings.closedLidDisplayMode, .zeroBrightness)
            XCTAssertTrue(fixture.brightness.writes.isEmpty)
            XCTAssertNil(fixture.journal.record)
            XCTAssertFalse(fixture.controller.closedLidDisplayAssertionConfirmed)
            XCTAssertEqual(fixture.display.creates, 0)
            XCTAssertNotEqual(fixture.model.closedLidDisplayState, .brightnessZero)
            XCTAssertNil(fixture.model.closedLidDisplayStatusText,
                         "Selection alone cannot produce a confirmed-applied message")
        }
    }

    @MainActor
    func testUnavailableExternalDisplayKeepsSavedSelectionWithoutDisplayOffFallback() throws {
        let fixture = try SessionFeaturesFixture(startWork: true, helperMode: .zeroBrightness,
                                                  unsupportedIssue: .externalDisplayPresent)
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.clamshellActive, "The injected helper grants actual lid authority")
        XCTAssertEqual(fixture.model.v3Settings.closedLidDisplayMode, .zeroBrightness)
        XCTAssertFalse(fixture.model.canUseZeroBrightness)
        XCTAssertEqual(fixture.model.closedLidDisplayState, .unavailable(.externalDisplayPresent))
        XCTAssertNotNil(fixture.model.closedLidDisplayStatusText)
        XCTAssertTrue(fixture.brightness.writes.isEmpty)
        XCTAssertEqual(fixture.display.creates, 0)
        XCTAssertEqual(fixture.controller.workLease()?.effectiveClosedLidDisplayMode, .zeroBrightness)
    }

    @MainActor
    func testConfirmedZeroAndLaterUserChangeHaveDistinctTruthfulStateCopy() throws {
        let fixture = try SessionFeaturesFixture(startWork: true, helperMode: .zeroBrightness)
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.clamshellActive)
        XCTAssertTrue(fixture.controller.closedLidDisplayAssertionConfirmed)
        XCTAssertEqual(fixture.model.closedLidDisplayState, .brightnessZero)
        XCTAssertEqual(fixture.brightness.writes, [0])
        let appliedCopy = try XCTUnwrap(fixture.model.closedLidDisplayStatusText)
        fixture.brightness.value = 0.4
        fixture.model.updateSessionFeatures(fixture.controller.status)
        XCTAssertEqual(fixture.model.closedLidDisplayState, .userChangePreserved)
        let changedCopy = try XCTUnwrap(fixture.model.closedLidDisplayStatusText)
        XCTAssertNotEqual(appliedCopy, changedCopy)
        XCTAssertEqual(fixture.brightness.writes, [0], "Observation cannot force the user's later choice back to zero")
        fixture.model.finishSessionFeatures()
        XCTAssertEqual(fixture.brightness.value, 0.4)
        XCTAssertEqual(fixture.brightness.writes, [0])
    }

    @MainActor
    func testFinishRestoresOwnedBrightnessAndFlushesStatisticsWithoutResumingWork() throws {
        let fixture = try SessionFeaturesFixture(startWork: true, helperMode: .zeroBrightness)
        defer { fixture.close() }
        let store = UsageStatisticsStore(defaults: fixture.defaults)
        fixture.model.usageStatisticsStore = store
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.observe(now: now, lidClosed: true, clamshellConfirmed: true,
            holding: true, onBattery: true, protectionReason: nil)
        store.observe(now: now.addingTimeInterval(30), lidClosed: true, clamshellConfirmed: true,
            holding: true, onBattery: true, protectionReason: nil)
        XCTAssertNil(fixture.defaults.data(forKey: UsageStatisticsStore.storageKey))
        XCTAssertTrue(fixture.controller.end())
        fixture.model.finishSessionFeatures()
        XCTAssertEqual(fixture.brightness.writes, [0, 0.7])
        XCTAssertNil(fixture.journal.record)
        XCTAssertNotNil(fixture.defaults.data(forKey: UsageStatisticsStore.storageKey))
        let restoredStatistics = UsageStatisticsStore(defaults: fixture.defaults)
        XCTAssertEqual(restoredStatistics.stats.days.reduce(0) { $0 + $1.lidClosedSeconds }, 30)
        XCTAssertNil(restoredStatistics.stats.lastTick)
        XCTAssertFalse(fixture.controller.status.holding)
        XCTAssertFalse(fixture.controller.status.manualActive)
    }
}
