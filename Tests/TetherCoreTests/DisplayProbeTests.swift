import XCTest
@testable import TetherCore

final class DisplayProbeTests: XCTestCase {
    private func screen(_ id: UInt32 = 15, builtIn: Bool = false, vendor: UInt32 = 0xeee0, model: UInt32 = 0xeee1) -> DisplayObservation {
        .init(id: id, builtIn: builtIn, vendor: vendor, model: model, width: 2560, height: 1440, active: true, asleep: false)
    }
    private func data(name: String = "Splashtop Display 1", id: String = "f", vendor: String = "eee0", model: String = "eee1", connection: String? = nil) throws -> Data {
        var row = ["_name": name, "_spdisplays_displayID": id, "_spdisplays_display-vendor-id": vendor, "_spdisplays_display-product-id": model]
        row["spdisplays_connection_type"] = connection
        return try JSONSerialization.data(withJSONObject: ["SPDisplaysDataType": [["spdisplays_ndrvs": [row]]]])
    }
    func testRealSplashtopProfileMatchesAllIdentifiers() throws {
        let report = DisplayProbe.resolve(observations: [screen()], profile: try data())
        XCTAssertEqual(report.virtualCount, 1)
        XCTAssertEqual(report.displays[0].name, "Splashtop Display 1")
        XCTAssertTrue(report.displays[0].profileMatched)
        XCTAssertEqual(report.displays[0].provider, "Splashtop")
        XCTAssertNil(report.issue)
    }
    func testDigitOnlySystemProfileIDIsHexadecimal() throws {
        let report = DisplayProbe.resolve(observations: [screen(16, model: 0xeee2)], profile: try data(id: "10", model: "eee2"))
        XCTAssertTrue(report.displays[0].profileMatched)
    }
    func testUnknownVendorIsNotGuessedVirtualFromAppName() throws {
        let report = DisplayProbe.resolve(observations: [screen(vendor: 123, model: 456)], profile: try data(vendor: "7b", model: "1c8"))
        XCTAssertEqual(report.displays[0].kind, .connected)
        XCTAssertNil(report.displays[0].provider)
    }
    func testDisplayLinkUSBIsNotClassifiedVirtual() throws {
        let report = DisplayProbe.resolve(observations: [screen(vendor: 123, model: 456)], profile: try data(name: "DisplayLink monitor", vendor: "7b", model: "1c8", connection: "spdisplays_usb"))
        XCTAssertEqual(report.displays[0].kind, .usb)
        XCTAssertEqual(report.virtualCount, 0)
    }
    func testWiredAndWirelessTransportsUseReportedEvidence() throws {
        for (transport, kind) in [("spdisplays_hdmi", DisplayFinding.Kind.wired), ("spdisplays_displayport", .wired), ("spdisplays_airplay", .wireless), ("spdisplays_sidecar", .wireless)] {
            let report = DisplayProbe.resolve(observations: [screen(vendor: 123, model: 456)], profile: try data(vendor: "7b", model: "1c8", connection: transport))
            XCTAssertEqual(report.displays[0].kind, kind)
        }
    }
    func testStaleProfileOrReusedIDDoesNotAttachWrongName() throws {
        for profile in [try data(id: "e"), try data(vendor: "610"), try data(model: "a05c")] {
            let report = DisplayProbe.resolve(observations: [screen()], profile: profile)
            XCTAssertFalse(report.displays[0].profileMatched)
            XCTAssertNotEqual(report.displays[0].name, "Splashtop Display 1")
            XCTAssertNotNil(report.issue)
        }
    }
    func testMalformedProfilePreservesLiveObservation() {
        let report = DisplayProbe.resolve(observations: [screen()], profile: Data("invalid".utf8))
        XCTAssertTrue(report.graphicsAvailable)
        XCTAssertEqual(report.virtualCount, 1)
        XCTAssertFalse(report.displays[0].profileMatched)
        XCTAssertNotNil(report.issue)
    }
    func testReadFailureKeepsSpecificReasonAndFastEvidence() {
        let report = DisplayProbe.resolve(observations: [screen()], profile: nil, issue: "timed out")
        XCTAssertEqual(report.issue, "timed out")
        XCTAssertEqual(report.displays.count, 1)
    }
    func testMissingCoreGraphicsNeverUsesPossiblyStaleProfileAlone() throws {
        let report = DisplayProbe.resolve(observations: nil, profile: try data())
        XCTAssertFalse(report.graphicsAvailable)
        XCTAssertTrue(report.displays.isEmpty)
        XCTAssertEqual(DisplayProbe.topology(nil), .unknown)
    }
    func testSuccessfulEmptyListIsDistinctFromUnavailableObservation() {
        let empty = DisplayProbe.resolve(observations: [], profile: nil)
        let unavailable = DisplayProbe.resolve(observations: nil, profile: nil)
        XCTAssertTrue(empty.graphicsAvailable)
        XCTAssertTrue(empty.displays.isEmpty)
        XCTAssertNil(empty.issue)
        XCTAssertFalse(unavailable.graphicsAvailable)
        XCTAssertNotEqual(empty.summary, unavailable.summary)
        XCTAssertNotEqual(empty.guidance, unavailable.guidance)
        XCTAssertEqual(DisplayProbe.topology([]), .none)
        XCTAssertEqual(DisplayProbe.topology(nil), .unknown)
    }
    func testEmptyListCannotClaimBuiltInPanelOrNativeClamshell() {
        let empty = DisplayProbe.resolve(observations: [], profile: nil)
        XCTAssertNotEqual(empty.summary,
            L("Only the built-in display is connected", "내장 화면만 연결되어 있습니다"))
        XCTAssertNil(NativeDisplayEvidence(report: empty))
        var probe = NativeDisplayProbeCache()
        XCTAssertNil(probe.begin(observations: [], power: .ac, fullWake: true))
        XCTAssertFalse(probe.pending)
    }
    func testDisplayReadFailureDoesNotClaimGeneralWorkIsBlocked() {
        let unavailable = DisplayProbe.resolve(observations: nil, profile: nil)
        XCTAssertFalse(unavailable.guidance.contains("Tether will not add a hold"))
        XCTAssertFalse(unavailable.guidance.contains("추가 유지는 적용하지 않습니다"))
    }
    func testTopologySeparatesVirtualFromOtherAdditionalScreens() {
        let builtIn = screen(1, builtIn: true, vendor: 0x610, model: 1)
        XCTAssertEqual(DisplayProbe.topology([builtIn]), .none)
        XCTAssertEqual(DisplayProbe.topology([builtIn, screen()]), .virtualOnly)
        XCTAssertEqual(DisplayProbe.topology([builtIn, screen(), screen(42, vendor: 123)]), .externalWithVirtual)
        XCTAssertEqual(DisplayProbe.topology([builtIn, screen(42, vendor: 123)]), .externalUnverified)
    }
    func testVirtualOnlyIsNotClaimedAsNativeClamshellAndRetainsTetherHold() {
        var snapshot = Snapshot(power: .ac, lidClosed: true, sleepDisabled: false, externalDisplay: true)
        snapshot.displayTopology = .virtualOnly
        XCTAssertFalse(snapshot.usesNativeClamshell)
        XCTAssertFalse(snapshot.defersToDisplaySetup)
        XCTAssertTrue(Policy.wantsClamshell(snapshot, enabled: true, sleepNowPending: false))
        XCTAssertEqual(Policy.actions(for: snapshot, triggers: [.display], enabled: true, sleepNowPending: false, ownsOverride: false), [.setSleepDisabled(true)])
    }
    func testVirtualDisplayGuidancePreservesRemoteRenderingAndSeparatesItsEvidence() {
        let report = DisplayProbe.resolve(observations: [screen()], profile: nil)
        XCTAssertTrue(report.guidance.contains(L("may be needed for remote rendering", "원격 화면에 필요할 수")))
        XCTAssertTrue(report.guidance.contains(L("withholds all-display sleep", "전체 화면 절전 명령을 보류")))
        XCTAssertTrue(report.guidance.contains(L("built-in display separately", "내장 화면 상태를 별도로")))
        XCTAssertTrue(report.guidance.contains(L("does not confirm remote frames, input or lock state", "원격 화면·입력과 잠금 상태가 확인된 것은 아닙니다")))
        XCTAssertFalse(report.guidance.contains(L("Review the named app's virtual-display settings", "필요하지 않다면")))
    }
    func testNamesAreBoundedAndControlCharactersStripped() throws {
        let report = DisplayProbe.resolve(observations: [screen()], profile: try data(name: "Monitor\n" + String(repeating: "x", count: 300)))
        XCTAssertLessThanOrEqual(report.displays[0].name.count, 120)
        XCTAssertFalse(report.displays[0].name.contains("\n"))
    }
    func testReportRoundTripDoesNotRetainSerialOrEDID() throws {
        var raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data()) as? [String: Any])
        raw["serial"] = "sensitive-fixture"; raw["edid"] = "fixture-only"
        let report = DisplayProbe.resolve(observations: [screen()], profile: try JSONSerialization.data(withJSONObject: raw))
        let encoded = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(DisplayReport.self, from: encoded), report)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("sensitive-fixture"))
    }
}
