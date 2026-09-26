import XCTest
@testable import TetherCore

final class SleepLogTests: XCTestCase {
    private let t0: Double = 1_800_000_000

    override func setUp() { Localization.current = .korean }
    override func tearDown() { Localization.current = .preferred }

    private func wake(_ log: inout SleepLog, after seconds: Double, full: Bool = true, justWoke: Bool = true,
                      percent: Int? = 77, onBattery: Bool = true, reason: String? = "Clamshell Sleep",
                      byTether: Bool = false, wakeReason: String? = "EC.LidOpen") -> SleepRecord? {
        log.awake(at: t0 + seconds, fullWake: full, justWoke: justWoke, percent: percent, onBattery: onBattery,
                  sleepReason: reason, requestedByTether: byTether, wakeType: "UserActivity Assertion",
                  wakeReason: wakeReason)
    }

    func testNightOnBattery() throws {
        var log = SleepLog()
        log.willSleep(at: t0, percent: 80, onBattery: true, byTether: false)
        let record = try XCTUnwrap(wake(&log, after: 8 * 3600, percent: 76))
        XCTAssertEqual(record.duration, 8 * 3600)
        XCTAssertEqual(record.drainPerHour!, 0.5, accuracy: 0.001)
        XCTAssertNil(log.open)
        XCTAssertEqual(log.recent.count, 1)
        XCTAssertEqual(Texts.sleepCause(record), "덮개 닫힘")
        XCTAssertEqual(Texts.wakeCause(record), "덮개 열림")
    }

    func testDarkWakesAreCountedNotSplit() throws {
        var log = SleepLog()
        log.willSleep(at: t0, percent: 80, onBattery: true, byTether: false)
        XCTAssertNil(wake(&log, after: 1800, full: false))
        XCTAssertNil(wake(&log, after: 1810, full: false, justWoke: false))  // later checks of the same dark wake
        log.willSleep(at: t0 + 1830, percent: 80, onBattery: true, byTether: false)  // back to sleep: same record
        let record = try XCTUnwrap(wake(&log, after: 3 * 3600, percent: 78))
        XCTAssertEqual(record.darkWakes, 1)
        XCTAssertEqual(record.sleptAt, t0)
    }

    /// Input during the pre-sleep window cancels the sleep a moment after "will sleep".
    func testCancelledSleepIsNotKept() {
        var log = SleepLog()
        log.willSleep(at: t0, percent: 80, onBattery: false, byTether: true)
        XCTAssertNil(wake(&log, after: 3))
        XCTAssertTrue(log.recent.isEmpty)
        XCTAssertNil(log.open)
    }

    func testDrainNeedsBatteryThroughoutAndTime() throws {
        var log = SleepLog()
        log.willSleep(at: t0, percent: 80, onBattery: false, byTether: false)
        XCTAssertNil(try XCTUnwrap(wake(&log, after: 3 * 3600, percent: 80, onBattery: false)).drainPerHour)
        log.willSleep(at: t0, percent: 80, onBattery: true, byTether: false)
        XCTAssertNil(try XCTUnwrap(wake(&log, after: 1200, percent: 79)).drainPerHour)  // too short
        log.willSleep(at: t0, percent: 60, onBattery: true, byTether: false)
        XCTAssertNil(try XCTUnwrap(wake(&log, after: 3 * 3600, percent: 90, onBattery: false)).drainPerHour)  // plugged in
    }

    func testTetherAsSleepCause() throws {
        var log = SleepLog()
        log.willSleep(at: t0, percent: 80, onBattery: true, byTether: true)
        let record = try XCTUnwrap(wake(&log, after: 3600, reason: "Software Sleep"))
        XCTAssertEqual(Texts.sleepCause(record), "Tether가 재움")

        log.willSleep(at: t0, percent: 80, onBattery: true, byTether: false)
        let byPID = try XCTUnwrap(wake(&log, after: 3600, reason: "Software Sleep", byTether: true))
        XCTAssertTrue(byPID.byTether)
    }

    func testAverageDrainIsWeightedByDuration() {
        var log = SleepLog()
        log.willSleep(at: t0, percent: 80, onBattery: true, byTether: false)
        _ = wake(&log, after: 8 * 3600, percent: 76)   // 4 points over 8 h
        log.willSleep(at: t0, percent: 70, onBattery: true, byTether: false)
        _ = wake(&log, after: 2 * 3600, percent: 64)   // 6 points over 2 h
        XCTAssertEqual(log.averageDrain!, 1.0, accuracy: 0.001)
    }

    func testKeepsTheLastTwenty() {
        var log = SleepLog()
        for i in 0..<25 {
            log.willSleep(at: t0 + Double(i) * 10_000, percent: 80, onBattery: false, byTether: false)
            _ = log.awake(at: t0 + Double(i) * 10_000 + 600, fullWake: true, justWoke: true, percent: 80,
                          onBattery: false, sleepReason: nil, requestedByTether: false, wakeType: nil, wakeReason: nil)
        }
        XCTAssertEqual(log.recent.count, SleepLog.keep)
        XCTAssertEqual(log.recent.first?.sleptAt, t0 + 5 * 10_000)
    }

    func testWakeCauses() {
        func cause(_ type: String?, _ reason: String?) -> String {
            var r = SleepRecord(sleptAt: 0, percentBefore: nil, onBatteryBefore: false)
            r.wakeType = type
            r.wakeReason = reason
            return Texts.wakeCause(r)
        }
        XCTAssertEqual(cause("UserActivity Assertion", nil), "키보드·트랙패드")
        XCTAssertEqual(cause(nil, "smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty"), "Wi-Fi·블루투스")
        XCTAssertEqual(cause("Maintenance", "RTC (Alarm)"), "예약된 시스템 작업")
        XCTAssertEqual(cause(nil, nil), "알 수 없음")
        XCTAssertEqual(Texts.drainLevel(0.6), "정상")
        XCTAssertEqual(Texts.drainLevel(2), "조금 높음")
        XCTAssertEqual(Texts.drainLevel(4.2), "높음")
    }

    /// usage.json from before the sleep log still loads.
    func testOlderUsageFileLoads() throws {
        let json = #"{"recentSessions":[],"stats":{"days":[]},"tracker":{}}"#
        let usage = try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
        XCTAssertNil(usage.sleepLog)
        XCTAssertTrue(usage.sleeps.recent.isEmpty)
    }
}
