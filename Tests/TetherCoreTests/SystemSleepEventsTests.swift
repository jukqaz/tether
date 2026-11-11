import XCTest
@testable import TetherCore

final class SystemSleepEventsTests: XCTestCase {
    private func instant(_ value: String) -> Double {
        ISO8601DateFormatter().date(from: value)!.timeIntervalSince1970
    }
    private var record: SleepRecord {
        var r = SleepRecord(sleptAt: instant("2026-09-29T12:04:36+09:00") + 0.24,
                            percentBefore: 80, onBatteryBefore: false)
        r.wokeAt = instant("2026-09-29T12:21:13+09:00") + 0.52
        return r
    }
    // Event times from the failed physical session. Reasons and process details are omitted.
    private let log = """
    2026-09-29 12:04:36 +0900 Sleep       Entering DarkWake state due to 'Software Sleep'
    2026-09-29 12:04:43 +0900 Sleep       Entering Sleep state due to 'Software Sleep'
    2026-09-29 12:05:40 +0900 DarkWake    DarkWake from Deep Idle
    2026-09-29 12:14:36 +0900 DarkWake    DarkWake from Deep Idle
    2026-09-29 12:15:14 +0900 DarkWake    DarkWake from Deep Idle
    2026-09-29 12:18:19 +0900 DarkWake    DarkWake from Deep Idle
    2026-09-29 12:18:39 +0900 DarkWake    DarkWake from Deep Idle
    2026-09-29 12:18:52 +0900 DarkWake    DarkWake from Deep Idle
    2026-09-29 12:19:09 +0900 DarkWake    DarkWake from Deep Idle
    2026-09-29 12:20:30 +0900 DarkWake    DarkWake from Deep Idle
    2026-09-29 12:21:13 +0900 Wake        Wake from Deep Idle
    """

    func testActualSessionTimelineCorrectsZeroToEight() {
        let events = SystemSleepEvents(log)
        XCTAssertEqual(events.darkWakeCount(for: record), 8)
        var history = SleepLog(recent: [record])
        XCTAssertEqual(history.reconcileDarkWakes(with: events), 1)
        XCTAssertEqual(history.recent[0].darkWakes, 8)
        XCTAssertEqual(history.recent[0].darkWakeCountVerified, true)
        XCTAssertEqual(history.reconcileDarkWakes(with: events), 0)
    }
    func testMissingCoverageOrWakeIsUnknownInsteadOfZero() {
        XCTAssertNil(SystemSleepEvents("").darkWakeCount(for: record))
        XCTAssertNil(SystemSleepEvents(log.components(separatedBy: "\n").dropFirst().joined(separator: "\n")).darkWakeCount(for: record))
        XCTAssertNil(SystemSleepEvents(log.components(separatedBy: "\n").dropLast().joined(separator: "\n")).darkWakeCount(for: record))
        XCTAssertNil(SystemSleepEvents(log.replacingOccurrences(of: "Wake from Deep Idle", with: "Requests pending")).darkWakeCount(for: record))
    }
    func testDuplicateRowsAndUnrelatedIntervalsDoNotInflateCount() {
        let unrelated = """
        2026-09-29 11:59:00 +0900 DarkWake DarkWake from Deep Idle
        2026-09-29 12:22:00 +0900 DarkWake DarkWake from Deep Idle
        2026-09-29 12:21:13 +0900 Wake Requests [scheduled events]
        """
        XCTAssertEqual(SystemSleepEvents(log + "\n" + log + "\n" + unrelated).darkWakeCount(for: record), 8)
    }
    func testCompleteIntervalWithNoDarkWakesCanVerifyZero() {
        let withoutDark = log.components(separatedBy: "\n").filter { !$0.contains("DarkWake    ") }.joined(separator: "\n")
        XCTAssertEqual(SystemSleepEvents(withoutDark).darkWakeCount(for: record), 0)
    }
    func testMultipleFullWakesAreAmbiguous() {
        let extra = "\n2026-09-29 12:15:20 +0900 Wake Wake from Deep Idle\n"
        XCTAssertNil(SystemSleepEvents(log + extra).darkWakeCount(for: record))
    }
    func testLegacyRecordDecodesWithoutInventingVerification() throws {
        let old = #"{"sleptAt":1,"wokeAt":100,"onBatteryBefore":false,"byTether":false,"darkWakes":0}"#
        let decoded = try JSONDecoder().decode(SleepRecord.self, from: Data(old.utf8))
        XCTAssertNil(decoded.darkWakeCountVerified)
        XCTAssertEqual(decoded.darkWakeSummary, "unverified (0 notifications)")
        var history = SleepLog(recent: [decoded])
        XCTAssertEqual(history.reconcileDarkWakes(with: SystemSleepEvents("")), 0)
        XCTAssertEqual(history.recent, [decoded])
    }
    func testTailCaptureRetainsNewestOutputAndStaysBounded() {
        let r = Shell.run("/usr/bin/printf", ["old-prefix-123456789-newest"], maxOutputBytes: 6, keepTail: true)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.output, "newest")
        let zero = Shell.run("/usr/bin/printf", ["ignored"], maxOutputBytes: 0, keepTail: true)
        XCTAssertEqual(zero.output, "")
    }

    func testLargePipeOutputCompletesWithinReadBudget() {
        // 32 MiB exceeds a pipe buffer many times. Sleeping after every EAGAIN
        // used up the real pmset read budget before reaching the newest events.
        let r = Shell.run("/bin/sh", ["-c", "/bin/dd if=/dev/zero bs=1024 count=32768 2>/dev/null; printf complete"],
                          timeout: 3, maxOutputBytes: 4096, keepTail: true)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.output.utf8.count, 4096)
        XCTAssertTrue(r.output.hasSuffix("complete"))
    }
}
