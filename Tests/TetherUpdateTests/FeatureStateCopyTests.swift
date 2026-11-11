import AppKit
import XCTest
import TetherCore
@testable import Tether

private final class FeatureStateDefaults: UserDefaults {
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
    override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
    override func persistentDomain(forName name: String) -> [String: Any]? { values }
    override func setPersistentDomain(_ domain: [String: Any], forName name: String) { values = domain }
    override func removePersistentDomain(forName name: String) { values.removeAll() }
    override func synchronize() -> Bool { true }
}

private final class FeatureStateAssertion: IdleAssertionBackend {
    var creates = 0
    var releases = 0
    var releaseFails = false
    private var ids: Set<UInt32> = []
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        creates += 1
        let id = UInt32(creates)
        ids.insert(id)
        return (0, id)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { ids.contains(id) ? 0 : -1 }
    func level(id: UInt32) -> Int? { ids.contains(id) ? 255 : 0 }
    func release(id: UInt32) -> Int32 {
        releases += 1
        guard !releaseFails else { return -1 }
        ids.remove(id)
        return 0
    }
}

/// Shared state copy is read-only; all work, helper and preference effects are simulated.
final class FeatureStateCopyTests: XCTestCase {
    private enum Scenario: CaseIterable {
        case automatic, manual, dual, allStopped, protection, manualWithAutomaticRest

        var arguments: [String] {
            let common = ["--sample", "--prepared-lid", "--display-on"]
            switch self {
            case .automatic: return common
            case .manual: return common + ["--manual", "--timed"]
            case .dual: return common + ["--manual", "--timed", "--dual"]
            case .allStopped: return common + ["--manual", "--timed", "--dual", "--paused"]
            case .protection: return common + ["--manual", "--timed", "--dual", "--protection"]
            case .manualWithAutomaticRest:
                return common + ["--manual", "--timed", "--dual", "--automatic-rest"]
            }
        }

