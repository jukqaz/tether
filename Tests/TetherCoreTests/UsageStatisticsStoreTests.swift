import XCTest
@testable import TetherCore

final class UsageStatisticsStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    private func observe(_ store: UsageStatisticsStore, after seconds: Double = 0,
                         lid: Bool? = true, clamshell: Bool = true, holding: Bool = true,
                         battery: Bool = true, protection: String? = nil) {
        store.observe(now: t0.addingTimeInterval(seconds), lidClosed: lid,
                      clamshellConfirmed: clamshell, holding: holding,
                      onBattery: battery, protectionReason: protection)
    }

    @MainActor
    func testCountsOnlyConfirmedClosedAndBatteryHoldingIntervals() {
        let store = UsageStatisticsStore()
        observe(store)
        observe(store, after: 30)
        observe(store, after: 60, lid: false, battery: false)
        observe(store, after: 90, lid: false, battery: false)
        XCTAssertEqual(store.stats.days.reduce(0) { $0 + $1.lidClosedSeconds }, 60)
        XCTAssertEqual(store.stats.days.reduce(0) { $0 + ($1.holdSeconds ?? 0) }, 60)
    }

    @MainActor
    func testUnknownLidAndUnconfirmedWorkCannotCreditClosedDuration() {
        let store = UsageStatisticsStore()
        observe(store)
        observe(store, after: 30, lid: nil)
        observe(store, after: 60, clamshell: false, holding: false)
        observe(store, after: 90, clamshell: false, holding: false)
        XCTAssertEqual(store.stats.days.reduce(0) { $0 + $1.lidClosedSeconds }, 0)
        XCTAssertEqual(store.stats.days.reduce(0) { $0 + ($1.holdSeconds ?? 0) }, 60)
    }

    @MainActor
    func testLongGapAndBackwardsClockDoNotFillMissingTime() {
        let store = UsageStatisticsStore()
        observe(store)
        observe(store, after: 30)
        observe(store, after: 3_600)
        observe(store, after: 3_590)
        observe(store, after: 3_620)
        XCTAssertEqual(store.stats.days.reduce(0) { $0 + $1.lidClosedSeconds }, 60)
        XCTAssertEqual(store.stats.days.reduce(0) { $0 + ($1.holdSeconds ?? 0) }, 60)
    }

    @MainActor
    func testThermalProtectionCountsOnceUntilRecoveryAndIgnoresOtherReasons() {
        let store = UsageStatisticsStore()
        observe(store, holding: false, protection: "thermal")
        observe(store, after: 10, holding: false, protection: "thermal")
        observe(store, after: 20, holding: false, protection: "battery")
        observe(store, after: 30, holding: false, protection: "thermal")
        XCTAssertEqual(store.stats.days.reduce(0) { $0 + $1.heatGuards }, 1)
        observe(store, after: 40, holding: false)
        observe(store, after: 50, holding: false, protection: "battery")
        observe(store, after: 60, holding: false, protection: "thermal")
        XCTAssertEqual(store.stats.days.reduce(0) { $0 + $1.heatGuards }, 2)
    }

    @MainActor
    func testPersistenceRestoresTotalsWithoutSamplingOrRestartDoubleCount() throws {
        let suite = "tether-usage-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = UsageStatisticsStore(defaults: defaults)
        observe(original)
        observe(original, after: 30, protection: "thermal")
        original.flush()
        let encoded = try XCTUnwrap(defaults.data(forKey: UsageStatisticsStore.storageKey))
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("lastTick"))
        XCTAssertFalse(text.contains("lastSample"))
        let restored = UsageStatisticsStore(defaults: defaults)
        XCTAssertNil(restored.stats.lastTick)
        XCTAssertNil(restored.stats.lastSample)
        observe(restored, after: 3_600, protection: "thermal")
        XCTAssertEqual(restored.stats.days.reduce(0) { $0 + $1.lidClosedSeconds }, 30)
        XCTAssertEqual(restored.stats.days.reduce(0) { $0 + $1.heatGuards }, 1)
    }

    @MainActor
    func testRetainsOnlySevenDaySummariesInOneBoundedRecord() throws {
        let suite = "tether-usage-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStatisticsStore(defaults: defaults)
        for day in 0..<10 {
            observe(store, after: Double(day) * 86_400)
            observe(store, after: Double(day) * 86_400 + 30)
        }
        store.flush()
        XCTAssertEqual(store.stats.days.count, 7)
        XCTAssertEqual(store.stats.days.reduce(0) { $0 + $1.lidClosedSeconds }, 210)
        XCTAssertLessThan(try XCTUnwrap(defaults.data(forKey: UsageStatisticsStore.storageKey)).count, 32_768)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?.keys.sorted(), [UsageStatisticsStore.storageKey])
    }

    @MainActor
    func testCorruptRecordIsPreservedWhileMemoryStatisticsContinue() throws {
        let suite = "tether-usage-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("not valid statistics".utf8)
        defaults.set(corrupt, forKey: UsageStatisticsStore.storageKey)
        let store = UsageStatisticsStore(defaults: defaults)
        observe(store)
        observe(store, after: 30)
        store.flush()
        XCTAssertEqual(store.issue, "stored-statistics-unreadable")
        XCTAssertEqual(defaults.data(forKey: UsageStatisticsStore.storageKey), corrupt)
        XCTAssertEqual(store.stats.days.reduce(0) { $0 + $1.lidClosedSeconds }, 30)
    }

    @MainActor
    func testWriteFailureDoesNotDiscardCollectedStatisticsOrThrow() throws {
        let suite = "tether-usage-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(RejectingStatisticsDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStatisticsStore(defaults: defaults)
        observe(store)
        observe(store, after: 30)
        store.flush()
        XCTAssertEqual(store.issue, "statistics-save-failed")
        XCTAssertEqual(store.stats.days.reduce(0) { $0 + ($1.holdSeconds ?? 0) }, 30)
        XCTAssertNil(defaults.data(forKey: UsageStatisticsStore.storageKey))
    }
}

private final class RejectingStatisticsDefaults: UserDefaults {
    override func set(_ value: Any?, forKey defaultName: String) {}
}
