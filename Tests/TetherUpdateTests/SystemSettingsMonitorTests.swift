import XCTest
@testable import Tether
import TetherCore

private final class SystemSettingsMemoryDefaults: UserDefaults, @unchecked Sendable {
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
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
    override func persistentDomain(forName name: String) -> [String: Any]? { values }
    override func setPersistentDomain(_ domain: [String: Any], forName name: String) { values = domain }
    override func removePersistentDomain(forName name: String) { values.removeAll() }
}

private final class SystemSettingsAssertionFixture: IdleAssertionBackend {
    var commands = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { commands += 1; return (0, 41) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { commands += 1; return 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { commands += 1; return 0 }
}

private actor SystemSettingsFixtureReader {
    private var results: [SystemSettingsMonitor.Reading]
    private(set) var calls = 0
    init(_ results: [SystemSettingsMonitor.Reading]) { self.results = results }
    func read() -> SystemSettingsMonitor.Reading {
        calls += 1
        return results.count > 1 ? results.removeFirst() : results[0]
    }
}

private actor PendingSystemSettingsReader {
    private var pending: [CheckedContinuation<SystemSettingsMonitor.Reading, Never>] = []
    private(set) var calls = 0
    func read() async -> SystemSettingsMonitor.Reading {
        calls += 1
        return await withCheckedContinuation { pending.append($0) }
    }
    func finish(_ value: SystemSettingsMonitor.Reading) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: value)
    }
}

