import XCTest
import IOKit.pwr_mgt
@testable import TetherCore

private final class AssertionFixture: IdleAssertionBackend {
    var createCode: Int32 = 0
    var renewCode: Int32 = 0
    var releaseCode: Int32 = 0
    var omitCreatedID = false
    var observedLevel: Int? = 255
    var created: [Double] = []
    var renewed: [(UInt32, Double)] = []
    var released: [UInt32] = []
    var foreignLevel = 255
    var scriptedLevels: [Int?] = []
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        created.append(timeout)
        return (createCode, createCode == 0 && !omitCreatedID ? 7 : nil)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 {
        renewed.append((id, timeout))
        return renewCode
    }
    func level(id: UInt32) -> Int? { scriptedLevels.isEmpty ? observedLevel : scriptedLevels.removeFirst() }
    func release(id: UInt32) -> Int32 { released.append(id); return releaseCode }
}

final class IdleAssertionDriverTests: XCTestCase {
    func testUnconfirmedRenewalDoesNotExtendThePreviouslyObservedEvidenceHorizon() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let driver = IdleAssertionDriver(backend: fixture)
            driver.apply(expiry: 130, now: 100)
            fixture.scriptedLevels = [255, nil]
            driver.apply(expiry: 133, now: 103)
            XCTAssertEqual(driver.state, .unverified)
            XCTAssertEqual(driver.expiry, 118); XCTAssertEqual(driver.confirmedExpiry, 115)
            fixture.observedLevel = nil
            driver.apply(expiry: 280, now: 130)
            XCTAssertEqual(fixture.released, [7]); XCTAssertEqual(fixture.renewed.count, 1)
            XCTAssertNil(driver.assertionID)
        }
    }

    func testFirstUnavailableQueryFreezesTheLastConfirmedNativeDeadline() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let driver = IdleAssertionDriver(backend: fixture)
            driver.apply(expiry: 130, now: 100)
            fixture.observedLevel = nil
            for time in [103.0, 110, 114] { driver.apply(expiry: time + 15, now: time) }
            XCTAssertEqual(driver.state, .unverified)
            XCTAssertEqual(driver.expiry, 115); XCTAssertEqual(driver.confirmedExpiry, 115)
            XCTAssertTrue(fixture.renewed.isEmpty); XCTAssertEqual(fixture.created, [15])
            driver.apply(expiry: 280, now: 115)
            XCTAssertEqual(fixture.released, [7]); XCTAssertNil(driver.confirmedExpiry)
        }
    }

    func testShortenedPolicyEndsAnUnobservedAllocationInsteadOfIgnoringTheChange() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let driver = IdleAssertionDriver(backend: fixture)
            driver.apply(expiry: 130, now: 100)
            fixture.observedLevel = nil
            driver.apply(expiry: 110, now: 103)
            XCTAssertEqual(driver.state, .inactive); XCTAssertEqual(fixture.released, [7])
            XCTAssertTrue(fixture.renewed.isEmpty); XCTAssertNil(driver.expiry)
        }
    }

    func testRecoveryCanRenewOnlyAfterTheExistingAllocationIsObservedAgain() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let driver = IdleAssertionDriver(backend: fixture)
            driver.apply(expiry: 130, now: 100)
            fixture.observedLevel = nil; driver.apply(expiry: 133, now: 103)
            XCTAssertTrue(fixture.renewed.isEmpty)
            fixture.observedLevel = 255; driver.apply(expiry: 136, now: 106)
            XCTAssertEqual(driver.state, .holding); XCTAssertEqual(driver.confirmedExpiry, 121)
            XCTAssertEqual(fixture.renewed.count, 1); XCTAssertEqual(fixture.renewed.first?.0, 7)
            XCTAssertEqual(fixture.created, [15])
        }
    }

    func testInitiallyUnobservedCreationNeverGainsAConfirmedDeadlineOrRenewal() async {
        await MainActor.run {
            let fixture = AssertionFixture(); fixture.observedLevel = nil
            let driver = IdleAssertionDriver(backend: fixture)
            driver.apply(expiry: 130, now: 100); driver.apply(expiry: 200, now: 110)
            XCTAssertNil(driver.confirmedExpiry); XCTAssertEqual(driver.expiry, 115)
            XCTAssertTrue(fixture.renewed.isEmpty)
            driver.apply(expiry: nil, now: 111)
            XCTAssertEqual(fixture.released, [7]); XCTAssertNil(driver.assertionID)
        }
    }

    func testNativeObservationUsesActiveAllocationRatherThanStaleLevel() {
        let properties: [String: Any] = ["AssertionId": NSNumber(value: 7), "AssertPID": NSNumber(value: 42),
            "AssertType": kIOPMAssertPreventUserIdleSystemSleep, "AssertLevel": NSNumber(value: 255)]
        XCTAssertEqual(NativeIdleAssertionBackend.confirmedLevel(id: 7, pid: 42, properties: properties,
            active: [42: [properties]]), 255)
        XCTAssertEqual(NativeIdleAssertionBackend.confirmedLevel(id: 7, pid: 42, properties: properties,
            active: [:]), 0)
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 7, pid: 42, properties: properties, active: nil))
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 7, pid: 42, properties: nil, active: [:]))
        var ambiguous = properties; ambiguous.removeValue(forKey: "AssertionId")
        XCTAssertNil(NativeIdleAssertionBackend.confirmedLevel(id: 7, pid: 42, properties: properties,
            active: [42: [ambiguous]]))
        var another = properties; another["AssertionId"] = NSNumber(value: 8)
        XCTAssertEqual(NativeIdleAssertionBackend.confirmedLevel(id: 7, pid: 42, properties: properties,
            active: [42: [another]]), 0)
        XCTAssertEqual(NativeIdleAssertionBackend.confirmedLevel(id: 7, pid: 42, properties: properties,
            active: [99: [properties]]), 0)
    }
    func testRepeatedRenewalsOwnOneIDAndReleaseOnlyThatID() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let subject = IdleAssertionDriver(backend: fixture)
            for time in 100..<120 { subject.apply(expiry: Double(time + 15), now: Double(time)) }
            XCTAssertEqual(fixture.created, [15]); XCTAssertEqual(fixture.renewed.count, 19)
            XCTAssertTrue(fixture.renewed.allSatisfy { $0.0 == 7 && $0.1 == 15 })
            subject.end(); XCTAssertEqual(fixture.released, [7]); XCTAssertNil(subject.assertionID)
            XCTAssertEqual(fixture.foreignLevel, 255)
        }
    }
    func testExpiredOrInvalidDeadlineNeverCreatesTimeoutZero() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let driver = IdleAssertionDriver(backend: fixture)
            for deadline in [100.0, 99, .nan, .infinity] { driver.apply(expiry: deadline, now: 100) }
            driver.apply(expiry: nil, now: 100)
            XCTAssertTrue(fixture.created.isEmpty)
            driver.apply(expiry: 101, now: 100); driver.apply(expiry: 101, now: 101)
            XCTAssertEqual(fixture.created, [1]); XCTAssertEqual(fixture.released, [7])
        }
    }
    func testSubsecondDeadlineReleasesInsteadOfCreatingAnUnlimitedRequest() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let driver = IdleAssertionDriver(backend: fixture)
            driver.apply(expiry: 100.5, now: 100)
            XCTAssertTrue(fixture.created.isEmpty)
            driver.apply(expiry: 110, now: 100)
            driver.apply(expiry: 110, now: 109.5)
            XCTAssertTrue(fixture.renewed.isEmpty)
            XCTAssertEqual(fixture.released, [7]); XCTAssertEqual(driver.state, .inactive)
        }
    }
    func testDriverIndependentlyBoundsAnExcessivePolicyDeadline() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let driver = IdleAssertionDriver(backend: fixture)
            driver.apply(expiry: 100_000, now: 100)
            XCTAssertEqual(fixture.created, [15]); XCTAssertEqual(driver.expiry, 115)
        }
    }
    func testFailedCreateCannotClaimHolding() async {
        await MainActor.run {
            let fixture = AssertionFixture(); fixture.createCode = -5
            let driver = IdleAssertionDriver(backend: fixture)
            driver.apply(expiry: 130, now: 100)
            XCTAssertEqual(driver.state, .failed(-5)); XCTAssertNil(driver.assertionID)
        }
    }
    func testMissingIDOnSuccessIsStillFailure() async {
        await MainActor.run {
            let fixture = AssertionFixture(); fixture.omitCreatedID = true
            let driver = IdleAssertionDriver(backend: fixture)
            driver.apply(expiry: 130, now: 100)
            XCTAssertNotEqual(driver.state, .holding)
            XCTAssertNotEqual(driver.state, .failed(0)); XCTAssertNil(driver.assertionID)
        }
    }
    func testMissingLevelIsUnverifiedRatherThanHolding() async {
        await MainActor.run {
            let fixture = AssertionFixture(); fixture.observedLevel = nil
            let driver = IdleAssertionDriver(backend: fixture)
            driver.apply(expiry: 130, now: 100)
            XCTAssertEqual(driver.state, .unverified); XCTAssertEqual(driver.assertionID, 7)
        }
    }
    func testOSTimeoutObservationAndRearmUseTheSameAllocation() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let subject = IdleAssertionDriver(backend: fixture)
            subject.apply(expiry: 130, now: 100)
            fixture.observedLevel = 0; subject.observe()
            XCTAssertEqual(subject.state, .inactive); XCTAssertEqual(subject.assertionID, 7)
            fixture.observedLevel = 255; subject.apply(expiry: 150, now: 140)
            XCTAssertEqual(subject.state, .holding); XCTAssertEqual(fixture.created.count, 1)
            XCTAssertEqual(fixture.renewed.first?.0, 7)
        }
    }
    func testRenewFailurePreservesIDWithoutClaimingANewLease() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let subject = IdleAssertionDriver(backend: fixture)
            subject.apply(expiry: 130, now: 100); fixture.renewCode = -6
            subject.apply(expiry: 150, now: 110)
            XCTAssertEqual(subject.state, .failed(-6)); XCTAssertEqual(subject.expiry, 115)
            XCTAssertEqual(subject.assertionID, 7); XCTAssertEqual(fixture.created.count, 1)
        }
    }
    func testFailedReleaseKeepsIDAndRetriesItWithoutAnotherCreate() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let subject = IdleAssertionDriver(backend: fixture)
            subject.apply(expiry: 130, now: 100); fixture.releaseCode = -7
            subject.end(); XCTAssertEqual(subject.state, .failed(-7)); XCTAssertEqual(subject.assertionID, 7)
            XCTAssertEqual(subject.expiry, 115)
            fixture.releaseCode = 0; subject.end()
            XCTAssertEqual(fixture.released, [7, 7]); XCTAssertEqual(fixture.created.count, 1)
            XCTAssertNil(subject.assertionID)
        }
    }
    func testLaterPolicyCannotRenewAnAllocationWithPendingRelease() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let subject = IdleAssertionDriver(backend: fixture)
            subject.apply(expiry: 130, now: 100)
            fixture.releaseCode = -7
            subject.end()
            subject.apply(expiry: 200, now: 110)
            XCTAssertTrue(subject.releasePending)
            XCTAssertEqual(subject.state, .failed(-7))
            XCTAssertEqual(subject.expiry, 115)
            XCTAssertEqual(fixture.released, [7, 7])
            XCTAssertEqual(fixture.created, [15])
            XCTAssertTrue(fixture.renewed.isEmpty)
        }
    }
    func testObservationCannotTurnFailedCleanupBackIntoHolding() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let subject = IdleAssertionDriver(backend: fixture)
            subject.apply(expiry: 130, now: 100)
            fixture.releaseCode = -7
            subject.end()
            for level in [Int?(255), 0, nil] {
                fixture.observedLevel = level
                subject.observe()
                XCTAssertTrue(subject.releasePending)
                XCTAssertEqual(subject.state, .failed(-7))
            }
            XCTAssertEqual(fixture.created.count, 1)
            XCTAssertTrue(fixture.renewed.isEmpty)
        }
    }
    func testSuccessfulPendingCleanupAllowsOnlyTheCurrentFiniteRequest() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let subject = IdleAssertionDriver(backend: fixture)
            subject.apply(expiry: 130, now: 100)
            fixture.releaseCode = -7
            subject.end()
            fixture.releaseCode = 0
            subject.apply(expiry: 122, now: 120)
            XCTAssertFalse(subject.releasePending)
            XCTAssertEqual(subject.state, .holding)
            XCTAssertEqual(subject.expiry, 122)
            XCTAssertEqual(subject.confirmedExpiry, 122)
            XCTAssertEqual(fixture.created, [15, 2])
            XCTAssertTrue(fixture.renewed.isEmpty)
            XCTAssertEqual(fixture.released, [7, 7])
        }
    }
    func testSuccessfulPendingCleanupCannotResurrectAnExpiredRequest() async {
        await MainActor.run {
            let fixture = AssertionFixture()
            let subject = IdleAssertionDriver(backend: fixture)
            subject.apply(expiry: 130, now: 100)
            fixture.releaseCode = -7
            subject.end()
            fixture.releaseCode = 0
            subject.apply(expiry: 115, now: 120)
            XCTAssertFalse(subject.releasePending)
            XCTAssertEqual(subject.state, .inactive)
            XCTAssertNil(subject.assertionID)
            XCTAssertEqual(fixture.created, [15])
            XCTAssertTrue(fixture.renewed.isEmpty)
        }
    }
}
