import XCTest
@testable import TetherCore

final class ScreenLockPolicyProbeTests: XCTestCase {
    private func line(_ message: String) -> String {
        "2026-10-06 12:12:33.449 sysadminctl[34463:2098573] \(message)\n"
    }
    private func parse(_ output: String, status: Int32 = 0, timedOut: Bool = false,
                       confirmed: Bool = true) -> ScreenLockPolicy {
        ScreenLockPolicyProbe.parse(status: status, output: output, timedOut: timedOut,
                                    terminationConfirmed: confirmed)
    }

    func testExactKnownMessagesAfterLogPrefix() {
        // The off result is a known CLI fixture; these tests never change the Mac's policy.
        XCTAssertEqual(parse(line("screenLock is off")), .off)
        XCTAssertEqual(parse(line("screenLock delay is immediate")), .immediate)
        XCTAssertEqual(parse(line("screenLock delay is 300 seconds")), .after(seconds: 300))
        XCTAssertEqual(parse(line("screenLock delay is 0 seconds")), .after(seconds: 0))
        XCTAssertEqual(parse(line("screenLock delay is 86400 seconds")), .after(seconds: 86_400))
    }

    func testFailedTimedOutOrUnconfirmedReaderCannotReportOff() {
        let output = line("screenLock is off")
        for status in [Int32(-1), 1, 124] {
            XCTAssertEqual(parse(output, status: status), .unavailable)
        }
        XCTAssertEqual(parse(output, timedOut: true), .unavailable)
        XCTAssertEqual(parse(output, confirmed: false), .unavailable)
    }

    func testMissingUnknownDuplicateAndContradictoryMessagesAreUnavailable() {
        for output in ["", "\n\n", " ", line(""), line("screenLock status unknown"),
                       line("screenLock is off") + line("screenLock is off"),
                       line("screenLock is off") + line("screenLock delay is immediate"),
                       line("screenLock delay is immediate") + line("screenLock delay is 300 seconds"),
                       line("screenLock delay is 300 seconds") + line("screenLock delay is 300 seconds"),
                       line("screenLock is off") + line("Permission denied"),
                       "warning: incomplete read\n" + line("screenLock is off")] {
            XCTAssertEqual(parse(output), .unavailable, output)
        }
    }

    func testPolicyPayloadMustMatchExactly() {
        for message in ["screenLock is OFF", "screenLock is off ", "screenLock is off extra",
                        "screenLock delay is immediate extra", "screenLock delay is 300 seconds extra",
                        "screenLock delay is 300 second", "screenLock  delay is 300 seconds",
                        "screenLock delay is -1 seconds", "screenLock delay is +1 seconds",
                        "screenLock delay is 1.5 seconds", "screenLock delay is 1e3 seconds",
                        "screenLock delay is 0300 seconds", "screenLock delay is 1,000 seconds",
                        "screenLock delay is 86401 seconds", "screenLock delay is 2147483647 seconds",
                        "screenLock delay is 999999999999999999999999 seconds",
                        "screenLock delay is \u{0663}\u{0660}\u{0660} seconds",
                        "screenLock is off\0screenLock delay is immediate"] {
            XCTAssertEqual(parse(line(message)), .unavailable, message)
        }
    }

    func testOnlyTheSysadminctlLogPrefixCanIntroducePolicy() {
        for output in ["screenLock is off", "screenLock delay is immediate",
                       "sysadminctl[34463:2098573] screenLock is off",
                       "2026-10-06 12:12:33.449 anotherTool[34463:2098573] screenLock is off",
                       "2026-10-06 12:12:33.449 sysadminctl[34463] screenLock is off",
                       "2026-10-06 12:12:33.449 sysadminctl[pid:2098573] screenLock is off",
                       "2026-10-06 12:12:33.449 sysadminctl[34463:2098573] prefix screenLock is off"] {
            XCTAssertEqual(parse(output), .unavailable, output)
        }
    }

    func testSaturatedOutputCannotHideAdditionalPoliciesOrErrors() {
        let valid = line("screenLock is off")
        let padded = String(repeating: "\n", count: ScreenLockPolicyProbe.maximumOutputBytes - valid.utf8.count) + valid
        XCTAssertEqual(padded.utf8.count, ScreenLockPolicyProbe.maximumOutputBytes)
        XCTAssertEqual(parse(padded), .unavailable)
        XCTAssertEqual(parse(padded + "\n"), .unavailable)
    }
}
