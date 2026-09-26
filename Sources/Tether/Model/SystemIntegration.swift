import AppKit
import Foundation
import TetherCore

/// Changes outside the app bundle: the login item, the `tether` link and the bundled scripts
/// that run as root. Failures throw a message worth showing; a cancelled password prompt throws
/// `cancelled`.
@MainActor
enum SystemIntegration {
    enum Failure: Error {
        case cancelled
        case message(String)
    }

    // MARK: Login item

    static let launchAgentLabel = "local.tether.app"
    static var launchAgentPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist" }
    static var launchAtLogin: Bool { FileManager.default.fileExists(atPath: launchAgentPath) }

    /// A per-user LaunchAgent works without a Developer ID signature, unlike SMAppService.
    static func setLaunchAtLogin(_ on: Bool) throws {
        let url = URL(fileURLWithPath: launchAgentPath)
        guard on else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [Bundle.main.executablePath ?? "/Applications/Tether.app/Contents/MacOS/Tether"],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
        } catch {
            throw Failure.message(L("Couldn't create the login item: \(error.localizedDescription)",
                                    "로그인 항목을 만들지 못했습니다: \(error.localizedDescription)"))
        }
    }

    // MARK: Terminal command

    /// Per-user `~/.local/bin` needs no password; `/usr/local/bin` is on every PATH but needs one.
    static let userCLIPath = NSHomeDirectory() + "/.local/bin/tether"
    static let systemCLIPath = "/usr/local/bin/tether"
    private static var cliBinaryPath: String { Bundle.main.bundlePath + "/Contents/Helpers/tether" }

    /// Where the `tether` link points into this app, if anywhere.
    static var cliLocation: String? {
        [userCLIPath, systemCLIPath].first { path in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: path))?.hasSuffix("Tether.app/Contents/Helpers/tether") == true
        }
    }

    /// Links `tether` into `~/.local/bin` when that folder exists (it is on PATH for many
    /// developers), otherwise into `/usr/local/bin` with an administrator prompt.
    static func setCLIInstalled(_ on: Bool) throws {
        let fm = FileManager.default
        guard on else {
            if cliLocation == userCLIPath { try? fm.removeItem(atPath: userCLIPath) }
            if cliLocation == systemCLIPath { try runPrivileged(command: "rm -f " + shellQuoted(systemCLIPath)) }
            return
        }
        guard fm.fileExists(atPath: cliBinaryPath) else {
            throw Failure.message(L("The tether command isn't in this app. Run a Tether.app built with scripts/build.sh.",
                                    "앱 안에 tether 명령이 없습니다. build.sh로 만든 Tether.app에서 실행하세요."))
        }
        let userBin = (userCLIPath as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: userBin, isDirectory: &isDirectory), isDirectory.boolValue else {
            try runPrivileged(command: "mkdir -p /usr/local/bin && ln -sf " + shellQuoted(cliBinaryPath) + " " + shellQuoted(systemCLIPath))
            return
        }
        let existing = try? fm.destinationOfSymbolicLink(atPath: userCLIPath)
        if existing == nil, fm.fileExists(atPath: userCLIPath) {
            throw Failure.message(L("\(userCLIPath) already exists and wasn't touched.", "\(userCLIPath) 파일이 이미 있어 건드리지 않았습니다."))
        }
        do {
            if existing != nil { try fm.removeItem(atPath: userCLIPath) }
            try fm.createSymbolicLink(atPath: userCLIPath, withDestinationPath: cliBinaryPath)
        } catch {
            throw Failure.message(L("Couldn't install the command: \(error.localizedDescription)",
                                    "터미널 명령을 설치하지 못했습니다: \(error.localizedDescription)"))
        }
    }

    // MARK: Root

    /// Runs a bundled script as root after the standard administrator password prompt.
    static func runScript(_ name: String) throws {
        guard let path = Bundle.main.path(forResource: name, ofType: nil) else {
            throw Failure.message(L("\(name) is missing. Run a Tether.app built with scripts/build.sh.",
                                    "\(name)을 찾을 수 없습니다. build.sh로 만든 Tether.app에서 실행하세요."))
        }
        try runPrivileged(command: "/bin/sh " + shellQuoted(path))
    }

    private static func runPrivileged(command: String) throws {
        let source = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw Failure.cancelled }
        throw Failure.message((error[NSAppleScript.errorMessage] as? String) ?? L("The helper task failed.", "도우미 작업에 실패했습니다."))
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
