import Darwin
import XCTest
@testable import TetherCore

/// Explicit private stub IPC and an owned child only. Never connects to an installed app or power service.
final class V4CLIIntegrationTests: XCTestCase {
    struct Execution { var code: Int32; var output: String; var error: String }
    private func executable() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["TETHER_TEST_CLI_EXECUTABLE"],
              FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Set TETHER_TEST_CLI_EXECUTABLE to the separately built CLI for the private stub integration test")
        }
        return path
    }
    private func status(active: Bool, requestID: UUID?) -> UserSessionStatus {
        var status = UserSessionStatus(power: .ac, thermal: 0, batteryPercent: 80, limits: nil, enabled: true,
            automaticEnabled: false, automaticActive: false, powerCondition: .ac, automaticMinutes: 0,
            batteryHoldUntil: nil, pendingBatteryMinutes: nil, manualActive: active, holding: active, until: nil,
            blockReason: nil, error: nil, canStart: !active, manualBatteryRemaining: 7200, manualEndReason: nil,
            manualMaximumMinutes: 120, canStartBatteryHold: !active, batteryRemaining: 7200)
        status.manualRequestID = requestID; status.manualApprovalPending = false
        return status
    }
    private func execute(_ executable: String, arguments: [String], socket: String, server: String) async throws -> Execution {
        try await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["TETHER_USER_SESSION_SOCKET"] = socket
            environment["TETHER_USER_SESSION_SERVER_EXECUTABLE"] = server
            process.environment = environment
            let output = Pipe(), error = Pipe(); process.standardOutput = output; process.standardError = error
            try process.run(); process.waitUntilExit()
            return Execution(code: process.terminationStatus,
                output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                error: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }.value
    }
    @MainActor
    func testRunDefersUserCodeUntilApprovedAndReturnsActualExitStatus() async throws {
        let cli = try executable()
        let directory = URL(fileURLWithPath: "/private/tmp/tv4r-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let socket = directory.appendingPathComponent("s").path
        let marker = directory.appendingPathComponent("executed").path
        let service = UserSessionService(path: socket)
        defer { service.stop(); try? FileManager.default.removeItem(at: directory) }
        let server = try XCTUnwrap(ProcessIdentity.capture(pid: getpid())?.executable)
        let requestID = UUID(), epoch = UUID()
        var approved = false, sawManual = false, sawPrematureEnd = false
        try service.start { request, _ in
            if case .manual = request.command {
                sawManual = true
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "No user command may execute before approval")
                let binding = request.manualPID
                let observed = binding.flatMap { ProcessIdentity.capture(pid: $0.pid) }
                XCTAssertEqual(observed?.started, binding?.startIdentity)
                XCTAssertEqual(observed?.executable, binding?.executableIdentity)
                XCTAssertEqual(observed?.uid, geteuid())
                approved = true
            }
            if request.command == .endManual { sawPrematureEnd = true }
            var reply = UserSessionReply(id: request.id, epoch: epoch, revision: 0, ok: true,
                                         status: self.status(active: approved, requestID: approved ? requestID : nil))
            reply.workScope = V4Fixture.scope
            return reply
        }
        let result = try await execute(cli, arguments: ["run", "--minutes", "30", "--", "/bin/sh", "-c", "printf executed > \"$1\"; exit 7", "tether-test", marker], socket: socket, server: server)
        XCTAssertTrue(sawManual); XCTAssertFalse(sawPrematureEnd)
        XCTAssertEqual(result.code, 7, result.error)
        XCTAssertEqual(try String(contentsOfFile: marker), "executed")
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertFalse(result.error.contains(marker), "Never log the command's arguments")
    }
    @MainActor
    func testDeniedRunCleansOnlyUnstartedOwnedChild() async throws {
        let cli = try executable()
        let directory = URL(fileURLWithPath: "/private/tmp/tv4d-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let socket = directory.appendingPathComponent("s").path
        let marker = directory.appendingPathComponent("must-not-exist").path
        let service = UserSessionService(path: socket)
        defer { service.stop(); try? FileManager.default.removeItem(at: directory) }
        let server = try XCTUnwrap(ProcessIdentity.capture(pid: getpid())?.executable)
        var child: Int32?
        try service.start { request, _ in
            child = request.manualPID?.pid ?? child
            var reply = UserSessionReply(id: request.id, epoch: UUID(), revision: 0,
                ok: request.manualPID == nil, error: request.manualPID == nil ? nil : "safetyBlocked",
                status: self.status(active: false, requestID: nil))
            reply.workScope = V4Fixture.scope
            return reply
        }
        let result = try await execute(cli, arguments: ["run", "--minutes", "30", "--", "/bin/sh", "-c", "printf bad > \"$1\"", "tether-test", marker], socket: socket, server: server)
        XCTAssertNotEqual(result.code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        let pid = try XCTUnwrap(child)
        XCTAssertTrue(ProcessIdentity.exited(pid: pid), "Owned suspended child must be killed and reaped after denied admission")
    }
}
