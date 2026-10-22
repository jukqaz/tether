import XCTest
@testable import TetherCore

final class PowerInfluenceTests: XCTestCase {
    func testSavedTimeoutsAreIndependentForACAndBattery() {
        let value = PowerSleepPreferences.decode(result("""
        Battery Power:
         sleep 1
         displaysleep 2
         ttyskeepawake 1
         womp 0
        AC Power:
         sleep 0
         displaysleep 10
         ttyskeepawake 1
         womp 1
        """))
        XCTAssertEqual(value.ac?.systemMinutes, 0)
        XCTAssertEqual(value.ac?.displayMinutes, 10)
        XCTAssertEqual(value.battery?.systemMinutes, 1)
        XCTAssertEqual(value.battery?.displayMinutes, 2)
        XCTAssertEqual(value.ac?.terminalKeepsAwake, true)
        XCTAssertNil(value.setting(for: .unknown), "Unknown power cannot inherit AC settings")
    }

    func testFailedTruncatedOrIncompleteCommandDoesNotMeanSleepDisabled() {
        let output = "AC Power:\n sleep 0\n displaysleep 10\n"
        for value in [result(output, status: 1), result(output, timedOut: true),
                      result(output, terminationConfirmed: false), result(String(repeating: " ", count: 65_536))] {
            XCTAssertNil(PowerSleepPreferences.decode(value).ac)
        }
        XCTAssertNil(PowerSleepPreferences.decode(result("AC Power:\n womp 1")).ac)
        let missingSystem = PowerSleepPreferences.decode(result("AC Power:\n displaysleep 10"))
        XCTAssertNil(missingSystem.ac?.systemMinutes)
        XCTAssertEqual(missingSystem.ac?.displayMinutes, 10)
    }

    func testAmbiguousAndInvalidTimeoutsCannotBecomeAConfirmedZero() {
        for output in ["AC Power:\n sleep 0\n sleep 10", "AC Power:\n sleep 1\nAC Power:\n sleep 0",
                       "AC Power:\n sleep 0 extra"] {
            XCTAssertNil(PowerSleepPreferences.decode(result(output)).ac)
        }
        for invalid in ["-1", "false", "1.5", "2147483648", "０", "nan"] {
            let value = PowerSleepPreferences.decode(result("AC Power:\n sleep \(invalid)\n displaysleep 10"))
            XCTAssertNil(value.ac?.systemMinutes)
            XCTAssertEqual(value.ac?.displayMinutes, 10)
        }
    }

    func testInputAndInternalDisplayDelayCannotBecomeLidSleepAuthority() {
        let observed: PowerAssertionSnapshot.ByProcess = [621: [["AssertType": "UserIsActive", "AssertLevel": 255,
            "Process Name": "WindowServer", "AssertName": "com.apple.iohideventsystem.queue.tickle.nxevent service:IOHIDSystem pid:78429 process:SkyComputerUseService"]],
            565: [["AssertType": "InternalPreventDisplaySleep", "AssertLevel": 255,
                   "Process Name": "powerd", "AssertName": "private title"]]]
        let signals = SystemProbe.decodeActivitySignals(observed, excluding: [])
        XCTAssertEqual(signals.count, 2)
        XCTAssertEqual(signals.first { $0.pid == 621 }?.sourcePID, 78429)
        XCTAssertEqual(signals.first { $0.pid == 565 }?.kind, .displayDelay)
        XCTAssertTrue(SystemProbe.decodeSleepBlockers(observed, excluding: [], closedLidSleepOnly: false).isEmpty)
        XCTAssertTrue(SystemProbe.decodeSleepBlockers(observed, excluding: [], closedLidSleepOnly: true).isEmpty)
        XCTAssertFalse(String(describing: signals).contains("private title"))
        XCTAssertFalse(String(describing: signals).contains("SkyComputerUseService"))
        XCTAssertEqual(SystemProbe.decodeActivitySignals(observed, excluding: [621]).count, 1)
    }

    func testUnknownInputPayloadDoesNotGuessTheSourceOrExposeIt() {
        let record = "com.apple.iohideventsystem.queue.tickle.nxevent service:IOHIDSystem pid:22 process:Worker"
        XCTAssertEqual(PowerActivitySignal.inputSourcePID(owner: "WindowServer", name: record), 22)
        XCTAssertNil(PowerActivitySignal.inputSourcePID(owner: "UntrustedApp", name: record))
        for malformed in [record + " pid:23", record.replacingOccurrences(of: "pid:22", with: "pid:-22"),
                          record.replacingOccurrences(of: "pid:22", with: "pid:2147483648"),
                          record.replacingOccurrences(of: "pid:22", with: "pid:0"),
                          "Private document pid:22", String(repeating: "x", count: 513)] {
            XCTAssertNil(PowerActivitySignal.inputSourcePID(owner: "WindowServer", name: malformed))
        }
    }

    func testOnlySafeExactCaptureAndVideoCategoriesSurviveRequestProjection() {
        let observed: PowerAssertionSnapshot.ByProcess = [10: [
            ["AssertType": "NoDisplaySleepAssertion", "AssertLevel": 255, "Process Name": "Browser", "AssertName": "Capturing"],
            ["AssertType": "NoDisplaySleepAssertion", "AssertLevel": 255, "Process Name": "Browser", "AssertName": "Video Wake Lock"],
            ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255, "Process Name": "Browser", "AssertName": "Capturing private conversation"]]]
        let findings = PowerActivityPolicy.requests(SystemProbe.decodeSleepBlockers(observed,
            excluding: [], closedLidSleepOnly: false), displaySleepExpected: false)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].purposes, [.screenCapture, .videoPlayback])
        XCTAssertFalse(findings[0].opposesDisplaySleep)
        XCTAssertFalse(String(describing: findings).contains("private conversation"))
        XCTAssertNil(PowerRequestPurpose(assertionName: "Capturing private conversation"))
    }

    func testReportSeparatesUnavailableFromZeroAndRespectsNameOptIn() {
        let preferences = PowerSleepPreferences(ac: .init(systemMinutes: 0, displayMinutes: 10))
        let signals: [PowerActivitySignal] = [.init(pid: 1, process: "PrivateApp", kind: .userActivity, sourcePID: 2)]
        let privateReport = Diagnostics.powerInfluenceSummary(preferences: preferences, signals: signals, includeProcessNames: false)
        XCTAssertTrue(privateReport.contains("idle system sleep disabled (0)"))
        XCTAssertTrue(privateReport.contains("Battery: idle system sleep unavailable"))
        XCTAssertTrue(privateReport.contains("OS input-process hint pid 2"))
        XCTAssertFalse(privateReport.contains("PrivateApp"))
        XCTAssertTrue(Diagnostics.powerInfluenceSummary(preferences: preferences, signals: signals, includeProcessNames: true).contains("PrivateApp"))
        let missing = Diagnostics.powerInfluenceSummary(preferences: .init(), signals: nil, includeProcessNames: false)
        XCTAssertTrue(missing.contains("absence of input is not established"))
        XCTAssertFalse(missing.contains("disabled (0)"))
    }

    private func result(_ output: String, status: Int32 = 0, timedOut: Bool = false,
                        terminationConfirmed: Bool = true) -> Shell.Result {
        Shell.Result(status: status, output: output, timedOut: timedOut, processID: nil,
                     terminationConfirmed: terminationConfirmed, exitStatus: status)
    }
}
