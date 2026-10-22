import XCTest
@testable import TetherCore

final class StatusTests: XCTestCase {
    /// A 1.0 helper wrote "displayOff", which 1.1 no longer has; the status must still decode.
    func testUnknownEventFromAnotherVersionStillDecodes() throws {
        let json = """
        {"enabled":true,"lastEvent":"displayOff","lastEventAt":1790358175.4,"lidClosed":false,
         "power":"ac","sleepDisabled":true,"updatedAt":1790358371.8,"version":"1.0.0"}
        """
        let status = try JSONDecoder().decode(Status.self, from: Data(json.utf8))
        XCTAssertEqual(status.version, "1.0.0")
        XCTAssertTrue(status.sleepDisabled)
        XCTAssertNil(status.lastEvent)
    }

    /// A 1.6 status read by a build that knows the new fields, and one written before them.
    func testNewFieldsAreOptional() throws {
        let old = """
        {"enabled":true,"lidClosed":true,"power":"ac","sleepDisabled":true,"updatedAt":1,"version":"1.4.0",
         "lastEvent":"heatGuardOn"}
        """
        let decodedOld = try JSONDecoder().decode(Status.self, from: Data(old.utf8))
        XCTAssertNil(decodedOld.heatGuard)
        XCTAssertNil(decodedOld.displayRecovery)
        XCTAssertEqual(decodedOld.lastEvent, .heatGuardOn)

        var status = Status(updatedAt: 1, version: TetherPaths.version, enabled: true, power: .ac,
                            lidClosed: true, sleepDisabled: true, lastEvent: .heatCritical, lastEventAt: 2)
        status.heatGuard = true
        status.displayRecovery = DisplayRecoveryStatus(phase: .recovering, requests: 2)
        status.thermalAlertAt = 3
        status.batteryHoldSince = 4
        let decoded = try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded, status)
    }

    func testLowPowerModeIsReadPerPowerSource() {
        let output = """
        Battery Power:
         Sleep On Power Button 1
         lowpowermode         1
         displaysleep         2
        AC Power:
         Sleep On Power Button 1
         lowpowermode         0
         displaysleep         10
        """
        XCTAssertEqual(SystemProbe.lowPowerMode(in: output, section: "Battery Power"), 1)
        XCTAssertEqual(SystemProbe.lowPowerMode(in: output, section: "AC Power"), 0)
        XCTAssertNil(SystemProbe.lowPowerMode(in: "AC Power:\n displaysleep 10\n", section: "AC Power"))
    }

    func testRoundTrip() throws {
        let status = Status(updatedAt: 1, version: TetherPaths.version, enabled: true, power: .battery,
                            lidClosed: true, sleepDisabled: false, lastEvent: .lidSleep, lastEventAt: 2)
        let decoded = try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded, status)
    }
}

final class DateTextTests: XCTestCase {
    private let saved = Localization.current
    override func tearDown() { Localization.current = saved }

    /// Dates follow Tether's language, not the Mac's, so English never shows "9월".
    func testDatesFollowTheAppLanguage() {
        let date = Date(timeIntervalSince1970: 1_790_395_200)  // late September 2026
        Localization.current = .english
        XCTAssertTrue(Texts.dateTime(date).contains("Sep"), Texts.dateTime(date))
        Localization.current = .korean
        XCTAssertTrue(Texts.dateTime(date).contains("9월"), Texts.dateTime(date))
        XCTAssertFalse(Texts.time(date).isEmpty)
    }
}
