import XCTest
@testable import TetherCore

final class NativeClamshellTests: XCTestCase {
    private func screen(_ id: UInt32 = 42, vendor: UInt32 = 123, model: UInt32 = 456,
                        builtIn: Bool = false, active: Bool = true) -> DisplayObservation {
        .init(id: id, builtIn: builtIn, vendor: vendor, model: model, width: 2560,
              height: 1440, active: active, asleep: false)
    }
    private func report(_ displays: [DisplayObservation], transport: String = "spdisplays_hdmi") throws -> DisplayReport {
        let rows = displays.map {
            ["_spdisplays_displayID": String($0.id, radix: 16),
             "_spdisplays_display-vendor-id": String($0.vendor, radix: 16),
             "_spdisplays_display-product-id": String($0.model, radix: 16),
             "spdisplays_connection_type": transport]
        }
        let profile = try JSONSerialization.data(withJSONObject: ["SPDisplaysDataType": [["spdisplays_ndrvs": rows]]])
        return DisplayProbe.resolve(observations: displays, profile: profile)
    }
    func testWiredCandidateNeedsCurrentOSPolicyAndClearGlobalOverride() throws {
        let displays = [screen()]
        let evidence = try XCTUnwrap(NativeDisplayEvidence(report: report(displays)))
        var s = Snapshot(power: .ac, lidClosed: true, sleepDisabled: false, externalDisplay: true)
        XCTAssertTrue(evidence.available(snapshot: s, observations: displays, causesSleep: false))
        XCTAssertFalse(evidence.available(snapshot: s, observations: displays, causesSleep: true))
        XCTAssertFalse(evidence.available(snapshot: s, observations: displays, causesSleep: nil))
        s.sleepDisabled = true
        XCTAssertFalse(evidence.available(snapshot: s, observations: displays, causesSleep: false))
        s.sleepDisabled = false; s.power = .battery
        XCTAssertFalse(evidence.available(snapshot: s, observations: displays, causesSleep: false))
        s.power = .ac; s.fullWake = false
        XCTAssertFalse(evidence.available(snapshot: s, observations: displays, causesSleep: false))
    }
    func testVirtualWirelessUSBAndUnknownConnectionsDoNotQualify() throws {
        XCTAssertNil(NativeDisplayEvidence(report: try report([screen(vendor: 0xeee0, model: 0xeee1)])))
        for transport in ["spdisplays_usb", "spdisplays_airplay", "spdisplays_sidecar", "unknown"] {
            XCTAssertNil(NativeDisplayEvidence(report: try report([screen()], transport: transport)), transport)
        }
        XCTAssertNil(NativeDisplayEvidence(report: DisplayProbe.resolve(observations: [screen()], profile: nil)))
    }
    func testEvidenceRequiresExactLiveExternalIdentitiesAndAnActiveWiredOutput() throws {
        let evidence = try XCTUnwrap(NativeDisplayEvidence(report: report([screen()])))
        XCTAssertTrue(evidence.matches([screen()]))
        XCTAssertFalse(evidence.matches([screen(43)]))
        XCTAssertFalse(evidence.matches([screen(vendor: 124)]))
        XCTAssertFalse(evidence.matches([screen(model: 457)]))
        XCTAssertFalse(evidence.matches([screen(active: false)]))
        XCTAssertFalse(evidence.matches(nil))
        XCTAssertFalse(evidence.matches([screen(), screen()]))
    }
    func testBuiltInPanelDisappearingDoesNotInventAHotplug() throws {
        let displays = [screen(1, builtIn: true), screen()]
        let evidence = try XCTUnwrap(NativeDisplayEvidence(report: report(displays)))
        XCTAssertTrue(evidence.matches([screen()]))
    }
    func testMixedVirtualAndPhysicalSetupRequiresMatchedWiredPath() throws {
        let displays = [screen(), screen(43, vendor: 0xeee0, model: 0xeee1)]
        let evidence = try XCTUnwrap(NativeDisplayEvidence(report: report(displays)))
        XCTAssertTrue(evidence.matches(displays))
        XCTAssertFalse(evidence.matches([displays[1]]))
    }
    func testCacheRejectsOldResultAfterWakeOrDisplayInvalidation() throws {
        var cache = NativeDisplayProbeCache()
        let displays = [screen()]
        let generation = try XCTUnwrap(cache.begin(observations: displays, power: .ac, fullWake: true))
        cache.invalidate()
        XCTAssertFalse(cache.complete(generation: generation, report: try report(displays), observations: displays))
        XCTAssertNil(cache.evidence)
        XCTAssertFalse(cache.pending)
    }
    func testCacheRejectsProfilerResultsIfTheDisplayChangedDuringTheRead() throws {
        var cache = NativeDisplayProbeCache()
        let generation = try XCTUnwrap(cache.begin(observations: [screen()], power: .ac, fullWake: true))
        XCTAssertFalse(cache.complete(generation: generation, report: try report([screen()]), observations: [screen(model: 457)]))
        XCTAssertNil(cache.evidence)
        XCTAssertFalse(cache.pending)
        XCTAssertNotNil(cache.begin(observations: [screen(model: 457)], power: .ac, fullWake: true))
    }
    func testCacheDoesNotRepeatFailedProfileQueriesOnTimerTicks() throws {
        var cache = NativeDisplayProbeCache()
        let displays = [screen()]
        let generation = try XCTUnwrap(cache.begin(observations: displays, power: .ac, fullWake: true))
        XCTAssertNil(cache.begin(observations: displays, power: .ac, fullWake: true))
        XCTAssertTrue(cache.complete(generation: generation,
            report: DisplayProbe.resolve(observations: displays, profile: nil), observations: displays))
        XCTAssertNil(cache.evidence)
        XCTAssertNil(cache.begin(observations: displays, power: .ac, fullWake: true))
        cache.invalidate()
        XCTAssertNotNil(cache.begin(observations: displays, power: .ac, fullWake: true))
    }
    func testCacheDoesNotProfileVirtualOnlyBatteryOrDarkWake() {
        var cache = NativeDisplayProbeCache()
        XCTAssertNil(cache.begin(observations: [screen(vendor: 0xeee0, model: 0xeee1)], power: .ac, fullWake: true))
        XCTAssertNil(cache.begin(observations: [screen()], power: .battery, fullWake: true))
        XCTAssertNil(cache.begin(observations: [screen()], power: .ac, fullWake: false))
        XCTAssertFalse(cache.pending)
    }
    func testCacheDoesNotLoopWhenProfilerSideGraphicsCaptureIsUnavailable() throws {
        var cache = NativeDisplayProbeCache()
        let displays = [screen()]
        let generation = try XCTUnwrap(cache.begin(observations: displays, power: .ac, fullWake: true))
        XCTAssertFalse(cache.complete(generation: generation,
            report: DisplayProbe.resolve(observations: nil, profile: nil), observations: displays))
        XCTAssertNil(cache.evidence); XCTAssertFalse(cache.pending)
        XCTAssertNil(cache.begin(observations: displays, power: .ac, fullWake: true))
    }
    func testHandoffNeverTrialReleasesAClosedOrUnownedHold() {
        var gate = NativeClamshellHandoffGate()
        var s = Snapshot(power: .ac, lidClosed: true, sleepDisabled: true, externalDisplay: true)
        s.nativeDisplayCandidate = true
        XCTAssertFalse(gate.begin(snapshot: s, allowed: true, ownsOverride: true))
        s.lidClosed = false
        XCTAssertFalse(gate.begin(snapshot: s, allowed: true, ownsOverride: false))
        XCTAssertFalse(gate.begin(snapshot: s, allowed: false, ownsOverride: true))
        XCTAssertTrue(gate.begin(snapshot: s, allowed: true, ownsOverride: true))
        XCTAssertFalse(gate.begin(snapshot: s, allowed: true, ownsOverride: true))
        s.lidClosed = true
        XCTAssertFalse(gate.begin(snapshot: s, allowed: true, ownsOverride: true))
        s.lidClosed = false
        XCTAssertTrue(gate.begin(snapshot: s, allowed: true, ownsOverride: true))
    }
    func testPolicyDefersOnlyNewAcquisitionForTheBoundedNativeProbe() {
        var s = Snapshot(power: .ac, lidClosed: true, sleepDisabled: false, externalDisplay: true)
        s.nativeDisplayProbePending = true
        XCTAssertFalse(Policy.wantsClamshell(s, enabled: true, sleepNowPending: false, ownsOverride: false))
        XCTAssertEqual(Policy.actions(for: s, triggers: [.display], enabled: true,
            sleepNowPending: false, ownsOverride: false), [])
        s.sleepDisabled = true
        XCTAssertEqual(Policy.actions(for: s, triggers: [.display], enabled: true,
            sleepNowPending: false, ownsOverride: true), [])
        s.sleepDisabled = false
        s.nativeDisplayProbePending = false
        XCTAssertEqual(Policy.actions(for: s, triggers: [.display], enabled: true,
            sleepNowPending: false, ownsOverride: false), [.setSleepDisabled(true)])
    }
}
