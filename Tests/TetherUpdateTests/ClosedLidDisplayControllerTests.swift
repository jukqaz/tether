import XCTest
@testable import Tether
import TetherCore

private final class ClosedDisplayMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func synchronize() -> Bool { true }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

private final class ClosedDisplayAssertionFixture: IdleAssertionBackend {
    var creates = 0
    var renews = 0
    var releases = 0
    var levelValue: Int? = 255
    var releaseCode: Int32 = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) { creates += 1; return (0, UInt32(creates)) }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 { renews += 1; return 0 }
    func level(id: UInt32) -> Int? { levelValue }
    func release(id: UInt32) -> Int32 { releases += 1; return releaseCode }
}

final class ClosedLidDisplayControllerTests: XCTestCase {
    func testDisplayContextBeforeFirstObservationCannotConsumeLegacyGeneralIntent() async throws {
        try await MainActor.run {
            let defaults = ClosedDisplayMemoryDefaults()
            var settings = IdleSessionSettings()
            settings.automaticEnabled = true
            settings.legacyRootConfigurationPending = false
            defaults.set(try JSONEncoder().encode(settings), forKey: UserSessionController.preferenceKey)
            let backend = ClosedDisplayAssertionFixture()
            let display = ClosedDisplayAssertionFixture()
            let subject = UserSessionController(defaults: defaults, backend: backend, displayBackend: display,
                guiProbe: nil, environmentProbe: nil, boot: "fixture")
            defer { _ = subject.end() }
            subject.setClosedLidDisplayContext(lidClosed: false, zeroBrightnessEligible: false)
            XCTAssertNil(subject.runtimeMarkers.pauseReason)
            XCTAssertFalse(subject.status.holding)
            XCTAssertEqual(backend.creates, 0)
            subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                now: ContinuousTime.now, batteryPercent: 80)
            XCTAssertNil(subject.runtimeMarkers.pauseReason)
            XCTAssertTrue(subject.status.automaticActive)
            XCTAssertTrue(subject.status.holding)
            XCTAssertEqual(backend.creates, 1)
            XCTAssertEqual(display.creates, 0)
        }
    }

    @MainActor
    private func fixture(_ body: (UserSessionController, ClosedDisplayAssertionFixture, ClosedDisplayAssertionFixture, Double) throws -> Void) throws {
        let defaults = ClosedDisplayMemoryDefaults()
        var settings = IdleSessionSettings()
        settings.legacyRootConfigurationPending = false
        settings.allowClosedLid = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(IdleSessionSettings.self, from: data)
        XCTAssertTrue(decoded.isSupported, "Serialized fixture settings must be supported: \(decoded)")
        defaults.set(data, forKey: UserSessionController.preferenceKey)
        let system = ClosedDisplayAssertionFixture(), display = ClosedDisplayAssertionFixture()
        let subject = UserSessionController(defaults: defaults, backend: system, displayBackend: display,
            guiProbe: nil, environmentProbe: nil, boot: "fixture")
        defer { _ = subject.end() }
        let now = ContinuousTime.now
        subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now, batteryPercent: 80)
        XCTAssertNil(subject.status.error, "Initial fixture authority: \(subject.status)")
        try body(subject, system, display, now)
    }

    func testZeroBrightnessRequiresClosedLidAndVerifiedEligibilityAndUsesWorkDeadline() async throws {
        try await MainActor.run {
            try fixture { subject, system, display, now in
                XCTAssertTrue(subject.setClosedLidDisplayMode(.zeroBrightness))
                XCTAssertTrue(subject.start(duration: 1800, now: now))
                subject.setClosedLidDisplayContext(lidClosed: true, zeroBrightnessEligible: false)
                XCTAssertEqual(display.creates, 0)
                XCTAssertFalse(subject.closedLidDisplayAssertionConfirmed)
                subject.setClosedLidDisplayContext(lidClosed: true, zeroBrightnessEligible: true)
                XCTAssertEqual(display.creates, 1)
                XCTAssertTrue(subject.closedLidDisplayAssertionConfirmed)
                XCTAssertTrue(subject.status.holding)
                XCTAssertEqual(system.creates, 1)
                let lease = try XCTUnwrap(subject.workLease(now: now))
                XCTAssertEqual(lease.effectiveClosedLidDisplayMode, .zeroBrightness)
                XCTAssertLessThanOrEqual(try XCTUnwrap(lease.expiry), now + IdleSessionPolicy.healthTTL)
                subject.setClosedLidDisplayContext(lidClosed: false, zeroBrightnessEligible: false)
                XCTAssertEqual(display.releases, 1)
                XCTAssertFalse(subject.closedLidDisplayAssertionConfirmed)
                XCTAssertTrue(subject.status.manualActive)
            }
        }
    }

    func testClosedOffAndUnchangedSuppressOpenDisplayRequestWithoutRejectingWork() async throws {
        try await MainActor.run {
            for mode in [ClosedLidDisplayMode.off, .unchanged] {
                try fixture { subject, _, display, now in
                    subject.setKeepDisplayAwake(true)
                    XCTAssertTrue(subject.setClosedLidDisplayMode(mode))
                    subject.setClosedLidDisplayContext(lidClosed: true, zeroBrightnessEligible: false)
                    XCTAssertTrue(subject.start(duration: 1800, now: now))
                    XCTAssertEqual(display.creates, 0)
                    XCTAssertTrue(subject.manualDisplayConfirmed)
                    XCTAssertTrue(subject.status.holding)
                    subject.setClosedLidDisplayContext(lidClosed: false, zeroBrightnessEligible: false)
                    XCTAssertEqual(display.creates, 1)
                    XCTAssertEqual(subject.status.displayHolding, true)
                }
            }
        }
    }

    func testUnknownObservationAllowsExplicitLidRevocationButNoReplacementGrant() async throws {
        try await MainActor.run {
            try fixture { subject, system, _, now in
                XCTAssertTrue(subject.start(duration: 1800, now: now))
                let original = try XCTUnwrap(subject.workLease(now: now))
                XCTAssertNotNil(original.lidPermit)
                subject.update(power: .unknown, thermal: 0, fullWake: true, controllingUser: true, now: now + 1)
                let renews = system.renews
                XCTAssertNil(subject.workLease(now: now + 1))
                subject.setAllowClosedLid(false)
                let release = try XCTUnwrap(subject.workLease(now: now + 1))
                XCTAssertTrue(release.isValid(now: now + 1))
                XCTAssertTrue(release.reasons.isEmpty)
                XCTAssertNil(release.expiry)
                XCTAssertNil(release.lidPermit)
                XCTAssertGreaterThan(release.sequence, original.sequence)
                XCTAssertTrue(subject.status.manualActive)
                XCTAssertTrue(subject.status.holding)
                XCTAssertEqual(system.renews, renews)
                subject.setAllowClosedLid(true)
                XCTAssertNil(subject.workLease(now: now + 1))
            }
        }
    }

    func testUnknownAutomaticOffRevokesHelperWithoutConsumingManualWork() async throws {
        try await MainActor.run {
            try fixture { subject, system, _, now in
                subject.setAutomatic(true)
                XCTAssertTrue(subject.start(duration: 1800, now: now))
                let original = try XCTUnwrap(subject.workLease(now: now))
                XCTAssertEqual(Set(original.reasons), Set([.automatic, .manual]))
                subject.update(power: .ac, thermal: nil, fullWake: true, controllingUser: true, now: now + 1)
                let renews = system.renews
                subject.setAutomatic(false)
                let release = try XCTUnwrap(subject.workLease(now: now + 1))
                XCTAssertTrue(release.reasons.isEmpty)
                XCTAssertNil(release.lidPermit)
                XCTAssertFalse(subject.status.automaticActive)
                XCTAssertTrue(subject.status.manualActive)
                XCTAssertTrue(subject.status.holding)
                XCTAssertEqual(system.renews, renews)
            }
        }
    }

    func testUnknownBrightnessEligibilityCannotAcquireOrRearmDisplayAssertion() async throws {
        try await MainActor.run {
            try fixture { subject, _, display, now in
                XCTAssertTrue(subject.setClosedLidDisplayMode(.zeroBrightness))
                XCTAssertTrue(subject.start(duration: 1800, now: now))
                subject.update(power: .unknown, thermal: 0, fullWake: true, controllingUser: true, now: now + 1)
                subject.setClosedLidDisplayContext(lidClosed: true, zeroBrightnessEligible: true)
                XCTAssertEqual(display.creates, 0)
                XCTAssertFalse(subject.closedLidDisplayAssertionConfirmed)
            }
        }
    }

    func testUnplugAndEndReleaseFiniteZeroBrightnessAssertion() async throws {
        try await MainActor.run {
            try fixture { subject, _, display, now in
                XCTAssertTrue(subject.setClosedLidDisplayMode(.zeroBrightness))
                XCTAssertTrue(subject.start(duration: 1800, now: now))
                subject.setClosedLidDisplayContext(lidClosed: true, zeroBrightnessEligible: true)
                XCTAssertTrue(subject.closedLidDisplayAssertionConfirmed)
                subject.update(power: .battery, thermal: 0, fullWake: true, controllingUser: true, now: now + 1, batteryPercent: 80)
                XCTAssertFalse(subject.status.holding)
                XCTAssertFalse(subject.closedLidDisplayAssertionConfirmed)
                XCTAssertEqual(display.releases, 1)
                XCTAssertTrue(subject.end())
                XCTAssertEqual(display.releases, 1)
            }
        }
    }

    func testUnconfirmedReleaseBlocksEveryNewStartAndResumeUntilConfirmed() async throws {
        try await MainActor.run {
            try fixture { subject, system, _, now in
                XCTAssertTrue(subject.start(duration: 1800, now: now))
                system.releaseCode = -1
                subject.stopCurrent()
                XCTAssertEqual(subject.status.ownReleasePending, true)
                XCTAssertFalse(subject.status.canStart)
                XCTAssertFalse(subject.status.canStartBatteryHold)
                XCTAssertFalse(subject.canResume)
                XCTAssertFalse(subject.start(duration: 1800, now: now))
                XCTAssertFalse(subject.startBatteryHold(minutes: 30, now: now))
                XCTAssertFalse(subject.setEnabled(true))
                XCTAssertFalse(subject.resumeAutomatic(now: now))
                XCTAssertEqual(system.creates, 1)
                system.releaseCode = 0
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true, now: now + 1, batteryPercent: 80)
                XCTAssertEqual(subject.status.ownReleasePending, false)
                XCTAssertTrue(subject.canResume)
                XCTAssertTrue(subject.setEnabled(true))
                XCTAssertTrue(subject.start(duration: 1800, now: now + 1))
                XCTAssertEqual(system.creates, 2)
            }
        }
    }

    func testAutomaticPauseExpiryCannotRenewAnUnreleasedOldAllocation() async throws {
        try await MainActor.run {
            try fixture { subject, system, _, now in
                subject.setAutomatic(true)
                XCTAssertTrue(subject.status.automaticActive)
                XCTAssertEqual(system.creates, 1)
                let renews = system.renews
                system.releaseCode = -1
                XCTAssertTrue(subject.pauseAutomatic(for: 1800, now: now))
                XCTAssertEqual(subject.status.ownReleasePending, true)
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: now + 1801, batteryPercent: 80)
                XCTAssertTrue(subject.status.automaticActive)
                XCTAssertFalse(subject.status.holding)
                XCTAssertEqual(subject.status.ownReleasePending, true)
                XCTAssertEqual(system.creates, 1)
                XCTAssertEqual(system.renews, renews)
                XCTAssertFalse(subject.status.canStart)
                system.releaseCode = 0
                subject.update(power: .ac, thermal: 0, fullWake: true, controllingUser: true,
                    now: now + 1802, batteryPercent: 80)
                XCTAssertEqual(subject.status.ownReleasePending, false)
                XCTAssertTrue(subject.status.holding)
                XCTAssertEqual(system.creates, 2)
                XCTAssertEqual(system.renews, renews)
            }
        }
    }
}
