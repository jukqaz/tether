import Darwin
import Foundation
import XCTest
@testable import TetherCore

private final class DiskExtrasClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 100
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return time }
    func set(_ value: Double) { lock.lock(); time = value; lock.unlock() }
}

private final class DiskExtrasBackend: DiskKeepAwakeBackend, @unchecked Sendable {
    var supportsAutomaticCleanup: Bool { true }
    var opens = 0, pulses = 0, closes = 0
    var pulseError: DiskKeepAwakeError?, closeError: DiskKeepAwakeError?
    func open(directory: URL, id: UUID) throws -> UUID { opens += 1; return id }
    func pulse(_ handle: UUID) throws { pulses += 1; if let pulseError { throw pulseError } }
    func close(_ handle: UUID) throws { closes += 1; if let closeError { throw closeError } }
}

final class DiskExtrasTests: XCTestCase {
    private func directory() throws -> URL {
        // Use a physical parent: the backend deliberately refuses symlinks in every
        // path component, including the host's /var or /tmp temporary aliases.
        let value = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("tether-disk-extras-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return value
    }
    func testSettingsImportIsDisabledAndUnsafeRootsAreUnavailable() throws {
        XCTAssertFalse(DiskKeepAwakeSettings().enabled)
        let config = DiskKeepAwakeSettings(enabled: true, directory: URL(fileURLWithPath: "/Volumes/Selected/Folder"))
        XCTAssertFalse(config.normalizedForImport().enabled)
        XCTAssertEqual(try JSONDecoder().decode(DiskKeepAwakeSettings.self, from: JSONEncoder().encode(config)), config)
        for path in ["/", "/Users", "/Volumes", "/System/Library", "/usr/bin", "/private/etc", "/Library"] {
            XCTAssertFalse(NativeDiskKeepAwakeBackend.isAllowedSelection(URL(fileURLWithPath: path)), path)
        }
        XCTAssertFalse(DiskKeepAwakeSettings(enabled: true, directory: URL(string: "https://example.com")!).isValid)
        XCTAssertFalse(DiskKeepAwakeSettings(interval: .nan).isValid)
        XCTAssertFalse(DiskKeepAwakeSettings(maximumDuration: 7201).isValid)
    }
    func testPulseIntervalsAndFiniteDeadlineNeverRestartOnDuplicateStart() async {
        let clock = DiskExtrasClock(), backend = DiskExtrasBackend()
        let driver = DiskKeepAwakeDriver(backend: backend, automaticScheduling: false, clock: { clock.now() })
        let config = DiskKeepAwakeSettings(enabled: true, directory: URL(fileURLWithPath: "/Volumes/Selected"), interval: 15, maximumDuration: 60)
        let start = await driver.start(settings: config, until: 1000)
        XCTAssertEqual(start, .running(deadline: 160)); XCTAssertEqual(backend.pulses, 1)
        clock.set(110)
        let repeated = await driver.start(settings: config, until: 2000)
        XCTAssertEqual(repeated, .running(deadline: 160)); XCTAssertEqual(backend.opens, 1)
        let renewed = await driver.authorize(until: 135)
        XCTAssertTrue(renewed)
        _ = await driver.tick(); XCTAssertEqual(backend.pulses, 1)
        clock.set(115); _ = await driver.tick(); XCTAssertEqual(backend.pulses, 2)
        clock.set(160)
        let expired = await driver.tick()
        XCTAssertEqual(expired, .stopped); XCTAssertEqual(backend.closes, 1)
    }
    func testFreshAuthorizationExpiresAndCannotReviveAnEndedRun() async {
        let clock = DiskExtrasClock(), backend = DiskExtrasBackend()
        let driver = DiskKeepAwakeDriver(backend: backend, automaticScheduling: false, clock: { clock.now() })
        _ = await driver.start(settings: .init(enabled: true, directory: URL(fileURLWithPath: "/Volumes/Selected")), until: 7200)
        clock.set(115)
        let expired = await driver.tick()
        XCTAssertEqual(expired, .failed(.authorizationExpired)); XCTAssertEqual(backend.closes, 1)
        let revived = await driver.authorize(until: 130)
        XCTAssertFalse(revived); XCTAssertEqual(backend.opens, 1)
        XCTAssertEqual(backend.pulses, 1)
    }
    func testFreshAuthorizationRenewalDoesNotRefillTheOriginalBudget() async {
        let clock = DiskExtrasClock(), backend = DiskExtrasBackend()
        let driver = DiskKeepAwakeDriver(backend: backend, automaticScheduling: false, clock: { clock.now() })
        let config = DiskKeepAwakeSettings(enabled: true, directory: URL(fileURLWithPath: "/Volumes/Selected"), interval: 15, maximumDuration: 45)
        _ = await driver.start(settings: config, until: 1000)
        for now in [110.0, 120, 130, 140] {
            clock.set(now)
            let renewed = await driver.authorize(until: now + 15)
            XCTAssertTrue(renewed)
            let state = await driver.tick()
            XCTAssertEqual(state, .running(deadline: 145))
        }
        clock.set(145)
        let state = await driver.tick()
        XCTAssertEqual(state, .stopped); XCTAssertEqual(backend.opens, 1)
    }
    func testUnmountWriteFailureAndBackwardClockStopWithoutAutomaticRetry() async {
        for failure in [DiskKeepAwakeError.directoryUnavailable, .writeFailed, .syncFailed] {
            let clock = DiskExtrasClock(), backend = DiskExtrasBackend()
            backend.pulseError = failure
            let driver = DiskKeepAwakeDriver(backend: backend, automaticScheduling: false, clock: { clock.now() })
            let config = DiskKeepAwakeSettings(enabled: true, directory: URL(fileURLWithPath: "/Volumes/Selected"))
            let failed = await driver.start(settings: config, until: 200)
            XCTAssertEqual(failed, .failed(failure)); XCTAssertEqual(backend.closes, 1)
            clock.set(150); _ = await driver.tick()
            XCTAssertEqual(backend.pulses, 1)
        }
        let clock = DiskExtrasClock(), backend = DiskExtrasBackend()
        let driver = DiskKeepAwakeDriver(backend: backend, automaticScheduling: false, clock: { clock.now() })
        _ = await driver.start(settings: .init(enabled: true, directory: URL(fileURLWithPath: "/Volumes/Selected")), until: 200)
        clock.set(99)
        let result = await driver.tick()
        XCTAssertEqual(result, .failed(.invalidSelection)); XCTAssertEqual(backend.closes, 1)
    }
    func testCleanupFailureRetainsDebtAndBlocksNewFileUntilExplicitStopSucceeds() async {
        let backend = DiskExtrasBackend(), driver = DiskKeepAwakeDriver(backend: backend, automaticScheduling: false, clock: { 100 })
        let config = DiskKeepAwakeSettings(enabled: true, directory: URL(fileURLWithPath: "/Volumes/Selected"))
        _ = await driver.start(settings: config, until: 200)
        backend.closeError = .cleanupPending
        let pending = await driver.stop()
        XCTAssertEqual(pending, .cleanupPending)
        let rejected = await driver.start(settings: config, until: 300)
        XCTAssertEqual(rejected, .cleanupPending); XCTAssertEqual(backend.opens, 1)
        backend.closeError = nil
        let stopped = await driver.stop()
        XCTAssertEqual(stopped, .stopped)
    }
    func testNativeBackendWritesOnlyItsExclusiveFileAndNeverClaimsPathCleanup() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("user-file.txt"), bytes = Data("original".utf8)
        try bytes.write(to: original)
        let backend = NativeDiskKeepAwakeBackend(), id = UUID()
        let handle = try backend.open(directory: folder, id: id)
        let owned = folder.appendingPathComponent(".tether-owned-" + id.uuidString.lowercased())
        try backend.pulse(handle); try backend.pulse(handle)
        XCTAssertEqual(try Data(contentsOf: owned).count, 4096)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertThrowsError(try backend.close(handle)) { XCTAssertEqual($0 as? DiskKeepAwakeError, .cleanupPending) }
        XCTAssertThrowsError(try backend.close(handle))
        XCTAssertThrowsError(try backend.pulse(handle))
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
    func testSymlinkDirectoryAndPreexistingFileAreNeverFollowedOrOverwritten() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let actual = folder.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        let alias = folder.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let backend = NativeDiskKeepAwakeBackend()
        XCTAssertThrowsError(try backend.open(directory: alias, id: UUID()))
        let id = UUID(), existing = folder.appendingPathComponent(".tether-owned-" + id.uuidString.lowercased())
        let bytes = Data("not ours".utf8); try bytes.write(to: existing)
        XCTAssertThrowsError(try backend.open(directory: folder, id: id))
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
    }
    func testNameReplacementWithSymlinkCannotWriteOrRemoveUserFile() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let backend = NativeDiskKeepAwakeBackend(), id = UUID()
        let handle = try backend.open(directory: folder, id: id)
        let owned = folder.appendingPathComponent(".tether-owned-" + id.uuidString.lowercased())
        let moved = folder.appendingPathComponent("moved-owned")
        try FileManager.default.moveItem(at: owned, to: moved)
        let user = folder.appendingPathComponent("user-file"), bytes = Data("preserve".utf8)
        try bytes.write(to: user)
        try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: user)
        XCTAssertThrowsError(try backend.pulse(handle))
        XCTAssertThrowsError(try backend.close(handle))
        XCTAssertEqual(try Data(contentsOf: user), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: owned.path), user.path)
        try FileManager.default.removeItem(at: owned)
        XCTAssertThrowsError(try backend.close(handle))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }
    func testProductionDriverDoesNotCreateFilesWithUnsupportedNativeCleanup() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let backend = NativeDiskKeepAwakeBackend()
        XCTAssertFalse(backend.supportsAutomaticCleanup)
        let driver = DiskKeepAwakeDriver(backend: backend, automaticScheduling: false, clock: { 100 })
        let result = await driver.start(settings: .init(enabled: true, directory: folder), until: 200)
        XCTAssertEqual(result, .failed(.unsupported))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
}