final class SystemSettingsMonitorTests: XCTestCase {
    private static func value(_ lock: ScreenLockPolicy, configured: Bool = true, disabled: Bool? = false) -> SystemSettingsMonitor.Reading {
        .init(screenLock: lock, loginItemConfigured: configured, loginItemDisabled: disabled)
    }
    @MainActor private func settled(_ monitor: SystemSettingsMonitor) async {
        let until = ContinuousTime.now + 3
        while ContinuousTime.now < until {
            if !monitor.reading { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Fixture observation did not settle")
    }
    private func waitFor(_ reader: PendingSystemSettingsReader, calls: Int) async {
        let until = ContinuousTime.now + 3
        while ContinuousTime.now < until {
            if await reader.calls >= calls { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Fixture reader was not called")
    }

    @MainActor func testExternalChangesAndReadFailuresReplacePreviousState() async {
        let reader = SystemSettingsFixtureReader([Self.value(.off), Self.value(.immediate, disabled: true), Self.value(.unavailable, disabled: nil)])
        let monitor = SystemSettingsMonitor(simulated: true, reader: { await reader.read() })
        monitor.refresh(force: true); await settled(monitor)
        XCTAssertEqual(monitor.currentScreenLock, .off)
        monitor.refresh(force: true); await settled(monitor)
        XCTAssertEqual(monitor.currentScreenLock, .immediate)
        XCTAssertEqual(monitor.value.loginItemDisabled, true)
        monitor.refresh(force: true); await settled(monitor)
        XCTAssertEqual(monitor.currentScreenLock, .unavailable)
        XCTAssertNil(monitor.value.loginItemDisabled)
    }

    @MainActor func testPollingIsThrottledButReturnFromSettingsCanForceRefresh() async {
        var now = 100.0
        let reader = SystemSettingsFixtureReader([Self.value(.immediate), Self.value(.off)])
        let monitor = SystemSettingsMonitor(simulated: true, reader: { await reader.read() }, clock: { now })
        monitor.refresh(); await settled(monitor)
        now = 101; monitor.refresh(); await settled(monitor)
        let firstCalls = await reader.calls
        XCTAssertEqual(firstCalls, 1)
        monitor.refresh(force: true); await settled(monitor)
        XCTAssertEqual(monitor.currentScreenLock, .off)
        let finalCalls = await reader.calls
        XCTAssertEqual(finalCalls, 2)
    }

    @MainActor func testStaleAndBackwardClockEvidenceNeverReportsLockOff() async {
        var now = 100.0
        let monitor = SystemSettingsMonitor(simulated: true, reader: { Self.value(.off) }, clock: { now })
        monitor.refresh(); await settled(monitor)
        now = 144; XCTAssertEqual(monitor.currentScreenLock, .off)
        now = 145; XCTAssertEqual(monitor.currentScreenLock, .unavailable)
        now = 99; XCTAssertEqual(monitor.currentScreenLock, .unavailable)
        now = .nan; XCTAssertEqual(monitor.currentScreenLock, .unavailable)
    }

    @MainActor func testAppEditDiscardsOldReadAndCoalescesNextRead() async {
        let reader = PendingSystemSettingsReader()
        let monitor = SystemSettingsMonitor(simulated: true, reader: { await reader.read() })
        monitor.refresh(); await waitFor(reader, calls: 1)
        monitor.invalidate(); monitor.refresh(force: true); monitor.refresh(force: true)
        await reader.finish(Self.value(.off))
        await waitFor(reader, calls: 2)
        XCTAssertEqual(monitor.currentScreenLock, .unavailable)
        XCTAssertNil(monitor.checkedAt)
        await reader.finish(Self.value(.immediate, configured: false, disabled: nil))
        await settled(monitor)
        XCTAssertEqual(monitor.currentScreenLock, .immediate)
        XCTAssertFalse(monitor.value.loginItemConfigured)
        let calls = await reader.calls
        XCTAssertEqual(calls, 2)
    }

    @MainActor func testPreviewCannotQueryLiveSettings() {
        let monitor = SystemSettingsMonitor(simulated: true)
        monitor.refresh(force: true)
        XCTAssertFalse(monitor.reading)
        XCTAssertNil(monitor.checkedAt)
        XCTAssertEqual(monitor.currentScreenLock, .unavailable)
    }

    @MainActor func testAppReflectsExternalRegistrationWithoutChangingWorkOrPreferences() async {
        let reader = SystemSettingsFixtureReader([
            Self.value(.immediate, configured: true, disabled: true),
            Self.value(.off, configured: false, disabled: nil)
        ])
        let monitor = SystemSettingsMonitor(simulated: true, reader: { await reader.read() })
        let defaults = SystemSettingsMemoryDefaults()
        let backend = SystemSettingsAssertionFixture()
        let work = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil)
        work.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true,
                    now: ContinuousTime.now, batteryPercent: 80)
        XCTAssertTrue(work.start(duration: 180))
        defer { _ = work.end() }
        let model = AppModel(preview: true,
            capabilities: .init(supportedPlatform: true, internalBattery: true, lid: true),
            previewSession: work, previewDefaults: defaults, previewSystemSettings: monitor)
        let originalWork = work.status
        let originalPreferences = defaults.persistentDomain(forName: "fixture")! as NSDictionary
        let originalCommands = backend.commands
        monitor.refresh(force: true); await settled(monitor)
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertEqual(model.systemSettings.value.loginItemDisabled, true)
        monitor.refresh(force: true); await settled(monitor)
        XCTAssertFalse(model.launchAtLogin)
        XCTAssertEqual(work.status, originalWork)
        XCTAssertEqual(defaults.persistentDomain(forName: "fixture")! as NSDictionary, originalPreferences)
        XCTAssertEqual(backend.commands, originalCommands)
    }

    func testLoginItemOverridesSupportCurrentAndBooleanFormats() {
        for (state, expected) in [("enabled", false), ("disabled", true), ("false", false), ("true", true)] {
            XCTAssertEqual(SystemSettingsMonitor.loginItemDisabled(in: "disabled services = {\n\"local.tether.app\" => \(state)\n}", label: "local.tether.app"), expected)
        }
        XCTAssertEqual(SystemSettingsMonitor.loginItemDisabled(in: "disabled services = {\n\"another.app\" => disabled\n}", label: "local.tether.app"), false)
    }

    func testFailedPartialAndAmbiguousLoginItemOutputDoesNotMeanEnabled() {
        for output in ["", "permission denied", "disabled services = {", "disabled services = {\n\"local.tether.app\" => maybe\n}",
                       "disabled services = {\n\"local.tether.app\" => enabled\n\"local.tether.app\" => disabled\n}"] {
            XCTAssertNil(SystemSettingsMonitor.loginItemDisabled(in: output, label: "local.tether.app"))
        }
    }
}
