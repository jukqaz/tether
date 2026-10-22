import XCTest
import IOKit.pwr_mgt
@testable import TetherCore

/// Exercises the production identity check with observed dictionaries; never creates
/// an OS assertion or changes actual display, sleep or lock state.
private final class DisplayAssertionFixture: IdleAssertionBackend {
    let id: UInt32
    let type: NativeIdleAssertionBackend.AssertionType
    var active = true
    var queryAvailable = true
    var releaseCode: Int32 = 0
    var created: [Double] = []
    var renewed: [(UInt32, Double)] = []
    var released: [UInt32] = []

    init(id: UInt32 = 8, type: NativeIdleAssertionBackend.AssertionType = .display) {
        self.id = id; self.type = type
    }
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        created.append(timeout); active = true
        return (0, id)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 {
        renewed.append((id, timeout)); active = true
        return 0
    }
    func level(id: UInt32) -> Int? {
        let properties: [String: Any] = ["AssertionId": NSNumber(value: self.id),
            "AssertPID": NSNumber(value: 42), "AssertType": type.nativeType,
            "AssertLevel": NSNumber(value: kIOPMAssertionLevelOn)]
        let allocations: [NSNumber: [[String: Any]]]? = queryAvailable ? [42: active ? [properties] : []] : nil
        return NativeIdleAssertionBackend.confirmedLevel(id: id, pid: 42, properties: properties,
            active: allocations, type: type)
    }
    func release(id: UInt32) -> Int32 {
        released.append(id)
        if releaseCode == 0 { active = false }
        return releaseCode
    }
}

final class DisplayAssertionDriverTests: XCTestCase {
    private func properties(id: UInt32 = 8, pid: Int32 = 42,
                            type: NativeIdleAssertionBackend.AssertionType = .display) -> [String: Any] {
        ["AssertionId": NSNumber(value: id), "AssertPID": NSNumber(value: pid),
         "AssertType": type.nativeType, "AssertLevel": NSNumber(value: kIOPMAssertionLevelOn)]
    }

    func testNativeBackendDefaultsToSystemAndMapsDisplayToIdleDisplaySleep() {
        XCTAssertEqual(NativeIdleAssertionBackend().type, .system)
        XCTAssertEqual(NativeIdleAssertionBackend.AssertionType.system.nativeType, kIOPMAssertPreventUserIdleSystemSleep)
        XCTAssertEqual(NativeIdleAssertionBackend(type: .display).type.nativeType, kIOPMAssertPreventUserIdleDisplaySleep)
        // Every value is rejected before reaching IOKit; no native lease is created.
        for type in [NativeIdleAssertionBackend.AssertionType.system, .display] {
            let backend = NativeIdleAssertionBackend(type: type)
            for timeout in [0.0, -1, 0.5, .nan, .infinity] {
                let result = backend.create(timeout: timeout)
                XCTAssertEqual(result.code, Int32(kIOReturnBadArgument)); XCTAssertNil(result.id)
                XCTAssertEqual(backend.renew(id: 0, timeout: timeout), Int32(kIOReturnBadArgument))
            }
        }
    }

