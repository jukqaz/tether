import Darwin
import XCTest
@testable import TetherCore

/// Explicit private stub IPC only. Never connects to an installed app or power service.
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
    func testRemovedRunRejectsWithoutStartingUserCodeOrRequestingASession() async throws {
        let cli = try executable()
        let directory = URL(fileURLWithPath: "/private/tmp/tv4r-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let socket = directory.appendingPathComponent("s").path
        let marker = directory.appendingPathComponent("executed").path
        let service = UserSessionService(path: socket)
        defer { service.stop(); try? FileManager.default.removeItem(at: directory) }
        let server = try XCTUnwrap(ProcessIdentity.capture(pid: getpid())?.executable)
        var requests = 0
        try service.start { request, _ in
            requests += 1
            var reply = UserSessionReply(id: request.id, epoch: UUID(), revision: 0, ok: true,
                                         status: self.status(active: true, requestID: UUID()))
            reply.workScope = V4Fixture.scope
            return reply
        }
        for options in [["--minutes", "30"], ["--unlimited"], ["--help"]] {
            let result = try await execute(cli,
                arguments: ["run"] + options + ["--", "/bin/sh", "-c", "printf executed > \"$1\"; exit 7", "tether-test", marker],
                socket: socket, server: server)
            XCTAssertEqual(result.code, 2, result.error)
            XCTAssertTrue(result.output.isEmpty)
            XCTAssertTrue(result.error.contains("tether manual 30m"), result.error)
            XCTAssertFalse(result.error.contains(marker), "Never log the removed command's arguments")
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "A removed command must never execute the workload")
        }
        XCTAssertEqual(requests, 0, "Rejection precedes even a read-only IPC snapshot")
    }
    @MainActor
    func testRemovedManualPIDRejectsWithoutFallingBackToAnOrdinaryTimer() async throws {
        let cli = try executable()
        let directory = URL(fileURLWithPath: "/private/tmp/tv4d-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let socket = directory.appendingPathComponent("s").path
        let service = UserSessionService(path: socket)
        defer { service.stop(); try? FileManager.default.removeItem(at: directory) }
        let server = try XCTUnwrap(ProcessIdentity.capture(pid: getpid())?.executable)
        var requests = 0
        try service.start { request, _ in
            requests += 1
            var reply = UserSessionReply(id: request.id, epoch: UUID(), revision: 0, ok: true,
                status: self.status(active: true, requestID: UUID()))
            reply.workScope = V4Fixture.scope
            return reply
        }
        for arguments in [
            ["manual", "30m", "--pid", String(getpid()), "--json"],
            ["manual", "unlimited", "--pid", String(getpid())],
            ["manual", "30m", "--pid"],
            ["manual", "30m", "--pid", "0", "--help"]
        ] {
            let result = try await execute(cli, arguments: arguments, socket: socket, server: server)
            XCTAssertEqual(result.code, 2, result.error)
            XCTAssertTrue(result.output.isEmpty)
            XCTAssertTrue(result.error.contains("tether manual 30m"), result.error)
        }
        XCTAssertEqual(requests, 0, "Do not silently strip --pid and start a normal timer")
    }

    @MainActor
    func testHelpRemovesProcessBoundCommandsAndPreservesTaskAndDiagnosticCommands() async throws {
        let cli = try executable()
        let result = try await execute(cli, arguments: ["--help"], socket: "/private/tmp/tether-removed-command-unused.sock", server: "/unused")
        XCTAssertEqual(result.code, 0, result.error)
        XCTAssertTrue(result.error.isEmpty)
        XCTAssertFalse(result.output.contains("tether run"))
        XCTAssertFalse(result.output.contains("--pid"))
        for command in ["tether manual", "tether auto", "tether task begin", "tether displays", "tether doctor", "tether diagnose"] {
            XCTAssertTrue(result.output.contains(command), command)
        }
    }
}
