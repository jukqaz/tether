import XCTest
@testable import Tether

final class NotificationSettingsMonitorTests: XCTestCase {
    @MainActor
    func testRefreshIsReadOnlyAndDoesNotRequestPermission() async {
        var requests = 0, reads = 0
        let monitor = NotificationSettingsMonitor(query: {
            reads += 1; return .init(access: .notRequested, alerts: false)
        }, authorize: { requests += 1 })
        await monitor.refresh()
        XCTAssertEqual(monitor.value.access, .notRequested)
        XCTAssertEqual(reads, 1); XCTAssertEqual(requests, 0); XCTAssertFalse(monitor.busy)
    }
    @MainActor
    func testAllowQueriesFreshPermissionAndNeverRetriesADenial() async {
        var requests = 0
        var state = AppNotificationSettings(access: .notRequested, alerts: false)
        let monitor = NotificationSettingsMonitor(query: { state }, authorize: {
            requests += 1; state = .init(access: .denied, alerts: false)
        })
        await monitor.refresh()
        await monitor.requestPermission()
        XCTAssertEqual(requests, 1); XCTAssertEqual(monitor.value.access, .denied)
        await monitor.requestPermission()
        XCTAssertEqual(requests, 1); XCTAssertFalse(monitor.busy)
        // A later external enable is observed; no new request is necessary.
        state = .init(access: .allowed, alerts: true)
        await monitor.refresh(); await monitor.requestPermission()
        XCTAssertEqual(monitor.value, state); XCTAssertEqual(requests, 1)
    }
    @MainActor
    func testExternallyChangedPermissionCannotBeOverwrittenFromStaleUI() async {
        var requests = 0
        var state = AppNotificationSettings(access: .notRequested, alerts: false)
        let monitor = NotificationSettingsMonitor(query: { state }, authorize: { requests += 1 })
        await monitor.refresh()
        state = .init(access: .denied, alerts: false)
        await monitor.requestPermission()
        XCTAssertEqual(monitor.value, state); XCTAssertEqual(requests, 0)
    }
    @MainActor
    func testPreviewNeverQueriesOrAsksSystemPermission() async {
        var requests = 0, reads = 0
        let monitor = NotificationSettingsMonitor(simulated: true, query: {
            reads += 1; return .init(access: .allowed, alerts: true)
        }, authorize: { requests += 1 })
        await monitor.refresh(); await monitor.requestPermission()
        XCTAssertEqual(reads, 0); XCTAssertEqual(requests, 0)
        XCTAssertEqual(monitor.value.access, .notRequested)
    }
    @MainActor
    func testFailedRequestDoesNotClaimAuthorizationOrExposeErrors() async {
        let monitor = NotificationSettingsMonitor(query: { .init(access: .notRequested, alerts: false) },
            authorize: { throw NSError(domain: "secret endpoint", code: 1) })
        await monitor.requestPermission()
        XCTAssertEqual(monitor.value.access, .notRequested); XCTAssertFalse(monitor.busy)
        XCTAssertNotNil(monitor.error); XCTAssertFalse(monitor.error!.contains("secret"))
    }
    @MainActor
    func testRepeatedClicksWhilePermissionIsPendingAreIgnored() async {
        var requests = 0
        var state = AppNotificationSettings(access: .notRequested, alerts: false)
        var continuation: CheckedContinuation<Void, Never>?
        let began = expectation(description: "authorization began")
        let monitor = NotificationSettingsMonitor(query: { state }, authorize: {
            requests += 1
            await withCheckedContinuation { continuation = $0; began.fulfill() }
            state = .init(access: .allowed, alerts: true)
        })
        let first = Task { await monitor.requestPermission() }
        await fulfillment(of: [began], timeout: 2)
        XCTAssertTrue(monitor.busy)
        await monitor.requestPermission(); await monitor.refresh()
        XCTAssertEqual(requests, 1)
        continuation?.resume()
        await first.value
        XCTAssertFalse(monitor.busy); XCTAssertEqual(monitor.value, state)
    }
}
