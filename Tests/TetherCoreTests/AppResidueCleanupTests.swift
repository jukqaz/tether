import Darwin
import XCTest
@testable import TetherCore

final class AppResidueCleanupTests: XCTestCase {
    private let appPath = "/Applications/Tether.app/Contents/MacOS/Tether"

    private func fixture(_ body: (URL) throws -> Void) throws {
        // /tmp is itself a symlink on macOS; exercise the real directory chain.
        let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("tether-residue-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    private func leaf(_ relative: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private func plist(arguments: [String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["ProgramArguments": arguments], format: .xml, options: 0)
    }

    private func exists(_ url: URL) -> Bool {
        var entry = stat()
        return lstat(url.path, &entry) == 0
    }

    func testOrphanRetirementRemovesAllInstalledToolsAndDaemonsButPreservesTheSharedLockInode() throws {
        try fixture { folder in
            // Mirror only the installation layout under a temporary root. Never
            // pass the production paths to a filesystem mutation in this test.
            let installed = [
                TetherPaths.helperPath, TetherPaths.watchdogPath,
                TetherPaths.recoveryLockLibraryPath, TetherPaths.recoveryExecutorPath,
                TetherPaths.helperPlistPath, TetherPaths.watchdogPlistPath,
            ]
            for path in installed {
                try Data("installed".utf8).write(to: leaf(String(path.dropFirst()), in: folder))
            }
            let support = folder.appendingPathComponent(String(TetherPaths.supportDirectory.dropFirst()))
            try Data("journal".utf8).write(to: leaf(
                String(TetherPaths.helperStatePath.dropFirst()), in: folder))
            let lockPath = RecoveryLock.path(supportDirectory: TetherPaths.supportDirectory)
            let lock = try leaf(String(lockPath.dropFirst()), in: folder)
            let sentinel = Data("stable recovery lock".utf8)
            try sentinel.write(to: lock)
            var before = stat()
            XCTAssertEqual(lstat(lock.path, &before), 0)

            for path in TetherPaths.orphanedSystemArtifactPaths {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(String(path.dropFirst())))
            }

            for path in installed {
                XCTAssertFalse(exists(folder.appendingPathComponent(String(path.dropFirst()))), path)
            }
            XCTAssertFalse(exists(support))
            XCTAssertEqual(try Data(contentsOf: lock), sentinel)
            var after = stat()
            XCTAssertEqual(lstat(lock.path, &after), 0)
            XCTAssertEqual(after.st_dev, before.st_dev)
            XCTAssertEqual(after.st_ino, before.st_ino)
        }
    }

    func testMatchingCLIAndLoginItemAreRemoved() throws {
        try fixture { folder in
            let cli = try leaf(".local/bin/tether", in: folder)
            let agent = try leaf("Library/LaunchAgents/local.tether.app.plist", in: folder)
            XCTAssertEqual(symlink("/Applications/Tether.app/Contents/Helpers/tether", cli.path), 0)
            try plist(arguments: [appPath, "--login"]).write(to: agent)

            XCTAssertTrue(AppResidueCleanup.removeCLI(at: cli.path))
            XCTAssertTrue(AppResidueCleanup.removeLoginItem(at: agent.path, appPath: appPath))
            XCTAssertFalse(exists(cli))
            XCTAssertFalse(exists(agent))
        }
    }

