import XCTest
@testable import TetherCore

final class DiagnosticRecordingTests: XCTestCase {
    func testRecordingStopsAtDeadlineAndSurvivesDecode() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var control = Control(enabled: false)
        control.debugLog = true; control.debugLogUntil = DiagnosticRecording.deadline(minutes: 15, now: now)
        let restored = try JSONDecoder().decode(Control.self, from: JSONEncoder().encode(control))
        XCTAssertEqual(restored.debugLogUntil, 1900)
        XCTAssertFalse(restored.enabled, "Recording must not enable power management")
        XCTAssertTrue(DiagnosticRecording.isActive(enabled: restored.debugLog, until: restored.debugLogUntil, now: now))
        XCTAssertFalse(DiagnosticRecording.isActive(enabled: true, until: 1900, now: Date(timeIntervalSince1970: 1900)))
        XCTAssertFalse(DiagnosticRecording.isActive(enabled: false, until: 1900, now: now))
        XCTAssertFalse(DiagnosticRecording.isActive(enabled: true, until: .infinity, now: now))
        control.debugLogUntil = .nan
        XCTAssertFalse(control.isSupported)
    }

    func testLegacyChoicePreservedAndNewDurationsBounded() throws {
        let old = try JSONDecoder().decode(Control.self, from: Data(#"{"enabled":false,"debugLog":true}"#.utf8))
        XCTAssertTrue(old.debugLoggingActive)
        XCTAssertNil(old.debugLogUntil)
        XCTAssertEqual(DiagnosticRecording.deadline(minutes: Int.max, now: Date(timeIntervalSince1970: 0)), 14400)
        for input in [Double.nan, .infinity, -.infinity, 0, -1] { XCTAssertEqual(DiagnosticRecording.reportHours(input), 24) }
        XCTAssertEqual(DiagnosticRecording.reportHours(1000), 72)
    }

    func testReportNeverIncludesAssertionPayloadAndDistinguishesFailure() {
        let requests = [SleepBlocker(pid: 4, process: "Example LLM", kind: .system, reason: "secret prompt token=example")]
        let hidden = Diagnostics.assertionSummary(requests, includeProcessNames: false)
        XCTAssertFalse(hidden.contains("Example LLM")); XCTAssertFalse(hidden.contains("secret prompt"))
        XCTAssertTrue(hidden.contains("system")); XCTAssertTrue(hidden.contains("Process 1"))
        let named = Diagnostics.assertionSummary(requests, includeProcessNames: true)
        XCTAssertTrue(named.contains("Example LLM")); XCTAssertFalse(named.contains("token="))
        XCTAssertTrue(Diagnostics.assertionSummary(nil, includeProcessNames: false).contains("failed"))
        XCTAssertTrue(Diagnostics.assertionSummary([], includeProcessNames: false).contains("None"))
        XCTAssertFalse(Diagnostics.redact("url tether://hold?minutes=30&token=secret").contains("token="))
    }
}

final class LogArchiveTests: XCTestCase {
    private var folder: URL!
    private var path: String { folder.appendingPathComponent("helper.log").path }
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tether-logs-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testRotationPreservesActiveInodeAndThreePreviousFiles() throws {
        let fd = open(path, O_RDWR | O_CREAT | O_APPEND, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        var initial = stat(); XCTAssertEqual(fstat(fd, &initial), 0)
        for number in 1...5 {
            let text = String(repeating: "x", count: 40) + "\n2026-09-28 12:00:00 event-\(number)\n"
            _ = text.withCString { Darwin.write(fd, $0, strlen($0)) }
            XCTAssertEqual(LogArchive.rotate(descriptor: fd, path: path, limit: 40), .rotated)
            var current = stat(); XCTAssertEqual(stat(path, &current), 0)
            XCTAssertEqual(initial.st_ino, current.st_ino)
        }
        let final = "2026-09-28 12:00:01 current\n"
        _ = final.withCString { Darwin.write(fd, $0, strlen($0)) }
        let all = LogArchive.read(path: path)
        XCTAssertTrue(all.contains("current"))
        for number in 3...5 { XCTAssertTrue(all.contains("event-\(number)")) }
        for number in 1...2 { XCTAssertFalse(all.contains("event-\(number)")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".4"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 4)
    }

    func testArchiveFailureDoesNotClearActiveLog() throws {
        let original = "one\ntwo\nthree\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: path + ".1", withIntermediateDirectories: false)
        let fd = open(path, O_WRONLY | O_APPEND); defer { close(fd) }
        XCTAssertEqual(LogArchive.rotate(descriptor: fd, path: path, limit: 8), .failed)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), original)
    }

    func testLinksAndUnrelatedDescriptorCannotBeArchivedOrRead() throws {
        let victim = folder.appendingPathComponent("victim").path
        try "do not touch\n".write(toFile: victim, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: victim)
        let fd = open(victim, O_WRONLY); defer { close(fd) }
        XCTAssertEqual(LogArchive.rotate(descriptor: fd, path: path, limit: 4), .failed)
        XCTAssertEqual(LogArchive.read(path: path), "")
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "do not touch\n")
    }

    func testReportReadsArchivedMarkersAndDisclosesLimit() throws {
        let old = "2026-09-28 12:00:00 diagnostic marker abc\n"
        try old.write(toFile: path + ".1", atomically: true, encoding: .utf8)
        try "2026-09-28 12:01:00 current\n".write(toFile: path, atomically: true, encoding: .utf8)
        let lines = Diagnostics.helperLog(since: Date(timeIntervalSince1970: 0), path: path).joined(separator: "\n")
        XCTAssertTrue(lines.contains("diagnostic marker abc")); XCTAssertTrue(lines.contains("current"))
        XCTAssertTrue(lines.contains("latest 2 of 2"))
    }
}
