import XCTest
import Darwin
@testable import TetherCore

final class V4UserSessionProtocolTests: XCTestCase {
    let pid = V4ProcessIdentity(pid: 42, startIdentity: 100, executableIdentity: "/usr/bin/task")
    func event() -> V4WorkEvent {
        .init(jobID: UUID(), eventID: UUID(), sequence: 0, scope: V4Fixture.scope, producerID: "build", kind: .start)
    }
    func testPayloadAdmissionDoesNotTurnStatusOrOtherCommandsIntoManualAuthority() {
        XCTAssertTrue(UserSessionRequest(.status, now: 100, workEvent: event()).isValid(now: 100))
        XCTAssertFalse(UserSessionRequest(.off, now: 100, workEvent: event()).isValid(now: 100))
        XCTAssertTrue(UserSessionRequest(.manual(minutes: 30), now: 100, manualPID: pid).isValid(now: 100))
        XCTAssertFalse(UserSessionRequest(.status, now: 100, manualPID: pid).isValid(now: 100))
        XCTAssertFalse(UserSessionRequest(.manual(minutes: 30), now: 100, workEvent: event(), manualPID: pid).isValid(now: 100))
    }
    func testInvalidPIDAndOversizedTaskLivenessAreRejectedBeforeDispatch() {
        var invalid = pid; invalid.startIdentity = 0
        XCTAssertFalse(UserSessionRequest(.manual(minutes: 30), now: 100, manualPID: invalid).isValid(now: 100))
        var task = event(); task.ttl = 301
        XCTAssertFalse(UserSessionRequest(.status, now: 100, workEvent: task).isValid(now: 100))
        task.ttl = .nan
        XCTAssertFalse(UserSessionRequest(.status, now: 100, workEvent: task).isValid(now: 100))
    }
    func testOptionalV4PayloadsPreserveOldWireDecoding() throws {
        let request = UserSessionRequest(.status, now: 100)
        let decoded = try JSONDecoder().decode(UserSessionRequest.self, from: JSONEncoder().encode(request))
        XCTAssertNil(decoded.workEvent); XCTAssertNil(decoded.manualPID)
        let reply = UserSessionReply(id: request.id, epoch: UUID(), revision: 0, ok: true)
        let decodedReply = try JSONDecoder().decode(UserSessionReply.self, from: JSONEncoder().encode(reply))
        XCTAssertNil(decodedReply.workScope); XCTAssertNil(decodedReply.workEventResult)
    }
    @MainActor
    func testPrivateIPCTransportsStructuredPolicyRefusalWithoutCreatingWork() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/tv4-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("commands.sock").path
        let service = UserSessionService(path: path)
        defer { service.stop(); try? FileManager.default.removeItem(at: directory) }
        let epoch = UUID()
        try service.start { request, _ in
            var reply = UserSessionReply(id: request.id, epoch: epoch, revision: 0, ok: request.workEvent == nil,
                                         error: request.workEvent == nil ? nil : "automatic-gate-blocked")
            reply.workScope = V4Fixture.scope
            if request.workEvent != nil {
                reply.workEventResult = .init(disposition: .rejected, reason: "automatic-gate-blocked", record: nil)
            }
            return reply
        }
        let executable = try XCTUnwrap(ProcessIdentity.capture(pid: getpid())?.executable)
        let task = event()
        let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UserSessionReply, Error>) in
            DispatchQueue.global().async {
                do { continuation.resume(returning: try UserSessionClient(path: path, expectedServer: executable).perform(.status, workEvent: task)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.workEventResult?.disposition, .rejected)
        XCTAssertEqual(reply.workScope, V4Fixture.scope)
        XCTAssertNil(reply.workEventResult?.record)
    }
}
