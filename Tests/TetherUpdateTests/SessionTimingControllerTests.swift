import AppKit
import XCTest
@testable import Tether
import TetherCore

private final class TimingDefaults: UserDefaults {
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

private final class TimingAssertion: IdleAssertionBackend {
    var creates = 0
    var renews = 0
    var releases = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (0, 17) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { renews += 1; return 0 }
    func level(id: UInt32) -> Int? { 255 }
    func release(id: UInt32) -> Int32 { releases += 1; return 0 }
}


final class SessionTimingControllerTests: XCTestCase {
    func testSelectionDoesNotStartOrRetimeTheRequestWhileFullExtensionsPreserveItsIdentity() async throws {
        try await MainActor.run {
            let defaults = TimingDefaults(), backend = TimingAssertion()
            let subject = UserSessionController(defaults: defaults, backend: backend, guiProbe: nil, environmentProbe: nil, boot: "fixture")
            defer { _ = subject.end() }
            let now = ContinuousTime.now
            subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now)
            let model = AppModel(preview: true,
                capabilities: MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false),
                previewSession: subject, previewDefaults: defaults)
            model.selectManualDuration(900)
            XCTAssertEqual(model.selectedManualMinutes, 15)
            XCTAssertFalse(model.manualSessionActive); XCTAssertEqual(backend.creates, 0)
            model.startManualSession(minutes: model.selectedManualMinutes)
            let start = subject.status.manualStartedAt
            let requestID = subject.status.manualRequestID
            let deadline = try XCTUnwrap(subject.status.manualContinuousDeadline)
            model.selectManualDuration(3600)
            XCTAssertEqual(subject.status.manualStartedAt, start)
            XCTAssertEqual(subject.status.manualContinuousDeadline, deadline)
            XCTAssertFalse(subject.extend(duration: 3600))
            XCTAssertFalse(subject.rescheduleManual(duration: 3600))
            XCTAssertEqual(subject.status.manualContinuousDeadline, deadline)
            XCTAssertTrue(subject.extend(duration: 900))
            XCTAssertEqual(subject.status.manualContinuousDeadline, deadline + 900)
            XCTAssertTrue(subject.extend(duration: 1800))
            XCTAssertEqual(subject.status.manualContinuousDeadline, deadline + 2700)
            XCTAssertEqual(subject.status.manualStartedAt, start)
            XCTAssertEqual(subject.status.manualRequestID, requestID)
            XCTAssertEqual(model.selectedManualMinutes, 60)
            model.endManualSession()
            XCTAssertFalse(model.manualSessionActive)
            XCTAssertEqual(model.selectedManualMinutes, 60)
        }
    }

    func testClockLabelUsesContinuousDeadlineDespiteWallClockChanges() async throws {
        try await MainActor.run {
            let defaults = TimingDefaults()
            var wall = Date()
            let now = 512.0.nextDown.nextDown
            let subject = UserSessionController(defaults: defaults, backend: TimingAssertion(),
                guiProbe: nil, environmentProbe: nil, boot: "fixture", wallClock: { wall },
                continuousClock: { now })
            defer { _ = subject.end() }
            subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now)
            let model = AppModel(preview: true,
                capabilities: MacCapabilities(supportedPlatform: true, internalBattery: false, lid: false),
                previewSession: subject, previewDefaults: defaults)
            XCTAssertTrue(subject.start(duration: 900, now: now))
            let deadline = try XCTUnwrap(subject.status.manualContinuousDeadline)
            XCTAssertGreaterThan(deadline - (now + 120), 780, "Exercise clock subtraction rounding above the boundary")
            XCTAssertEqual(model.manualRemaining(at: wall, continuousNow: now + 120), 780)
            XCTAssertEqual(model.manualCountdown(at: wall, continuousNow: now + 120), "13:00")
            XCTAssertEqual(model.manualCountdown(at: wall, continuousNow: now + 119.75), "13:01")
            wall = wall.addingTimeInterval(3600)
            subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now + 120)
            XCTAssertEqual(subject.status.manualContinuousDeadline, deadline)
            XCTAssertEqual(model.manualCountdown(at: wall, continuousNow: now + 120), "13:00")
            XCTAssertEqual(try XCTUnwrap(model.manualSessionUntil).timeIntervalSince(wall), 780, accuracy: 0.001)
        }
    }

    func testRetiredContinuationCannotSurviveUnplugAndDirectBatteryStartKeepsItsDeadlineDuringACVisit() async throws {
        try await MainActor.run {
            let defaults = TimingDefaults()
            let subject = UserSessionController(defaults: defaults, backend: TimingAssertion(), guiProbe: nil, environmentProbe: nil, boot: "fixture")
            defer { _ = subject.end() }
            let now = ContinuousTime.now
            subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now, batteryPercent: 80)
            XCTAssertFalse(subject.setManualBatteryContinuationMinutes(120, now: now))
            XCTAssertTrue(subject.start(duration: nil, now: now))
            XCTAssertFalse(subject.setManualBatteryContinuationMinutes(120, now: now + 1))
            XCTAssertNil(subject.status.manualBatteryContinuationMinutes)
            subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: now + 2, batteryPercent: 80)
            XCTAssertFalse(subject.status.manualActive)
            XCTAssertEqual(subject.status.manualEndReason, .powerDisconnected)
            XCTAssertNil(subject.status.manualContinuousDeadline)
            XCTAssertFalse(subject.extend(duration: 900, now: now + 2))
            XCTAssertTrue(subject.start(duration: 900, now: now + 3))
            let requestID = subject.status.manualRequestID
            let deadline = try XCTUnwrap(subject.status.manualContinuousDeadline)
            XCTAssertEqual(deadline, now + 903, accuracy: 0.001)
            XCTAssertEqual(subject.status.manualStartedOnBattery, true)
            XCTAssertNil(subject.status.manualBatteryContinuationMinutes)
            XCTAssertTrue(subject.setManualBatteryContinuationMinutes(nil, now: now + 4))
            subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now + 65, batteryPercent: 80)
            XCTAssertEqual(subject.status.manualRequestID, requestID)
            XCTAssertEqual(subject.status.manualContinuousDeadline, deadline)
            subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: now + 125, batteryPercent: 80)
            XCTAssertFalse(subject.status.manualActive)
            XCTAssertEqual(subject.status.manualEndReason, .powerDisconnected)
            XCTAssertNil(subject.status.manualRequestID)
            XCTAssertNil(subject.status.manualContinuousDeadline)
            XCTAssertFalse(subject.extend(duration: 1800, now: now + 125))
        }
    }

}
