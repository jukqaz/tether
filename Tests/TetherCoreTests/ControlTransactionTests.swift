import XCTest
@testable import TetherCore

final class ControlTransactionTests: XCTestCase {
    private var folder: URL!
    private var path: String { folder.appendingPathComponent("control.json").path }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("control-transaction-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testConcurrentClientsKeepEveryChangeAndSafetySetting() throws {
        let original = Control(enabled: false, limits: UserLimits(batteryFloor: 50))
        XCTAssertTrue(JSONFile.write(original, to: path, permissions: 0o664))
        let target = path
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            for _ in 0..<12 {
                XCTAssertTrue(ControlStore.update(path: target) {
                    let count = $0.sleepNowRequest ?? 0
                    usleep(1_000) // expose the old read/modify/write lost-update window
                    $0.sleepNowRequest = count + 1
                })
            }
        }
        let control = try XCTUnwrap(JSONFile.read(Control.self, from: path))
        XCTAssertEqual(control.sleepNowRequest, 48)
        XCTAssertFalse(control.enabled)
        XCTAssertEqual(control.limits, original.limits)
    }

    func testMalformedControlIsNotReplacedWithDefaults() throws {
        for text in ["", "{", "{\"enabled\":\"no\"}"] {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            var called = false
            XCTAssertFalse(ControlStore.update(path: path) { _ in called = true })
            XCTAssertFalse(called)
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), text)
        }
    }

    func testTransactionPreservesInodeOwnerAndMode() throws {
        XCTAssertTrue(JSONFile.write(Control(enabled: false), to: path, permissions: 0o664))
        var before = stat()
        XCTAssertEqual(stat(path, &before), 0)
        XCTAssertTrue(ControlStore.update(path: path) { $0.debugLog = true })
        var after = stat()
        XCTAssertEqual(stat(path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_uid, before.st_uid)
        XCTAssertEqual(after.st_gid, before.st_gid)
        XCTAssertEqual(after.st_mode, before.st_mode)
    }

    func testTransactionRefusesLinksWithoutChangingTarget() throws {
        let victim = folder.appendingPathComponent("victim.json").path
        XCTAssertTrue(JSONFile.write(Control(enabled: false), to: victim, permissions: 0o664))
        let before = try Data(contentsOf: URL(fileURLWithPath: victim))
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: victim)
        XCTAssertFalse(ControlStore.update(path: path) { $0.enabled = true })
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.linkItem(atPath: victim, toPath: path)
        XCTAssertFalse(ControlStore.update(path: path) { $0.enabled = true })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: victim)), before)
    }

    func testBusyFileFailsWithinBoundWithoutCallingMutation() throws {
        XCTAssertTrue(JSONFile.write(Control(enabled: false), to: path, permissions: 0o664))
        let fd = open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        var called = false
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertFalse(ControlStore.update(path: path) { _ in called = true })
        XCTAssertFalse(called)
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 2_000_000_000)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertFalse(try XCTUnwrap(JSONFile.read(Control.self, from: path)).enabled)
    }

    func testReaderWaitsOutTruncationInsteadOfReadingDefaults() throws {
        XCTAssertTrue(JSONFile.write(Control(enabled: false), to: path, permissions: 0o664))
        let fd = open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(ftruncate(fd, 0), 0)
        let target = path
        let started = DispatchSemaphore(value: 0)
        let finished = expectation(description: "reader sees completed write")
        DispatchQueue.global().async {
            started.signal()
            XCTAssertEqual(JSONFile.read(Control.self, from: target)?.enabled, false)
            finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        usleep(20_000)
        let data = Data("{\"enabled\":false}".utf8)
        XCTAssertEqual(data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, data.count)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        wait(for: [finished], timeout: 2)
    }

    func testWatchRetainsLastGoodSettingsAndRetriesBusyFile() throws {
        XCTAssertTrue(JSONFile.write(Control(enabled: false), to: path, permissions: 0o664))
        let watch = JSONWatch(Control.self, path: path)
        XCTAssertTrue(watch.reload())
        XCTAssertTrue(ControlStore.update(path: path) { $0.debugLog = true })
        let fd = open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertFalse(watch.reload())
        XCTAssertEqual(watch.value?.enabled, false)
        XCTAssertNil(watch.value?.debugLog)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertTrue(watch.reload(), "retry even though mtime did not change after the busy read")
        XCTAssertEqual(watch.value?.debugLog, true)
    }

    func testWatchKeepsLastGoodValueOnMalformedFileAndRecovers() throws {
        XCTAssertTrue(JSONFile.write(Control(enabled: false), to: path, permissions: 0o664))
        let watch = JSONWatch(Control.self, path: path)
        XCTAssertTrue(watch.reload())
        try Data("{".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertFalse(watch.reload())
        XCTAssertEqual(watch.value?.enabled, false)
        XCTAssertTrue(JSONFile.overwrite(Control(enabled: true), at: path))
        XCTAssertTrue(watch.reload())
        XCTAssertEqual(watch.value?.enabled, true)
    }

    func testOversizedUpdateLeavesExistingSettingsUntouched() throws {
        XCTAssertTrue(JSONFile.write(Control(enabled: false), to: path, permissions: 0o664))
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertFalse(ControlStore.update(path: path) { $0.appPath = String(repeating: "x", count: JSONFile.maxSize) })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }
}