        var stopped: Bool { self == .allStopped || self == .protection }
        var manualActive: Bool { self == .manual || self == .dual || self == .manualWithAutomaticRest }
        var automaticActive: Bool { self == .automatic || self == .dual }
    }

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { _ = NSApplication.shared }
    }

    @MainActor
    func testFeatureCopyMatchesAutomaticManualDualStopAndProtectionWithoutMutatingWork() async throws {
        let previous = Localization.current
        defer { Localization.current = previous }
        for language in [Language.english, .korean] {
            Localization.current = language
            for scenario in Scenario.allCases {
                let model = PreviewRenderer.sampleModel(arguments: scenario.arguments)
                let controller = try XCTUnwrap(model.userSession)
                defer { _ = controller.end() }
                for _ in 0..<1000 {
                    if model.helperSetupConfirmed, !model.lidCommandPending,
                       scenario.stopped || model.lidSupportConfirmed { break }
                    await Task.yield()
                }
                let context = "\(language) / \(scenario)"
                XCTAssertTrue(model.userCommandsArePreview, context)
                XCTAssertFalse(model.defaults === UserDefaults.standard, context)
                XCTAssertTrue(model.helperSetupConfirmed, context)
                XCTAssertFalse(model.lidCommandPending, context)
                XCTAssertTrue(model.v3Settings.allowClosedLid, context)
                XCTAssertTrue(model.v3Settings.keepDisplayAwake, context)
                XCTAssertEqual(controller.status.manualActive, scenario.manualActive, context)
                XCTAssertEqual(controller.status.automaticActive, scenario.automaticActive, context)
                XCTAssertEqual(model.automaticPauseActive, scenario == .manualWithAutomaticRest, context)
                XCTAssertEqual(controller.status.holding, !scenario.stopped, context)
                XCTAssertEqual(controller.status.displayHolding, !scenario.stopped, context)

                if scenario == .allStopped {
                    XCTAssertEqual(controller.runtimeMarkers.pauseReason, .userStop, context)
                    XCTAssertNil(model.workProtectionReason, context)
                } else if scenario == .protection {
                    XCTAssertEqual(model.workProtectionReason, "thermal", context)
                }

                let helperBefore = try await model.performWorkService(ServiceRequest(.snapshot))
                XCTAssertEqual(helperBefore.protection?.dryRun, true, context)
                let status = controller.status
                let request = controller.manualRequestID
                let deadline = status.manualContinuousDeadline
                let saved = model.defaults.data(forKey: UserSessionController.preferenceKey)
                XCTAssertNotNil(saved, context)
                let controls = MenuKeepAwakeControls(model: model, canEdit: MenuActionVisibility(model: model).showsQuickOptions)
                if scenario.stopped {
                    // Showing these saved values in the menu must not make them writable.
                    XCTAssertTrue(controls.lidControlDisabled, context)
                    XCTAssertTrue(controls.controlsDisabled, context)
                    controls.lidBinding.wrappedValue = false
                    controls.displayBinding.wrappedValue = false
                    XCTAssertTrue(model.v3Settings.allowClosedLid, context)
                    XCTAssertTrue(model.v3Settings.keepDisplayAwake, context)
                }
                for _ in 0..<10 {
                    let display = model.displayUsageStatusText
                    let lid = model.lidUsageStatusText
                    XCTAssertEqual(controls.displayStatusDetail, display, context)
                    XCTAssertEqual(controls.lidStatusDetail, lid, context)
                    if scenario.stopped {
                        let summary = scenario == .protection
                            ? L("Stopped for protection", "보호로 중지됨")
                            : L("All keep-awake stopped", "모두 중지됨")
                        XCTAssertEqual(model.featureStopSummary, summary, context)
                        XCTAssertTrue(display.contains(summary), display)
                        XCTAssertTrue(lid.contains(summary), lid)
                        XCTAssertTrue(model.automaticStartStateDetail.contains(summary), model.automaticStartStateDetail)
                        assertNoActiveFeatureClaim(display, lid)
                        XCTAssertFalse(model.automaticStartStateDetail.localizedCaseInsensitiveContains("remains available"), context)
                        XCTAssertFalse(model.automaticStartStateDetail.contains("사용할 수"), context)
                    } else {
                        XCTAssertNil(model.featureStopSummary, context)
                    }
                }
                XCTAssertEqual(controller.status, status, context)
                XCTAssertEqual(controller.manualRequestID, request, context)
                XCTAssertEqual(controller.status.manualContinuousDeadline, deadline, context)
                XCTAssertEqual(model.defaults.data(forKey: UserSessionController.preferenceKey), saved, context)
                let helperAfter = try await model.performWorkService(ServiceRequest(.snapshot))
                // Reply IDs and sampling timestamps change on a read; stable work intent must not.
                XCTAssertEqual(helperAfter.status?.workSession?.sessionID, helperBefore.status?.workSession?.sessionID, context)
                XCTAssertEqual(helperAfter.status?.workSession?.manualRequestID, helperBefore.status?.workSession?.manualRequestID, context)
                XCTAssertEqual(helperAfter.status?.workSession?.manualDeadline, helperBefore.status?.workSession?.manualDeadline, context)
                XCTAssertEqual(helperAfter.status?.workSession?.configuration, helperBefore.status?.workSession?.configuration, context)
                XCTAssertEqual(helperAfter.status?.workSession?.reasons, helperBefore.status?.workSession?.reasons, context)
                XCTAssertEqual(helperAfter.status?.observedLidClosed, helperBefore.status?.observedLidClosed, context)
                XCTAssertEqual(helperAfter.status?.observedSleepDisabled, helperBefore.status?.observedSleepDisabled, context)
                XCTAssertEqual(helperAfter.status?.ownsOverride, helperBefore.status?.ownsOverride, context)
            }
        }
    }

    @MainActor
    func testUnconfirmedOwnReleaseTakesPriorityWithoutClaimingAnInactiveCompletion() throws {
        let previous = Localization.current
        defer { Localization.current = previous }
        for language in [Language.english, .korean] {
            Localization.current = language
            let defaults = FeatureStateDefaults()
            let backend = FeatureStateAssertion(), displayBackend = FeatureStateAssertion()
            let controller = UserSessionController(defaults: defaults, backend: backend,
                displayBackend: displayBackend, guiProbe: nil, environmentProbe: nil,
                boot: "feature-state-copy-fixture")
            defer { backend.releaseFails = false; _ = controller.end() }
            controller.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            controller.setAllowClosedLid(true)
            controller.setKeepDisplayAwake(true)
            let model = AppModel(preview: true,
                capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
                previewSession: controller,
                previewLegacyObservation: { .init(power: .ac, lidClosed: false, sleepDisabled: false, fullWake: true) },
                previewWorkService: { _ in throw ServiceFailure("feature-state-copy-fixture-isolated") },
                previewDefaults: defaults, previewHelperFiles: { [] })
            XCTAssertTrue(controller.start(duration: 1800))
            backend.releaseFails = true
            controller.endManual()
            XCTAssertEqual(controller.status.ownReleasePending, true)
            XCTAssertTrue(model.v3Settings.allowClosedLid)
            XCTAssertTrue(model.v3Settings.keepDisplayAwake)
            let status = controller.status
            let request = controller.manualRequestID
            let deadline = status.manualContinuousDeadline
            let saved = defaults.data(forKey: UserSessionController.preferenceKey)
            XCTAssertNotNil(saved)
            let counts = [backend.creates, backend.releases, displayBackend.creates, displayBackend.releases]
            let summary = L("Checking keep-awake release", "해제 확인 중")
            let controls = MenuKeepAwakeControls(model: model, openHelperSetup: {})
            for _ in 0..<10 {
                XCTAssertNil(model.featureStopSummary, "An unconfirmed release is separate from a stop or protection reason")
                XCTAssertTrue(model.displayUsageStatusText.contains(summary), model.displayUsageStatusText)
                XCTAssertTrue(model.lidUsageStatusText.contains(summary), model.lidUsageStatusText)
                XCTAssertTrue(model.automaticStartStateDetail.localizedCaseInsensitiveContains(L("release", "해제")),
                              model.automaticStartStateDetail)
                XCTAssertEqual(controls.displayStatusDetail, model.displayUsageStatusText)
                XCTAssertEqual(controls.lidStatusDetail, model.lidUsageStatusText)
                assertNoActiveFeatureClaim(model.displayUsageStatusText, model.lidUsageStatusText)
                XCTAssertFalse(model.displayUsageStatusText.localizedCaseInsensitiveContains("no keep-awake session"))
                XCTAssertFalse(model.lidUsageStatusText.localizedCaseInsensitiveContains("no keep-awake session"))
                XCTAssertFalse(model.displayUsageStatusText.contains("현재 유지 없음"))
                XCTAssertFalse(model.lidUsageStatusText.contains("현재 유지 없음"))
            }
            XCTAssertEqual(controller.status, status)
            XCTAssertEqual(controller.manualRequestID, request)
            XCTAssertEqual(controller.status.manualContinuousDeadline, deadline)
            XCTAssertEqual(defaults.data(forKey: UserSessionController.preferenceKey), saved)
            XCTAssertEqual([backend.creates, backend.releases, displayBackend.creates, displayBackend.releases], counts)
        }
    }

    private func assertNoActiveFeatureClaim(_ values: String...,
                                           file: StaticString = #filePath, line: UInt = #line) {
        for value in values {
            for claim in ["ready for closed-lid use", "support active", "requested", "준비됨", "요청 중", "적용 중"] {
                XCTAssertFalse(value.localizedCaseInsensitiveContains(claim), value, file: file, line: line)
            }
        }
    }
}
