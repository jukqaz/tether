import XCTest
@testable import Tether

private final class LoginItemRemovalFailureFixture: FileManager, @unchecked Sendable {
    private(set) var attemptedURLs: [URL] = []

    override func removeItem(at URL: URL) throws {
        attemptedURLs.append(URL)
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
}

final class LoginItemRemovalTests: XCTestCase {
    @MainActor
    private func fixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tether-login-item-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @MainActor
    func testSuccessfulRemovalDeletesOnlyTheRequestedLoginItem() throws {
        try fixture { directory in
            let item = directory.appendingPathComponent("local.tether.app.plist")
            let other = directory.appendingPathComponent("another-app.plist")
            let retained = Data("another application's login item".utf8)
            try Data("Tether login item".utf8).write(to: item)
            try retained.write(to: other)

            try SystemIntegration.removeLoginItem(at: item)

            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
            XCTAssertEqual(try Data(contentsOf: other), retained)
        }
    }

    @MainActor
    func testAnAlreadyMissingLoginItemIsAnIdempotentSuccess() throws {
        try fixture { directory in
            let item = directory.appendingPathComponent("local.tether.app.plist")

            XCTAssertNoThrow(try SystemIntegration.removeLoginItem(at: item))
            XCTAssertNoThrow(try SystemIntegration.removeLoginItem(at: item))

            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
        }
    }

    @MainActor
    func testRemovalFailureReachesTheCallerAndPreservesTheItem() throws {
        try fixture { directory in
            let item = directory.appendingPathComponent("local.tether.app.plist")
            let original = Data("Tether login item".utf8)
            try original.write(to: item)
            let fileManager = LoginItemRemovalFailureFixture()

            XCTAssertThrowsError(try SystemIntegration.removeLoginItem(at: item, fileManager: fileManager)) { error in
                guard case SystemIntegration.Failure.message(let message) = error else {
                    XCTFail("Unexpected removal failure: \(error)")
                    return
                }
                XCTAssertFalse(message.isEmpty)
            }

            XCTAssertEqual(fileManager.attemptedURLs, [item])
            XCTAssertEqual(try Data(contentsOf: item), original)
        }
    }
}
