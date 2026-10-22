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
    /// It relaunches the app after an abnormal exit; a normal Quit remains a quit.
    private static var loginItem: [String: Any] {
        [
            "Label": launchAgentLabel,
            "ProgramArguments": [Bundle.main.executablePath ?? "/Applications/Tether.app/Contents/MacOS/Tether"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
        ]
    }

    static func setLaunchAtLogin(_ on: Bool) throws {
        let url = URL(fileURLWithPath: launchAgentPath)
        guard on else {
            try removeLoginItem(at: url)
            return
        }
        let plist = loginItem
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
        } catch {
            throw Failure.message(L("Couldn't create the login item: \(error.localizedDescription)",
                                    "로그인 항목을 만들지 못했습니다: \(error.localizedDescription)"))
        }
    }

    /// A missing item is already disabled; any other removal failure must reach
    /// the caller before it reports success or continues removing the app.
    static func removeLoginItem(at url: URL, fileManager: FileManager = .default) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch let error as NSError {
            guard error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError else {
                throw Failure.message(L("Couldn't remove the login item: \(error.localizedDescription)",
                                        "로그인 항목을 제거하지 못했습니다: \(error.localizedDescription)"))
            }
        }
    }

    /// Rewrites a login item from an older version, or one pointing at an app that moved; the
    /// change applies from the next login.
    static func updateLoginItemIfNeeded() {
        let current = NSDictionary(contentsOfFile: launchAgentPath)
        guard current != NSDictionary(dictionary: loginItem) else { return }
        try? setLaunchAtLogin(true)
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

    static func missingHelperFiles(fileManager: FileManager = .default) -> [HelperInstallationFile] {
        HealthChecks.missingHelperFiles(fileManager: fileManager)
    }

    /// Only helper installation uses this asynchronous authorization path. The
    /// password dialog belongs to macOS; waiting for it never occupies the UI actor.
    static func installHelper() async throws {
        guard let path = Bundle.main.path(forResource: "install-helper.sh", ofType: nil) else {
            throw Failure.message(L("install-helper.sh is missing. Run a Tether.app built with scripts/build.sh.",
                                    "install-helper.sh를 찾을 수 없습니다. build.sh로 만든 Tether.app에서 실행하세요."))
        }
        let output = try await HelperAuthorizationProcess().run(arguments: helperInstallationArguments(path: path))
        if let failure = helperInstallationFailure(exitStatus: output.exitStatus, stderr: output.stderr) { throw failure }
    }

    static func helperInstallationArguments(path: String) -> [String] {
        let command = "/bin/sh " + shellQuoted(path)
        return ["-e", "do shell script \(appleScriptQuoted(command)) with administrator privileges"]
    }

    /// osascript returns the AppleScript error number even in a localized dialog.
    /// Cancellation keeps the same meaning as the existing NSAppleScript executor.
    static func helperInstallationFailure(exitStatus: Int32, stderr: String) -> Failure? {
        guard exitStatus != 0 else { return nil }
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.range(of: #"\(-128\)\s*$"#, options: .regularExpression) != nil { return .cancelled }
        return .message(message.isEmpty ? L("The helper task failed.", "도우미 작업에 실패했습니다.") : message)
    }

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

/// Termination and stderr EOF can arrive in either order. Drain the pipe throughout
/// the wait, but retain only bounded diagnostic text; installer output cannot fill
/// a pipe and stall authorization completion. No password is read or supplied.
final class HelperAuthorizationProcess: @unchecked Sendable {
    struct Output: Sendable { let exitStatus: Int32; let stderr: String }
    private let process = Process()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, Error>?
    private var exitStatus: Int32?
    private var stderrEnded = false
    private var errorData = Data()
    private let maximumErrorBytes = 16_384
    private let executableURL: URL

    /// The production call always uses osascript. Existing test modules may use
    /// a fixed nonprivileged fixture executable to exercise completion ordering.
    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/osascript")) { self.executableURL = executableURL }

    func run(arguments: [String]) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                self.lock.withLock {
                    self.errorData.append(data.prefix(max(0, self.maximumErrorBytes - self.errorData.count)))
                    if data.isEmpty { self.stderrEnded = true }
                }
                self.finishIfPossible()
            }
            process.terminationHandler = { [self] process in
                lock.withLock { exitStatus = process.terminationStatus }
                finishIfPossible()
            }
            do {
                try process.run()
                // The child's duplicated stderr descriptor stays open. Closing
                // this parent's writer lets EOF arrive when that child finishes.
                errorPipe.fileHandleForWriting.closeFile()
            } catch {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                let waiting = lock.withLock {
                    let waiting = self.continuation
                    self.continuation = nil
                    return waiting
                }
                errorPipe.fileHandleForWriting.closeFile()
                waiting?.resume(throwing: error)
            }
        }
    }

    private func finishIfPossible() {
        let completion = lock.withLock { () -> (CheckedContinuation<Output, Error>, Output)? in
            guard stderrEnded, let exitStatus, let continuation else { return nil }
            self.continuation = nil
            return (continuation, Output(exitStatus: exitStatus, stderr: String(decoding: errorData, as: UTF8.self)))
        }
        guard let completion else { return }
        process.terminationHandler = nil
        completion.0.resume(returning: completion.1)
    }
}