    func testUnrelatedCLILinkRegularFileAndDirectoryArePreserved() throws {
        for kind in ["link", "file", "directory"] {
            try fixture { folder in
                let cli = try leaf(".local/bin/tether", in: folder)
                switch kind {
                case "link": XCTAssertEqual(symlink("/Applications/Other.app/Contents/Helpers/tether", cli.path), 0)
                case "file": try Data("keep".utf8).write(to: cli)
                default:
                    try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: false)
                    try Data("keep".utf8).write(to: cli.appendingPathComponent("child"))
                }
                XCTAssertFalse(AppResidueCleanup.removeCLI(at: cli.path), kind)
                XCTAssertTrue(exists(cli), kind)
                if kind == "directory" {
                    XCTAssertEqual(try Data(contentsOf: cli.appendingPathComponent("child")), Data("keep".utf8))
                }
            }
        }
    }

    func testLoginItemMustHaveExactFirstProgramArgument() throws {
        for arguments in [["/Applications/Other.app", appPath], [appPath + "-other"], []] {
            try fixture { folder in
                let agent = try leaf("Library/LaunchAgents/local.tether.app.plist", in: folder)
                let original = try plist(arguments: arguments)
                try original.write(to: agent)
                XCTAssertFalse(AppResidueCleanup.removeLoginItem(at: agent.path, appPath: appPath))
                XCTAssertEqual(try Data(contentsOf: agent), original)
            }
        }
    }

    func testUnsafeLoginItemLeavesArePreserved() throws {
        for kind in ["file", "directory", "symlink", "hardlink", "fifo", "oversized"] {
            try fixture { folder in
                let agent = try leaf("Library/LaunchAgents/local.tether.app.plist", in: folder)
                let victim = folder.appendingPathComponent("victim.plist")
                let original = try plist(arguments: [appPath])
                try original.write(to: victim)
                switch kind {
                case "file": try Data("keep".utf8).write(to: agent)
                case "directory":
                    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: false)
                    try original.write(to: agent.appendingPathComponent("child.plist"))
                case "symlink": XCTAssertEqual(symlink(victim.path, agent.path), 0)
                case "hardlink": XCTAssertEqual(link(victim.path, agent.path), 0)
                case "fifo": XCTAssertEqual(mkfifo(agent.path, 0o600), 0)
                default:
                    let large = try PropertyListSerialization.data(fromPropertyList: [
                        "ProgramArguments": [appPath],
                        "Padding": String(repeating: "x", count: AppResidueCleanup.maximumPlistSize)
                    ], format: .xml, options: 0)
                    XCTAssertGreaterThan(large.count, AppResidueCleanup.maximumPlistSize)
                    try large.write(to: agent)
                }
                XCTAssertFalse(AppResidueCleanup.removeLoginItem(at: agent.path, appPath: appPath), kind)
                XCTAssertTrue(exists(agent), kind)
                XCTAssertEqual(try Data(contentsOf: victim), original, kind)
                if kind == "directory" {
                    XCTAssertEqual(try Data(contentsOf: agent.appendingPathComponent("child.plist")), original)
                }
            }
        }
    }

    func testIntermediateSymlinkCannotRedirectEitherCleanup() throws {
        try fixture { folder in
            let external = folder.appendingPathComponent("external", isDirectory: true)
            let cli = try leaf(".local/bin/tether", in: external)
            let agent = try leaf("Library/LaunchAgents/local.tether.app.plist", in: external)
            let original = try plist(arguments: [appPath])
            XCTAssertEqual(symlink("/Applications/Tether.app/Contents/Helpers/tether", cli.path), 0)
            try original.write(to: agent)
            let alias = folder.appendingPathComponent("home-alias")
            XCTAssertEqual(symlink(external.path, alias.path), 0)

            XCTAssertFalse(AppResidueCleanup.removeCLI(at: alias.appendingPathComponent(".local/bin/tether").path))
            XCTAssertFalse(AppResidueCleanup.removeLoginItem(
                at: alias.appendingPathComponent("Library/LaunchAgents/local.tether.app.plist").path, appPath: appPath))
            XCTAssertTrue(exists(cli))
            XCTAssertEqual(try Data(contentsOf: agent), original)
        }
    }

    func testPinnedParentSurvivesRenameAndSymlinkReplacement() throws {
        for isCLI in [true, false] {
            try fixture { folder in
                let name = isCLI ? "tether" : "local.tether.app.plist"
                let current = folder.appendingPathComponent("current", isDirectory: true)
                let originalLeaf = try leaf("current/\(name)", in: folder)
                let externalLeaf = try leaf("external/\(name)", in: folder)
                let original = try plist(arguments: [appPath])
                if isCLI {
                    XCTAssertEqual(symlink("/Applications/Tether.app/Contents/Helpers/tether", originalLeaf.path), 0)
                    XCTAssertEqual(symlink("/Applications/Tether.app/Contents/Helpers/tether", externalLeaf.path), 0)
                } else {
                    try original.write(to: originalLeaf)
                    try original.write(to: externalLeaf)
                }
                let parent = try XCTUnwrap(AppResidueCleanup.openParent(of: originalLeaf.path))
                defer { close(parent.descriptor) }
                let moved = folder.appendingPathComponent("moved", isDirectory: true)
                try FileManager.default.moveItem(at: current, to: moved)
                XCTAssertEqual(symlink(externalLeaf.deletingLastPathComponent().path, current.path), 0)

                if isCLI {
                    XCTAssertTrue(AppResidueCleanup.removeCLI(named: parent.name, from: parent.descriptor))
                } else {
                    XCTAssertTrue(AppResidueCleanup.removeLoginItem(named: parent.name, from: parent.descriptor, appPath: appPath))
                }
                XCTAssertFalse(exists(moved.appendingPathComponent(name)))
                XCTAssertTrue(exists(externalLeaf))
                if !isCLI { XCTAssertEqual(try Data(contentsOf: externalLeaf), original) }
            }
        }
    }

    func testRelativeAndTraversalPathsAreRefused() throws {
        XCTAssertNil(AppResidueCleanup.openParent(of: ".local/bin/tether"))
        XCTAssertNil(AppResidueCleanup.openParent(of: "/private/tmp/../tmp/tether"))
        XCTAssertNil(AppResidueCleanup.openParent(of: "/private/tmp/./tether"))
        XCTAssertNil(AppResidueCleanup.openParent(of: "/private/tmp/tether/"))
    }
}
