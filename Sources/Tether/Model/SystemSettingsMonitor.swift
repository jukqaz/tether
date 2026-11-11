import Foundation
import TetherCore

/// Observes shared macOS settings without becoming a second settings writer.
/// Uses the existing app refresh cadence; previews never launch system commands.
@MainActor
final class SystemSettingsMonitor: ObservableObject {
    struct Reading: Equatable, Sendable {
        var screenLock: ScreenLockPolicy
        var loginItemConfigured: Bool
        var loginItemDisabled: Bool?
    }

    @Published private(set) var value = Reading(screenLock: .unavailable, loginItemConfigured: false, loginItemDisabled: nil)
    @Published private(set) var reading = false
    @Published private(set) var checkedAt: Date?
    var onChange: (() -> Void)?
    private let reader: @Sendable () async -> Reading
    private let clock: () -> Double
    private let simulated: Bool
    private var lastStarted: Double?
    private var lastCompleted: Double?
    private var revision: UInt64 = 0
    private var refreshPending = false

    init(simulated: Bool, reader: (@Sendable () async -> Reading)? = nil,
         clock: @escaping () -> Double = { ContinuousTime.now }) {
        self.simulated = simulated && reader == nil
        self.clock = clock
        let path = SystemIntegration.launchAgentPath
        let label = SystemIntegration.launchAgentLabel
        let uid = geteuid()
        self.reader = reader ?? {
            await Task.detached(priority: .utility) {
                let configured = FileManager.default.fileExists(atPath: path)
                let disabled: Bool?
                if configured {
                    let result = Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"], timeout: 2, maxOutputBytes: 65_536)
                    disabled = result.status == 0 && !result.timedOut && result.terminationConfirmed
                        && result.output.utf8.count < 65_536 ? Self.loginItemDisabled(in: result.output, label: label) : nil
                } else { disabled = nil }
                return Reading(screenLock: ScreenLockPolicyProbe.read(), loginItemConfigured: configured,
                               loginItemDisabled: disabled)
            }.value
        }
    }

    var currentScreenLock: ScreenLockPolicy {
        let now = clock()
        guard let completed = lastCompleted, now.isFinite, now >= completed, now - completed < 45 else { return .unavailable }
        return value.screenLock
    }

    func refresh(force: Bool = false) {
        guard !simulated else { return }
        let now = clock()
        guard now.isFinite else { invalidate(); return }
        if reading { refreshPending = refreshPending || force; return }
        guard force || lastStarted.map({ now < $0 || now - $0 >= 15 }) ?? true else { return }
        reading = true; lastStarted = now
        let generation = revision
        Task { [weak self, reader] in
            let result = await reader()
            guard let self else { return }
            reading = false
            let completed = clock()
            if generation == revision, completed.isFinite {
                value = result; lastCompleted = completed; checkedAt = Date(); onChange?()
            }
            if refreshPending { refreshPending = false; refresh(force: true) }
        }
    }

    /// Discard observations started before an app-side edit; the newer read wins.
    func invalidate() {
        revision &+= 1; lastCompleted = nil; checkedAt = nil
        value = Reading(screenLock: .unavailable, loginItemConfigured: value.loginItemConfigured, loginItemDisabled: nil)
        onChange?()
    }

    nonisolated static func loginItemDisabled(in output: String, label: String) -> Bool? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "disabled services = {", lines.last == "}", lines.count >= 2 else { return nil }
        var matched: Bool?
        let prefix = "\"\(label)\" => "
        for line in lines.dropFirst().dropLast() {
            guard line.hasPrefix("\""), let delimiter = line.range(of: "\" => ") else { return nil }
            let state = String(line[delimiter.upperBound...])
            guard ["enabled", "disabled", "true", "false"].contains(state) else { return nil }
            if line.hasPrefix(prefix) {
                guard matched == nil else { return nil }
                matched = state == "disabled" || state == "true"
            }
        }
        // launchd lists overrides only. An absent label has no disabled override.
        return matched ?? false
    }
}
