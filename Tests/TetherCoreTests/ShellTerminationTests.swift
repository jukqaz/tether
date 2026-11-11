import Darwin
import XCTest
@testable import TetherCore

final class ShellTerminationTests: XCTestCase {
    func testTerminatingCooperativeDirectProcessIsObservedBeforeReturning() {
        let result = Shell.run("/bin/sleep", ["10"], timeout: 0.05)
        XCTAssertEqual(result.status, 124)
        XCTAssertTrue(result.timedOut); XCTAssertTrue(result.terminationConfirmed)
        XCTAssertNotNil(result.exitStatus)
        XCTAssertTrue(ProcessIdentity.exited(pid: result.processID!))
    }

    func testNoLateFileWriteAfterIgnoringTermAndBeingKilled() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("late-write")
        // Direct process, no spawned shell or child. Only a temporary file is affected.
        let writer = "$SIG{TERM}='IGNORE'; $|=1; print 'ready'; select undef,undef,undef,1; open(my $f,'>', $ARGV[0]) or die $!; print $f 'late';"
        let result = Shell.run("/usr/bin/perl", ["-e", writer, output.path], timeout: 0.1)
        XCTAssertTrue(result.output.hasPrefix("ready"), result.output)
        XCTAssertEqual(result.status, 124); XCTAssertEqual(result.exitStatus, SIGKILL)
        XCTAssertTrue(result.terminationConfirmed)
        XCTAssertTrue(ProcessIdentity.exited(pid: result.processID!))
        usleep(1_100_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "A terminated writer must not apply a late write")
    }

    func testClosedOutputPipeDoesNotMistakeLiveProcessForExit() {
        let result = Shell.run("/bin/sh", ["-c", "exec 1>&- 2>&-; trap '' TERM; while :; do :; done"], timeout: 0.05)
        XCTAssertEqual(result.status, 124); XCTAssertEqual(result.exitStatus, SIGKILL)
        XCTAssertTrue(result.terminationConfirmed)
        XCTAssertTrue(ProcessIdentity.exited(pid: result.processID!))
    }

    func testInvalidDeadlineDoesNotLaunchTheCommand() {
        for timeout in [Double.nan, .infinity, -.infinity] {
            let result = Shell.run("/usr/bin/printf", ["should-not-run"], timeout: timeout)
            XCTAssertEqual(result.status, -1); XCTAssertNil(result.processID)
            XCTAssertFalse(result.timedOut); XCTAssertTrue(result.terminationConfirmed)
            XCTAssertEqual(result.output, "Invalid command timeout")
        }
    }

    func testLaunchFailureHasNoUnconfirmedWriter() {
        let result = Shell.run("/nonexistent/tether-test-command", [])
        XCTAssertEqual(result.status, -1); XCTAssertNil(result.processID)
        XCTAssertNil(result.exitStatus); XCTAssertTrue(result.terminationConfirmed)
        XCTAssertFalse(result.timedOut)
    }

    func testParallelTimeoutsHaveIndependentTerminationObservations() async {
        let results = await withTaskGroup(of: Shell.Result.self) { group in
            for _ in 0..<8 {
                group.addTask { Shell.run("/bin/sleep", ["10"], timeout: 0.05) }
            }
            var values = [Shell.Result]()
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(Set(results.compactMap(\.processID)).count, 8)
        for result in results {
            XCTAssertEqual(result.status, 124); XCTAssertTrue(result.terminationConfirmed)
            XCTAssertTrue(ProcessIdentity.exited(pid: result.processID!))
        }
    }
}
