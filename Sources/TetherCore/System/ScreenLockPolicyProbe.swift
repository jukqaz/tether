import Foundation

/// The password policy after screen sleep or the screen saver starts. This is
/// neither the current screen-lock state nor proof of working remote access.
public enum ScreenLockPolicy: Equatable, Sendable {
    case off
    case immediate
    case after(seconds: Int)
    case unavailable
}

/// Read-only observation. Never sends a password or changes the lock policy.
public enum ScreenLockPolicyProbe {
    static let maximumOutputBytes = 2_048
    // A conservative parser bound, not a claim that macOS supports every delay.
    static let maximumDelaySeconds = 86_400

    public static func read() -> ScreenLockPolicy {
        let result = Shell.run("/usr/sbin/sysadminctl", ["-screenLock", "status"],
                               timeout: 2, maxOutputBytes: maximumOutputBytes)
        guard result.exitStatus == 0 else { return .unavailable }
        return parse(status: result.status, output: result.output, timedOut: result.timedOut,
                     terminationConfirmed: result.terminationConfirmed)
    }

    /// A successful command without one exact policy line remains unavailable.
    /// Saturated output might hide a second policy or an error after truncation.
    public static func parse(status: Int32, output: String, timedOut: Bool,
                             terminationConfirmed: Bool) -> ScreenLockPolicy {
        guard status == 0, !timedOut, terminationConfirmed,
              output.utf8.count < maximumOutputBytes else { return .unavailable }
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.count == 1 else { return .unavailable }
        let line = String(lines[0])
        let prefix = #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} sysadminctl\[[0-9]+:[0-9]+\] "#
        guard let range = line.range(of: prefix, options: .regularExpression) else { return .unavailable }
        let message = String(line[range.upperBound...])
        switch message {
        case "screenLock is off": return .off
        case "screenLock delay is immediate": return .immediate
        default:
            let start = "screenLock delay is ", end = " seconds"
            guard message.hasPrefix(start), message.hasSuffix(end) else { return .unavailable }
            let digits = String(message.dropFirst(start.count).dropLast(end.count))
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  let seconds = Int(digits), (0...maximumDelaySeconds).contains(seconds),
                  String(seconds) == digits else { return .unavailable }
            return .after(seconds: seconds)
        }
    }
}
