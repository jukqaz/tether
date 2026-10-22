import Darwin
import XCTest
@testable import TetherCore

final class UserSessionProtocolTests: XCTestCase {
    private let client = ProcessIdentity(pid: 45, uid: 501, started: 123, executable: "/fixture/tether")
    private func request(_ ledger: UserCommandLedger, now: Double = 100) -> UserSessionRequest {
        UserSessionRequest(.toggle, epoch: ledger.epoch, revision: ledger.revision, now: now)
    }
    func testACManualAndBatteryAliasHaveSeparateBoundsAndOnlyExplicit15Or30MinuteExtensions() throws {
        XCTAssertEqual(TetherCommand.parse(["manual", "unlimited"]), .manual(minutes: nil))
        XCTAssertEqual(TetherCommand.parse(["manual", "24h"]), .manual(minutes: 1440))
        XCTAssertEqual(TetherCommand.parse(["manual", "24h1m"]), .manual(minutes: 1441))
        XCTAssertEqual(TetherCommand.parse(["manual", "+30m"]), .extendManual(minutes: 30))
        XCTAssertEqual(TetherCommand.parse(["manual", "+15m"]), .extendManual(minutes: 15))
        XCTAssertNil(TetherCommand.parse(["manual", "+20m"]))
        XCTAssertEqual(TetherCommand.parse(["manual", "off"]), .endManual)
        XCTAssertEqual(TetherCommand.parse(["hold", "2h"]), .hold(minutes: 120))
        XCTAssertNil(TetherCommand.parse(["hold", "2h1m"]))
        XCTAssertNil(TetherCommand.parse(["hold", "4h"]))
        XCTAssertEqual(TetherCommand.parse(["auto", "off"]), .automatic(false))
        XCTAssertEqual(TetherCommand.parse(["condition", "ac"]), .condition(.ac))
        XCTAssertEqual(TetherCommand.parse(["condition", "battery"]), .condition(.battery))
        XCTAssertEqual(TetherCommand.parse(["condition", "any"]), .condition(.any))
        for input in [["on", "off"], ["sleep", "now"], ["status", "manual"], ["auto", "on", "off"], ["manual", "-1"], ["manual", "nan"], ["manual", "0"]] {
            XCTAssertNil(TetherCommand.parse(input), "Unexpected valid input: \(input)")
        }
        let commands: [TetherCommand] = [.manual(minutes: nil), .manual(minutes: 120), .automatic(true), .condition(.any), .endManual]
        for command in commands {
            XCTAssertEqual(try JSONDecoder().decode(TetherCommand.self, from: JSONEncoder().encode(command)), command)
        }
    }
    func testURLUsesTheSameParserAndBounds() throws {
        XCTAssertEqual(TetherCommand.parse(url: try XCTUnwrap(URL(string: "tether://manual/2h"))), .manual(minutes: 120))
        XCTAssertEqual(TetherCommand.parse(url: try XCTUnwrap(URL(string: "tether://auto/off"))), .automatic(false))
        XCTAssertEqual(TetherCommand.parse(url: try XCTUnwrap(URL(string: "tether://condition/ac"))), .condition(.ac))
        XCTAssertNil(TetherCommand.parse(url: try XCTUnwrap(URL(string: "tether://on/off"))))
        XCTAssertNil(TetherCommand.parse(url: try XCTUnwrap(URL(string: "https://manual/2h"))))
    }
    func testDeadlineVersionAndPayloadAreValidatedBeforeExecution() {
        var value = UserSessionRequest(.manual(minutes: 60), now: 100)
        XCTAssertTrue(value.isValid(now: 100)); XCTAssertFalse(value.isValid(now: 115))
        XCTAssertFalse(value.isValid(now: 99)); XCTAssertFalse(value.isValid(now: .nan))
        value.version = 2; XCTAssertFalse(value.isValid(now: 100)); value.version = 1
        value.build += 1; XCTAssertFalse(value.isValid(now: 100)); value.build = TetherPaths.build
        value.deadline = .infinity; XCTAssertFalse(value.isValid(now: 100))
        value.deadline = 115; value.command = .manual(minutes: 1441); XCTAssertTrue(value.isValid(now: 100))
        value.command = .manual(minutes: Int.max); XCTAssertFalse(value.isValid(now: 100))
        value.command = .hold(minutes: 121); XCTAssertFalse(value.isValid(now: 100))
        value.command = .extendManual(minutes: 1); XCTAssertFalse(value.isValid(now: 100))
    }
    func testRecordingWireHasBoundedDurationAndCannotCarryPowerOrTaskAuthority() throws {
        for minutes in [1, 15, 240] {
            let request = UserSessionRequest(now: 100, recording: .start(minutes: minutes))
            XCTAssertTrue(request.isValid(now: 100))
            XCTAssertEqual(try JSONDecoder().decode(UserSessionRequest.self, from: JSONEncoder().encode(request)), request)
            XCTAssertFalse(request.isValid(now: 115), "Recording commands retain the ordinary 15-second request lifetime")
        }
        for minutes in [Int.min, 0, 241, Int.max] {
            XCTAssertFalse(UserSessionRequest(now: 100, recording: .start(minutes: minutes)).isValid(now: 100))
        }
        var request = UserSessionRequest(now: 100, recording: .finish(recordingID: UUID()))
        XCTAssertTrue(request.isValid(now: 100))
        request.command = .off; XCTAssertFalse(request.isValid(now: 100))
        request.command = .status
        request.workEvent = .init(jobID: UUID(), eventID: UUID(), sequence: 0,
            scope: .init(bootID: "fixture", ownerID: "owner", powerGeneration: 0), producerID: "fixture", kind: .start)
        XCTAssertFalse(request.isValid(now: 100))
        request.workEvent = nil
        request.manualPID = .init(pid: 42, startIdentity: 100, executableIdentity: "/fixture/task")
        XCTAssertFalse(request.isValid(now: 100))
        XCTAssertNil(TetherCommand.parse(["record", "15"]))
        XCTAssertNil(TetherCommand.parse(url: try XCTUnwrap(URL(string: "tether://record/15"))))
        let old = UserSessionRequest(now: 100)
        XCTAssertNil(try JSONDecoder().decode(UserSessionRequest.self, from: JSONEncoder().encode(old)).recording)
        let oldReply = UserSessionReply(id: old.id, epoch: UUID(), revision: 0, ok: true)
        XCTAssertNil(try JSONDecoder().decode(UserSessionReply.self, from: JSONEncoder().encode(oldReply)).recordingID)
    }
    func testCLIUsesCurrentAppOwnerAndNeverTransfersOwnershipToANonGraphicalPeer() {
        let login = GUISessionIdentity(uid: 501, sessionID: 100001)
        let owner = GUISessionObservation(login: login, consoleUID: 501)
        func permitted(_ process: ProcessIdentity? = nil, uid: UInt32 = 501, peer: GUISessionIdentity? = nil,
                       observation: GUISessionObservation? = nil, expected: String = "/fixture/tether") -> Bool {
            UserSessionAccess.permits(client: process ?? client, uid: uid, peerLogin: peer,
                owner: observation ?? owner, expectedExecutable: expected, sameExecutable: ==)
        }
        XCTAssertTrue(permitted()); XCTAssertTrue(permitted(peer: login))
        XCTAssertFalse(permitted(peer: GUISessionIdentity(uid: 501, sessionID: 100002)))
        XCTAssertFalse(permitted(uid: 502)); XCTAssertFalse(permitted(uid: 0))
        XCTAssertFalse(permitted(expected: "/another/tether"))
        XCTAssertFalse(permitted(observation: .init(login: login, consoleUID: 502)))
        XCTAssertFalse(permitted(observation: .init(login: nil, consoleUID: 501)))
    }
    func testCASDoesNotAcceptPreviousRevisionOrPreviousAppEpoch() {
        var ledger = UserCommandLedger(); let original = request(ledger)
        if case .ready = ledger.check(original, client: client, now: 100) {} else { XCTFail("Initial request must be ready") }
        ledger.advance()
        if case .stale = ledger.check(original, client: client, now: 101) {} else { XCTFail("Previous revision must be rejected") }
        var another = request(ledger); another.epoch = UUID()
        if case .stale = ledger.check(another, client: client, now: 101) {} else { XCTFail("Previous process epoch must be rejected") }
    }
    func testIdenticalReplayReturnsTheOriginalReceiptButPayloadAndPIDReuseDoNot() {
        var ledger = UserCommandLedger(); let original = request(ledger)
        ledger.advance()
        let reply = UserSessionReply(id: original.id, epoch: ledger.epoch, revision: ledger.revision, ok: true)
        ledger.record(original, client: client, reply: reply)
        if case .replay(let cached) = ledger.check(original, client: client, now: 101) {
            XCTAssertEqual(cached.revision, reply.revision); XCTAssertEqual(cached.observedAt, reply.observedAt)
        } else { XCTFail("Lost acknowledgement must not apply the command again") }
        var changed = original; changed.command = .off
        if case .invalidReplay = ledger.check(changed, client: client, now: 101) {} else { XCTFail("Payload replacement must fail") }
        var reused = client; reused.started += 1
        if case .invalidReplay = ledger.check(original, client: reused, now: 101) {} else { XCTFail("PID reuse must fail") }
    }
    func testReceiptCapacityPreservesLiveRetriesAndOnlyExpiresAfterTheirDeadline() {
        var ledger = UserCommandLedger(); let first = request(ledger)
        for index in 0..<64 {
            let value = index == 0 ? first : request(ledger)
            ledger.advance()
            ledger.record(value, client: client, reply: .init(id: value.id, epoch: ledger.epoch, revision: ledger.revision, ok: true))
        }
        if case .busy = ledger.check(request(ledger), client: client, now: 101) {} else { XCTFail("Full cache must not evict a live retry") }
        if case .replay = ledger.check(first, client: client, now: 101) {} else { XCTFail("Oldest live receipt must remain available") }
        let fresh = request(ledger, now: 115)
        if case .ready = ledger.check(fresh, client: client, now: 115) {} else { XCTFail("Expired requests can be reclaimed") }
    }
    func testPackagedAndDebugCompanionsResolveOnlyTheirOwnAppLayout() {
        XCTAssertEqual(UserSessionEndpoint.coordinatorExecutable(forClient: "/a/Tether.app/Contents/Helpers/tether"), "/a/Tether.app/Contents/MacOS/Tether")
        XCTAssertEqual(UserSessionEndpoint.companionExecutable(forCoordinator: "/a/Tether.app/Contents/MacOS/Tether"), "/a/Tether.app/Contents/Helpers/tether")
        XCTAssertEqual(UserSessionEndpoint.coordinatorExecutable(forClient: "/a/TetherCLI"), "/a/Tether")
        XCTAssertNil(UserSessionEndpoint.coordinatorExecutable(forClient: "/a/unrelated"))
    }
    func testProductionSocketSharesThePrivateCoordinatorFolderInsteadOfURLSessionCache() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expectedFolder = home.appendingPathComponent("Library/Application Support/" + TetherPaths.bundleID)
        let endpoint = URL(fileURLWithPath: UserSessionEndpoint.production)
        XCTAssertEqual(endpoint.deletingLastPathComponent().path, expectedFolder.path)
        XCTAssertEqual(endpoint.deletingLastPathComponent().path,
                       URL(fileURLWithPath: AppCoordinatorLease.production).deletingLastPathComponent().path)
        XCTAssertEqual(endpoint.lastPathComponent, "commands.sock")
        XCTAssertNotEqual(endpoint.deletingLastPathComponent().path,
                          home.appendingPathComponent("Library/Caches/" + TetherPaths.bundleID).path)
    }
    @MainActor
    func testPrivateCoordinatorSocketWorksWithoutChangingPublicURLSessionCache() async throws {
        let folder = try privateFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("Caches")
        let cachedData = cache.appendingPathComponent("fsCachedData")
        let database = cache.appendingPathComponent("Cache.db")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        try FileManager.default.createDirectory(at: cachedData, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(chmod(cache.path, 0o755), 0)
        let cacheBytes = Data("URLSession cache fixture".utf8)
        try cacheBytes.write(to: database)
        var before = stat(); XCTAssertEqual(lstat(cache.path, &before), 0)
        XCTAssertThrowsError(try UserSessionEndpoint.verifyFolder(cache.appendingPathComponent("commands.sock").path,
                                                                 create: false))
        let support = folder.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let lease = try AppCoordinatorLease.acquire(at: support.appendingPathComponent("instance.lock").path)
        let socket = support.appendingPathComponent("commands.sock").path
        let server = UserSessionService(path: socket); defer { server.stop() }
        let current = try XCTUnwrap(ProcessIdentity.capture(pid: getpid()))
        let epoch = UUID()
        try server.start { request, _ in .init(id: request.id, epoch: epoch, revision: 0, ok: true) }
        let reply = try await Task.detached {
            try UserSessionClient(path: socket, expectedServer: current.executable).snapshot()
        }.value
        XCTAssertEqual(reply.epoch, epoch)
        XCTAssertTrue(lease.isValid, "The command service must not replace the app coordinator's lock")
        var socketInfo = stat(); XCTAssertEqual(lstat(socket, &socketInfo), 0)
        XCTAssertEqual(socketInfo.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(socketInfo.st_mode & 0o777, 0o600)
        var after = stat(); XCTAssertEqual(lstat(cache.path, &after), 0)
        XCTAssertEqual(after.st_dev, before.st_dev); XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_mode & 0o777, 0o755)
        XCTAssertEqual(try Data(contentsOf: database), cacheBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedData.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("commands.sock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("commands.lock").path))
    }
    func testSocketFolderRejectsSymlinksAndPublicPermissions() throws {
        let folder = try privateFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("commands.sock").path
        XCTAssertNoThrow(try UserSessionEndpoint.verifyFolder(socket, create: false))
        XCTAssertEqual(chmod(folder.path, 0o755), 0)
        XCTAssertThrowsError(try UserSessionEndpoint.verifyFolder(socket, create: false))
        XCTAssertEqual(chmod(folder.path, 0o700), 0)
        let link = folder.appendingPathComponent("link").path
        XCTAssertEqual(symlink(folder.path, link), 0)
        XCTAssertThrowsError(try UserSessionEndpoint.verifyFolder(link + "/commands.sock", create: false))
    }
    @MainActor
    func testSocketHasOneLifetimeOwnerAndPreservesAnUnexpectedFile() async throws {
        let folder = try privateFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("commands.sock").path
        let first = UserSessionService(path: socket), second = UserSessionService(path: socket)
        defer { first.stop(); second.stop() }
        try first.start { request, _ in .init(id: request.id, epoch: UUID(), revision: 0, ok: true) }
        var info = stat(); XCTAssertEqual(lstat(socket, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertThrowsError(try second.start { request, _ in .init(id: request.id, epoch: UUID(), revision: 0, ok: true) })
        XCTAssertEqual(lstat(socket, &info), 0, "A second server cannot unlink the first server")
        first.stop()
        try Data("unrelated".utf8).write(to: URL(fileURLWithPath: socket))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertThrowsError(try second.start { request, _ in .init(id: request.id, epoch: UUID(), revision: 0, ok: true) })
        XCTAssertEqual(try String(contentsOfFile: socket), "unrelated")
    }
    @MainActor
    func testRealSocketUsesKernelProcessIdentityAndVerifiesTheServerExecutable() async throws {
        let folder = try privateFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("commands.sock").path
        let server = UserSessionService(path: socket); defer { server.stop() }
        let current = try XCTUnwrap(ProcessIdentity.capture(pid: getpid()))
        let epoch = UUID()
        var wrongBuild = false
        try server.start { request, peer in
            XCTAssertEqual(peer.uid, getuid()); XCTAssertTrue(peer.process.matchesLifetime(current))
            var reply = UserSessionReply(id: request.id, epoch: epoch, revision: 7, ok: true)
            if wrongBuild { reply.build += 1 }
            return reply
        }
        let result = try await Task.detached { try UserSessionClient(path: socket, expectedServer: current.executable).snapshot() }.value
        XCTAssertEqual(result.epoch, epoch); XCTAssertEqual(result.revision, 7)
        let denied = await Task.detached { () -> String? in
            do { _ = try UserSessionClient(path: socket, expectedServer: "/not/the/server").snapshot(); return nil }
            catch let failure as UserSessionFailure { return failure.code }
            catch { return "unexpected" }
        }.value
        XCTAssertEqual(denied, "unexpectedServer")
        wrongBuild = true
        let mismatched = await Task.detached { () -> String? in
            do { _ = try UserSessionClient(path: socket, expectedServer: current.executable).snapshot(); return nil }
            catch let failure as UserSessionFailure { return failure.code }
            catch { return "unexpected" }
        }.value
        XCTAssertEqual(mismatched, "unsupportedVersion", "A replaced bundle path alone cannot establish the running app's build")
    }
    @MainActor
    func testRecordingClientRequiresAMatchingReceiptAndFutureDeadlineInsteadOfStatusSuccess() async throws {
        let folder = try privateFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("commands.sock").path
        let service = UserSessionService(path: socket); defer { service.stop() }
        let server = try XCTUnwrap(ProcessIdentity.capture(pid: getpid())?.executable)
        let epoch = UUID()
        var response = "legacyStatus"
        try service.start { request, _ in
            var reply = UserSessionReply(id: request.id, epoch: epoch, revision: 0, ok: true)
            guard request.recording != nil else { return reply }
            if response != "legacyStatus" { reply.recordingID = response == "wrongID" ? UUID() : request.id }
            if response != "missingDeadline" {
                reply.recordingUntil = Date().addingTimeInterval(response == "expiredDeadline" ? -1 : 60)
            }
            return reply
        }
        for scenario in ["legacyStatus", "wrongID", "missingDeadline", "expiredDeadline", "confirmed"] {
            response = scenario
            let result = await Task.detached { () -> String in
                do {
                    _ = try UserSessionClient(path: socket, expectedServer: server)
                        .perform(.status, recording: .start(minutes: 1))
                    return "accepted"
                } catch let failure as UserSessionFailure { return failure.code }
                catch { return "unexpected" }
            }.value
            XCTAssertEqual(result, scenario == "confirmed" ? "accepted" : "recordingUnavailable", scenario)
        }
    }
    private func privateFolder() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("tether-user-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
}
