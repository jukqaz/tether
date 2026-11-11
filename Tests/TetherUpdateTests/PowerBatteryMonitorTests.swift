import XCTest
import TetherCore
@testable import Tether

@MainActor
final class PowerBatteryMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func value(at date: Date, current: Double = 2_240) -> PowerBatteryReading {
        .init(observedAt: date, source: .ac, externalConnected: true, isCharging: current > 0,
              voltageMV: 12_500, currentMA: current, adapterReportedWatts: 94)
    }

    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Read-only monitor did not settle", file: file, line: line)
    }

    func testHiddenPanelDoesNotReadAndTwoPanelsShareOneQuery() async {
        var reads = 0
        let reading = value(at: now)
        let monitor = PowerBatteryMonitor(simulated: false, observesSystem: false,
            reader: { reads += 1; return reading }, clock: { self.now })
        monitor.refresh(); monitor.didWake()
        await Task.yield()
        XCTAssertEqual(reads, 0)
        let a = UUID(), b = UUID()
        monitor.setVisible(true, client: a); monitor.setVisible(true, client: a)
        monitor.setVisible(true, client: b)
        await settle { monitor.phase == .fresh }
        XCTAssertEqual(reads, 1); XCTAssertEqual(monitor.activeClientCount, 2)
        monitor.setVisible(false, client: a)
        XCTAssertTrue(monitor.isVisible)
        monitor.setVisible(false, client: b)
        XCTAssertFalse(monitor.isVisible); XCTAssertEqual(monitor.phase, .pending)
        monitor.refresh(); await Task.yield()
        XCTAssertEqual(reads, 1)
        monitor.setVisible(true, client: a)
        await settle { monitor.phase == .fresh }
        XCTAssertEqual(reads, 2, "Reopening must sample again, never reuse the old reading")
        monitor.setVisible(false, client: a)
    }

    func testLateQueryCannotPublishAfterPanelCloses() async {
        let source = DeferredPowerReader()
        let monitor = PowerBatteryMonitor(simulated: false, observesSystem: false,
            reader: { await source.read() }, clock: { self.now })
        let client = UUID()
        monitor.setVisible(true, client: client)
        await settle { source.count == 1 }
        monitor.setVisible(false, client: client)
        source.complete(value(at: now))
        await Task.yield(); await Task.yield()
        XCTAssertNil(monitor.reading); XCTAssertEqual(monitor.phase, .pending)
        XCTAssertFalse(monitor.isVisible)
    }

    func testPowerInvalidationRejectsInFlightResultAndCoalescesRefreshes() async {
        let source = DeferredPowerReader()
        let monitor = PowerBatteryMonitor(simulated: false, observesSystem: false,
            reader: { await source.read() }, clock: { self.now })
        let client = UUID(); monitor.setVisible(true, client: client)
        await settle { source.count == 1 }
        monitor.refresh(invalidate: true); monitor.refresh(invalidate: true)
        XCTAssertEqual(source.count, 1, "Power callbacks must not multiply outstanding IOKit reads")
        source.complete(value(at: now, current: 9_000))
        await settle { source.count == 2 }
        XCTAssertEqual(monitor.phase, .pending); XCTAssertNil(monitor.reading)
        source.complete(value(at: now, current: -500))
        await settle { monitor.phase == .fresh }
        XCTAssertEqual(monitor.reading?.currentMA, -500)
        monitor.setVisible(false, client: client)
    }

    func testSleepAndWakeNeverRestoreThePreSleepReading() async {
        let source = DeferredPowerReader()
        let monitor = PowerBatteryMonitor(simulated: false, observesSystem: false,
            reader: { await source.read() }, clock: { self.now })
        let client = UUID(); monitor.setVisible(true, client: client)
        await settle { source.count == 1 }
        monitor.willSleep(); monitor.refresh()
        XCTAssertEqual(source.count, 1)
        source.complete(value(at: now, current: 9_000))
        await settle { monitor.refreshCount == 1 && source.pending == 0 }
        monitor.didWake()
        await settle { source.count == 2 }
        XCTAssertEqual(monitor.phase, .pending)
        source.complete(value(at: now, current: 0))
        await settle { monitor.phase == .fresh }
        XCTAssertEqual(monitor.reading?.netWatts, 0)
        monitor.setVisible(false, client: client)
    }

    func testStaleFutureAndFailedReadDoNotRemainFresh() async {
        var clock = now
        var next: PowerBatteryReading? = value(at: now)
        let monitor = PowerBatteryMonitor(simulated: false, observesSystem: false,
            reader: { next }, clock: { clock })
        let client = UUID(); monitor.setVisible(true, client: client)
        await settle { monitor.phase == .fresh }
        clock = now.addingTimeInterval(10); monitor.reevaluate()
        XCTAssertEqual(monitor.phase, .fresh)
        clock = now.addingTimeInterval(10.001); monitor.reevaluate()
        XCTAssertEqual(monitor.phase, .stale)
        next = value(at: now.addingTimeInterval(60)); monitor.refresh(invalidate: true)
        await settle { monitor.phase == .unavailable }
        next = nil; monitor.refresh(invalidate: true)
        await settle { monitor.phase == .unavailable && monitor.reading == nil }
        monitor.setVisible(false, client: client)
    }

    func testFixtureNeverCollectsEvenWhenVisibleOrAfterPowerAndWakeEvents() async {
        var reads = 0
        let monitor = PowerBatteryMonitor(simulated: true, reader: { reads += 1; return nil })
        monitor.setFixture(reading: value(at: now), evaluatedAt: now)
        let client = UUID(); monitor.setVisible(true, client: client)
        monitor.refresh(invalidate: true); monitor.willSleep(); monitor.didWake()
        await Task.yield()
        XCTAssertEqual(reads, 0); XCTAssertEqual(monitor.phase, .fresh)
        monitor.setVisible(false, client: client)
        let live = PowerBatteryMonitor(simulated: false, observesSystem: false)
        live.setFixture(reading: value(at: now))
        XCTAssertNil(live.reading, "A fixture override cannot enter the normal monitor")
    }

    func testPowerDetailsCannotChangeCurrentWorkOrApprovedSettings() throws {
        let model = DesignPreviewState().model
        let work = try XCTUnwrap(model.userSession)
        defer { _ = work.end() }
        let request = work.manualRequestID, deadline = work.status.manualContinuousDeadline
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let settings = try encoder.encode(model.v3Settings)
        let client = UUID()
        defer { model.powerBattery.setVisible(false, client: client) }
        for scenario in PowerBatterySample.cases {
            PowerBatterySample.configure(model.powerBattery, scenario: scenario, now: now)
            model.powerBattery.setVisible(true, client: client)
            XCTAssertEqual(work.manualRequestID, request)
            XCTAssertEqual(work.status.manualContinuousDeadline, deadline)
            XCTAssertTrue(model.workSessionHolding)
            XCTAssertEqual(try encoder.encode(model.v3Settings), settings)
        }
    }
}

@MainActor
private final class DeferredPowerReader {
    private var continuations: [CheckedContinuation<PowerBatteryReading?, Never>] = []
    private(set) var count = 0
    var pending: Int { continuations.count }
    func read() async -> PowerBatteryReading? {
        count += 1
        return await withCheckedContinuation { continuations.append($0) }
    }
    func complete(_ value: PowerBatteryReading?) { continuations.removeFirst().resume(returning: value) }
}