    func testNativeObservationRejectsConfusingSystemAndDisplayTypes() {
        let display = properties()
        let system = properties(type: .system)
        XCTAssertEqual(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: display,
            active: [42: [display]], type: .display), kIOPMAssertionLevelOn)
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: system,
            active: [42: [display]], type: .display))
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: display,
            active: [42: [system]], type: .display))
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: display,
            active: [42: [system]], type: .system))
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: system,
            active: [42: [display]], type: .system))
        // Omitting the type remains a system-only observation for existing callers.
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: display,
            active: [42: [display]]))
    }

    func testDisplayObservationRequiresIdentityAndSuccessfulQuery() {
        let display = properties()
        XCTAssertEqual(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: display,
            active: [:], type: .display), kIOPMAssertionLevelOff)
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: display,
            active: nil, type: .display))
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: properties(id: 9),
            active: [42: [display]], type: .display))
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: properties(pid: 99),
            active: [42: [display]], type: .display))
        var unknownLevel = display; unknownLevel["AssertLevel"] = NSNumber(value: 999)
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: display,
            active: [42: [unknownLevel]], type: .display))
        var ambiguous = display; ambiguous.removeValue(forKey: "AssertionId")
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: display,
            active: [42: [ambiguous]], type: .display))
        XCTAssertEqual(NativeIdleAssertionBackend.confirmedLevel(id: 8, pid: 42, properties: display,
            active: [42: [properties(id: 9)]], type: .display), kIOPMAssertionLevelOff)
    }

    func testDisplayAndSystemDriversOwnAndReleaseIndependentIDs() async {
        await MainActor.run {
            let displayBackend = DisplayAssertionFixture()
            let systemBackend = DisplayAssertionFixture(id: 7, type: .system)
            let display = IdleAssertionDriver(backend: displayBackend)
            let system = IdleAssertionDriver(backend: systemBackend)
            display.apply(expiry: 130, now: 100); system.apply(expiry: 130, now: 100)
            XCTAssertEqual(display.state, .holding); XCTAssertEqual(system.state, .holding)
            XCTAssertEqual(display.assertionID, 8); XCTAssertEqual(system.assertionID, 7)
            display.end()
            XCTAssertEqual(displayBackend.released, [8]); XCTAssertTrue(systemBackend.released.isEmpty)
            XCTAssertEqual(system.state, .holding); XCTAssertEqual(system.assertionID, 7)
            system.apply(expiry: 133, now: 103)
            XCTAssertEqual(systemBackend.renewed.first?.0, 7)
            system.end(); XCTAssertEqual(systemBackend.released, [7])
            XCTAssertEqual(displayBackend.created, [15]); XCTAssertEqual(systemBackend.created, [15])
        }
    }

    func testDisplayTimeoutRearmsSameIDAndExplicitStopReleasesIt() async {
        await MainActor.run {
            let backend = DisplayAssertionFixture()
            let display = IdleAssertionDriver(backend: backend)
            display.apply(expiry: 100_000, now: 100)
            XCTAssertEqual(backend.created, [15]); XCTAssertEqual(display.expiry, 115)
            backend.active = false; display.observe()
            XCTAssertEqual(display.state, .inactive); XCTAssertEqual(display.assertionID, 8)
            display.apply(expiry: 300, now: 200)
            XCTAssertEqual(display.state, .holding); XCTAssertEqual(display.confirmedExpiry, 215)
            XCTAssertEqual(backend.created.count, 1); XCTAssertEqual(backend.renewed.first?.0, 8)
            XCTAssertEqual(backend.renewed.first?.1, 15)
            display.end()
            XCTAssertEqual(backend.released, [8]); XCTAssertNil(display.assertionID)
        }
    }

    func testDisplayUnavailableQueryFreezesEvidenceAndEndsAtItsDeadline() async {
        await MainActor.run {
            let backend = DisplayAssertionFixture()
            let display = IdleAssertionDriver(backend: backend)
            display.apply(expiry: 130, now: 100)
            backend.queryAvailable = false
            display.apply(expiry: 133, now: 103)
            XCTAssertEqual(display.state, .unverified)
            XCTAssertEqual(display.expiry, 115); XCTAssertEqual(display.confirmedExpiry, 115)
            XCTAssertTrue(backend.renewed.isEmpty)
            display.apply(expiry: 280, now: 115)
            XCTAssertEqual(backend.released, [8]); XCTAssertNil(display.assertionID)
        }
    }

    func testShortenedDisplayDeadlineEndsAnUnobservedAllocation() async {
        await MainActor.run {
            let backend = DisplayAssertionFixture()
            let display = IdleAssertionDriver(backend: backend)
            display.apply(expiry: 130, now: 100)
            backend.queryAvailable = false; display.apply(expiry: 110, now: 103)
            XCTAssertEqual(display.state, .inactive); XCTAssertEqual(backend.released, [8])
            XCTAssertTrue(backend.renewed.isEmpty); XCTAssertNil(display.expiry)
        }
    }

    func testDisplayFailedReleasePreservesOwnIDAndRetriesWithoutASecondCreation() async {
        await MainActor.run {
            let backend = DisplayAssertionFixture()
            let display = IdleAssertionDriver(backend: backend)
            display.apply(expiry: 130, now: 100)
            backend.releaseCode = -7; display.end()
            XCTAssertEqual(display.state, .failed(-7)); XCTAssertEqual(display.assertionID, 8)
            XCTAssertEqual(display.expiry, 115); XCTAssertEqual(display.confirmedExpiry, 115)
            backend.releaseCode = 0; display.end()
            XCTAssertEqual(backend.released, [8, 8]); XCTAssertEqual(backend.created.count, 1)
            XCTAssertNil(display.assertionID); XCTAssertNil(display.expiry)
        }
    }
}
