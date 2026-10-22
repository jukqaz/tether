import XCTest
@testable import Tether
import TetherCore

final class NativeUIAutomationGateTests: XCTestCase {
    func testProductionAndPreviewBundlesCannotEnterFixtureEvenWithEnvironmentAndMarker() {
        for id in ["io.github.jukqaz.tether", "io.github.jukqaz.tether.preview", "", nil] {
            XCTAssertFalse(NativeUIAutomation.isRequested(bundleID: id, fixture: true,
                environment: ["TETHER_UI_TESTING": "1"]))
        }
    }

    func testPrivateBundleRequiresBothMarkerAndExplicitEnvironment() {
        let id = NativeUIAutomation.bundleID
        XCTAssertFalse(NativeUIAutomation.isRequested(bundleID: id, fixture: nil,
            environment: ["TETHER_UI_TESTING": "1"]))
        XCTAssertFalse(NativeUIAutomation.isRequested(bundleID: id, fixture: true, environment: [:]))
        XCTAssertFalse(NativeUIAutomation.isRequested(bundleID: id, fixture: true,
            environment: ["TETHER_UI_TESTING": "0"]))
        XCTAssertTrue(NativeUIAutomation.isRequested(bundleID: id, fixture: true,
            environment: ["TETHER_UI_TESTING": "1"]))
    }

    func testUniquePrivateRunIDIsStrictlyScoped() {
        let prefix = NativeUIAutomation.bundleID + "."
        XCTAssertTrue(NativeUIAutomation.isRequested(bundleID: prefix + String(repeating: "a", count: 32),
            fixture: true, environment: ["TETHER_UI_TESTING": "1"]))
        for suffix in ["", "preview", String(repeating: "a", count: 31), String(repeating: "G", count: 32)] {
            XCTAssertFalse(NativeUIAutomation.isRequested(bundleID: prefix + suffix,
                fixture: true, environment: ["TETHER_UI_TESTING": "1"]))
        }
    }

    func testRecordingExceptionRequiresUniqueMarkedFixtureAndItsMockController() {
        let unique = NativeUIAutomation.bundleID + "." + String(repeating: "a", count: 32)
        let environment = ["TETHER_UI_TESTING": "1"]
        XCTAssertTrue(NativeUIAutomation.allowsInMemoryRecording(bundleID: unique, fixture: true,
            environment: environment, hasFixtureSession: true))
        XCTAssertFalse(NativeUIAutomation.allowsInMemoryRecording(bundleID: unique, fixture: true,
            environment: environment, hasFixtureSession: false))
        for id in ["io.github.jukqaz.tether", "io.github.jukqaz.tether.preview", NativeUIAutomation.bundleID,
                   NativeUIAutomation.bundleID + ".preview", nil] {
            XCTAssertFalse(NativeUIAutomation.allowsInMemoryRecording(bundleID: id, fixture: true,
                environment: environment, hasFixtureSession: true))
        }
        XCTAssertFalse(NativeUIAutomation.allowsInMemoryRecording(bundleID: unique, fixture: nil,
            environment: environment, hasFixtureSession: true))
        XCTAssertFalse(NativeUIAutomation.allowsInMemoryRecording(bundleID: unique, fixture: true,
            environment: [:], hasFixtureSession: true))
    }

    func testFixtureRefreshAllowsExplicitStartAfterObservationTTL() async {
        await MainActor.run {
            for power in [PowerSource.ac, .battery] {
                let system = ObservationAssertion(), display = ObservationAssertion()
                let controller = UserSessionController(defaults: ObservationDefaults(), backend: system,
                    displayBackend: display, guiProbe: nil, environmentProbe: nil, boot: "native-ui-fixture")
                var now = ContinuousTime.now
                let pump = NativeUITestObservationPump(controller: controller, power: power,
                    thermal: 0, batteryPercent: 80, clock: { now })
                defer { pump.stop(); _ = controller.end() }
                pump.refresh()

                now += 16
                XCTAssertFalse(controller.start(duration: 1800, now: now),
                    "An expired fixture observation must still fail the production freshness gate")
                XCTAssertFalse(controller.status.manualActive)
                XCTAssertEqual(system.creates, 0)

                pump.refresh()
                XCTAssertEqual(pump.lastObservedAt, now)
                XCTAssertEqual(controller.status.power, power)
                XCTAssertFalse(controller.status.manualActive, "Refreshing facts must not start work")
                XCTAssertTrue(controller.start(duration: 1800, now: now))
                XCTAssertTrue(controller.status.manualActive)
                XCTAssertTrue(controller.status.holding)
                XCTAssertEqual(system.creates, 1)
            }
        }
    }

    func testFixtureRefreshDoesNotBypassThermalProtection() async {
        await MainActor.run {
            let system = ObservationAssertion(), display = ObservationAssertion()
            let controller = UserSessionController(defaults: ObservationDefaults(), backend: system,
                displayBackend: display, guiProbe: nil, environmentProbe: nil, boot: "native-ui-fixture")
            var now = ContinuousTime.now
            let pump = NativeUITestObservationPump(controller: controller, power: .ac,
                thermal: 2, batteryPercent: 80, clock: { now })
            defer { pump.stop(); _ = controller.end() }
            pump.refresh()
            now += 16
            pump.refresh()
            XCTAssertFalse(controller.start(duration: 1800, now: now))
            XCTAssertFalse(controller.status.manualActive)
            XCTAssertFalse(controller.status.holding)
            XCTAssertEqual(system.creates, 0)
        }
    }
}

private final class ObservationAssertion: IdleAssertionBackend {
    private var active: Set<UInt32> = []
    private(set) var creates = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        creates += 1
        let id = UInt32(creates)
        active.insert(id)
        return (0, id)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { active.contains(id) ? 0 : -1 }
    func level(id: UInt32) -> Int? { active.contains(id) ? 255 : 0 }
    func release(id: UInt32) -> Int32 { active.remove(id); return 0 }
}

private final class ObservationDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
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
}
