import Darwin
import Foundation
import XCTest
@testable import TetherCore

final class GUISessionAuthorityTests: XCTestCase {
    private let login = GUISessionIdentity(uid: 501, sessionID: 100001)
    private func confirmed(_ login: GUISessionIdentity, now: Double = 100) -> GUISessionAuthority {
        var result = GUISessionAuthority(login: login)
        result.observe(GUISessionObservation(login: login, consoleUID: login.uid), now: now)
        return result
    }
    func testAccountAndLoginIdentityAreDifferent() {
        XCTAssertNotEqual(login, GUISessionIdentity(uid: login.uid, sessionID: 100002))
        for value in [GUISessionIdentity(uid: 0, sessionID: 1), GUISessionIdentity(uid: .max, sessionID: 1),
                      GUISessionIdentity(uid: 501, sessionID: 0), GUISessionIdentity(uid: 501, sessionID: .max)] {
            XCTAssertFalse(value.isValid)
        }
    }
    func testSameGraphicalLoginContinuesAcrossLockAndRemotePresence() {
        var lease = confirmed(login)
        // Lock, display off and remote presence do not identify another login.
        lease.observe(GUISessionObservation(login: login, consoleUID: login.uid), now: 130)
        XCTAssertTrue(lease.canAcquire); XCTAssertEqual(lease.confirmedUntil, 160)
    }
    func testKnownOtherConsoleUserRevokesImmediatelyAndDoesNotResurrect() {
        var lease = confirmed(login)
        lease.observe(GUISessionObservation(login: login, consoleUID: 502), now: 101)
        XCTAssertEqual(lease.status, .revoked); XCTAssertFalse(lease.canPreserveExisting(now: 101))
        lease.observe(GUISessionObservation(login: login, consoleUID: login.uid), now: 102)
        XCTAssertEqual(lease.status, .revoked); XCTAssertFalse(lease.canAcquire)
        lease.bind(login)
        lease.observe(GUISessionObservation(login: login, consoleUID: login.uid), now: 103)
        XCTAssertTrue(lease.canAcquire)
    }
    func testSameUIDDifferentLoginAlsoRevokes() {
        var lease = confirmed(login)
        lease.observe(GUISessionObservation(login: GUISessionIdentity(uid: login.uid, sessionID: 100002),
                                           consoleUID: login.uid), now: 101)
        XCTAssertEqual(lease.status, .revoked)
    }
    func testUnknownNeverAcquiresOrExtendsExistingDeadline() {
        var lease = confirmed(login)
        lease.observe(GUISessionObservation(login: nil, consoleUID: nil), now: 101)
        XCTAssertFalse(lease.canAcquire); XCTAssertEqual(lease.confirmedUntil, 130)
        XCTAssertEqual(lease.expiry(190, existing: true, now: 101), 130)
        XCTAssertNil(lease.expiry(190, existing: false, now: 101))
        lease.observe(GUISessionObservation(login: nil, consoleUID: nil), now: 129)
        XCTAssertEqual(lease.confirmedUntil, 130)
        XCTAssertTrue(lease.canPreserveExisting(now: 129))
        XCTAssertFalse(lease.canPreserveExisting(now: 130))
        XCTAssertNil(lease.expiry(190, existing: true, now: 130))
    }
    func testInitialUnknownHasNoLeaseOrPowerAuthority() {
        var lease = GUISessionAuthority(login: login)
        lease.observe(GUISessionObservation(login: nil, consoleUID: nil), now: 100)
        XCTAssertFalse(lease.canAcquire); XCTAssertNil(lease.confirmedUntil)
        XCTAssertNil(lease.expiry(150, existing: true, now: 100))
    }
    func testOnlyACompleteMatchingObservationRenews() {
        for observation in [GUISessionObservation(login: login, consoleUID: nil),
                            GUISessionObservation(login: nil, consoleUID: login.uid)] {
            var lease = confirmed(login)
            lease.observe(observation, now: 120)
            XCTAssertEqual(lease.status, .unavailable); XCTAssertEqual(lease.confirmedUntil, 130)
        }
    }
    func testInvalidAndBackwardClockDiscardTheLease() {
        for now in [Double.nan, Double.infinity, -Double.infinity, -1, 99] {
            var lease = confirmed(login)
            lease.observe(GUISessionObservation(login: login, consoleUID: login.uid), now: now)
            XCTAssertFalse(lease.canAcquire); XCTAssertNil(lease.confirmedUntil)
        }
    }
    func testInvalidClockCannotRestoreRevokedAuthority() {
        for now in [Double.nan, Double.infinity, -1, 99] {
            var lease = confirmed(login)
            lease.observe(GUISessionObservation(login: login, consoleUID: 502), now: 101)
            lease.observe(GUISessionObservation(login: login, consoleUID: login.uid), now: now)
            lease.observe(GUISessionObservation(login: login, consoleUID: login.uid), now: 102)
            XCTAssertEqual(lease.status, .revoked)
            XCTAssertFalse(lease.canAcquire); XCTAssertNil(lease.confirmedUntil)
        }
    }
    func testClockNeedsARepresentableFutureDeadline() {
        for now in [-1.0, Double.greatestFiniteMagnitude] {
            var lease = GUISessionAuthority(login: login)
            lease.observe(GUISessionObservation(login: login, consoleUID: login.uid), now: now)
            XCTAssertFalse(lease.canAcquire); XCTAssertNil(lease.confirmedUntil)
        }
        let lease = confirmed(login)
        XCTAssertFalse(lease.canPreserveExisting(now: 99))
    }
    func testManualExpiryCannotBeExtendedByTheGUILease() {
        let lease = confirmed(login)
        XCTAssertEqual(lease.expiry(105, existing: false, now: 100), 105)
        XCTAssertEqual(lease.expiry(999, existing: false, now: 100), 130)
        XCTAssertNil(lease.expiry(nil, existing: true, now: 100))
    }
    func testOwnerRequiresBootUIDLifetimeAndExecutable() throws {
        let process = try XCTUnwrap(ProcessIdentity.capture(pid: getpid()))
        let owner = GUISessionOwner(bootID: "boot", process: process,
                                   login: GUISessionIdentity(uid: process.uid, sessionID: 100001))
        XCTAssertTrue(owner.matches(process: process, boot: "boot"))
        XCTAssertFalse(owner.matches(process: process, boot: "other"))
        XCTAssertFalse(owner.matches(process: process, boot: ""))
        XCTAssertFalse(owner.matches(process: nil, boot: "boot"))
        var changed = process; changed.started += 1
        XCTAssertFalse(owner.matches(process: changed, boot: "boot"))
        changed = process; changed.uid += 1
        XCTAssertFalse(owner.matches(process: changed, boot: "boot"))
        changed = process; changed.executable = "/path/that/does/not/exist"
        XCTAssertFalse(owner.matches(process: changed, boot: "boot"))
    }
    func testClientJSONCannotClaimASessionAndEncodingDoesNotDiscloseMetadata() throws {
        let raw = Data("{\"version\":2,\"id\":\"00000000-0000-0000-0000-000000000001\",\"action\":\"attachApp\",\"authenticatedPID\":1,\"authenticatedGUILogin\":{\"uid\":501,\"sessionID\":100001}}".utf8)
        var request = try JSONDecoder().decode(ServiceRequest.self, from: raw)
        XCTAssertNil(request.authenticatedPID); XCTAssertNil(request.authenticatedGUILogin)
        request.authenticatedGUILogin = login; request.authenticatedPID = 123
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(object["authenticatedGUILogin"]); XCTAssertNil(object["authenticatedPID"])
    }
    func testLegacyHelperStateHasNoInventedGUIApproval() throws {
        let state = try JSONDecoder().decode(HelperState.self, from: Data("{\"appPID\":123,\"appUID\":501,\"appStarted\":99}".utf8))
        XCTAssertEqual(state.appUID, 501); XCTAssertNil(state.guiOwner); XCTAssertNil(state.controllerUID)
    }
    func testNativePeerTokenMatchesCallerAndRejectsWrongSocketCredentials() throws {
        guard let native = GUISessionProbe.caller() else { throw XCTSkip("No native graphical login; no simulated native success") }
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        XCTAssertEqual(GUISessionProbe.peer(fd: descriptors[0], uid: getuid(), pid: getpid()), native)
        XCTAssertNil(GUISessionProbe.peer(fd: descriptors[0], uid: getuid() + 1, pid: getpid()))
        XCTAssertNil(GUISessionProbe.peer(fd: descriptors[0], uid: getuid(), pid: getpid() + 1))
        XCTAssertNil(GUISessionProbe.peer(fd: -1, uid: getuid(), pid: getpid()))
    }
}
