import Foundation
import TetherCore

/// Read-only, terminating installer preflight; never initializes a helper or
/// creates a service. Root always probes the actual Mac, ignoring fixture data.
enum HelperInstallProbe {
    private struct Facts: Decodable {
        let supportedPlatform: Bool
        let internalBattery: Bool?
        let lid: Bool?
    }

    static var target: MacCapabilities.HelperInstallTarget {
        guard geteuid() != 0,
              let path = ProcessInfo.processInfo.environment["TETHER_INSTALL_TEST_ROOT"] else {
            return SystemProbe.capabilities.helperInstallTarget
        }
        // The installer already permits OS-command mocks only in non-root /tmp
        // fixtures. Keep hardware facts within that same private fixture boundary.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().path
        var info = stat()
        guard (parent == "/tmp" || parent == "/private/tmp"),
              url.lastPathComponent.hasPrefix("tether-install-test-"),
              lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700,
              let data = JSONFile.readBytes(from: url.appendingPathComponent("install-target-facts.json").path,
                                            expectedOwner: geteuid(), expectedPermissions: 0o600),
              let facts = try? JSONDecoder().decode(Facts.self, from: data) else { return .unavailable }
        return MacCapabilities(supportedPlatform: facts.supportedPlatform,
                               internalBattery: facts.internalBattery, lid: facts.lid).helperInstallTarget
    }
}
