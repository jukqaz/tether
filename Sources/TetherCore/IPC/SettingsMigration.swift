import Foundation
import CryptoKit

public struct MigrationReport: Codable, Equatable, Sendable {
    public let fromSchema: Int
    public let toSchema: Int
    public let appVersion: String
    public let backupName: String
    public let cleared: [String]
    public let frozeAdaptiveLimits: Bool
}

/// Runs before the helper accepts requests. Original bytes are retained independently of the
/// rolling control backup, and a repeated launch never replays a completed migration.
public enum SettingsMigration {
    public static func migrate(controlPath: String, usage: Usage? = nil) throws -> MigrationReport? {
        guard let data = JSONFile.readBytes(from: controlPath),
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var control = try? JSONDecoder().decode(Control.self, from: data), control.isSupported else {
            throw ServiceFailure("configurationUnreadable")
        }
        let schema = control.schemaVersion ?? 0
        guard schema < Control.currentSchema else {
            guard !control.hasRetiredSettings else { throw ServiceFailure("configurationUnreadable") }
            return nil
        }
        let folder = URL(fileURLWithPath: controlPath).deletingLastPathComponent()
        let backupDirectory = folder.appendingPathComponent("migrations")
        try preparePrivateDirectory(backupDirectory.path)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = "control-schema\(schema)-\(digest).json"
        let backup = backupDirectory.appendingPathComponent(name).path
        if FileManager.default.fileExists(atPath: backup) {
            guard JSONFile.readBytes(from: backup) == data else { throw ServiceFailure("writeFailed") }
        } else if !JSONFile.writeBytes(data, to: backup, permissions: 0o600, durable: true) {
            throw ServiceFailure("writeFailed")
        }
        var cleared = ["batteryHoldUntil", "pendingHoldMinutes", "holdSource", "sleepNowRequest", "profile", "paused", "autoLimits", "heatGuard", "holdLowPower"]
            .filter { raw[$0] != nil }
        let adaptive = raw["autoLimits"] as? Bool == true
        if adaptive {
            // Removing adaptation must not loosen the effective limits already in force.
            control.limits = frozenAdaptiveBatteryLimits(control.limits, usage: usage, now: Date())
            cleared.append("adaptivePolicyFrozen")
        }
        // Do not silently replace an explicitly chosen Celsius cutoff with a different
        // policy while an unattended session runs. The original is backed up above;
        // the user resumes once under the new, clearly described OS-pressure policy.
        let oldLimits = raw["limits"] as? [String: Any]
        if adaptive || oldLimits?["closedLidMaxTemperature"] != nil || oldLimits?["openLidMaxTemperature"] != nil {
            control.enabled = false
            cleared.append("temperaturePolicyRequiresResume")
        }
        if oldLimits?["closedLidMaxTemperature"] != nil { cleared.append("limits.closedLidMaxTemperature") }
        if oldLimits?["openLidMaxTemperature"] != nil { cleared.append("limits.openLidMaxTemperature") }
        control.limits?.closedLidMaxTemperature = nil; control.limits?.openLidMaxTemperature = nil
        if control.limits?.isDefault == true { control.limits = nil }
        control.heatGuard = nil; control.holdLowPower = nil; control.autoLimits = nil
        if control.powerCondition == .battery {
            control.enabled = false
            cleared.append("batteryAutomaticRetired")
        }
        if control.powerCondition != nil { control.powerCondition = .ac }
        control.schemaVersion = Control.currentSchema
        control.batteryHoldUntil = nil; control.pendingHoldMinutes = nil; control.holdSource = nil; control.sleepNowRequest = nil
        let report = MigrationReport(fromSchema: schema, toSchema: Control.currentSchema, appVersion: TetherPaths.version,
                                     backupName: name, cleared: cleared, frozeAdaptiveLimits: adaptive)
        // Publish the recovery information first. If either write fails the original file stays
        // intact and the helper refuses to enable clamshell mode.
        guard JSONFile.write(report, to: folder.appendingPathComponent("migration-report.json").path,
                             permissions: 0o644, durable: true),
              JSONFile.write(control, to: controlPath, permissions: 0o644, durable: true) else {
            throw ServiceFailure("writeFailed")
        }
        return report
    }

    /// Only the old measured battery allowance survives migration. Retired Celsius
    /// recommendations never influence the current OS-pressure protection policy.
    private static func frozenAdaptiveBatteryLimits(_ previous: UserLimits?, usage: Usage?, now: Date) -> UserLimits {
        let floor = SafetyPolicy.floor(previous)
        var maximum = SafetyPolicy.maxHold(previous)
        let week = (usage?.stats ?? StatsTracker()).week(now: now)
        let seconds = week.reduce(0) { $0 + ($1.holdSeconds ?? 0) }
        let drain = week.reduce(0) { $0 + ($1.holdDrain ?? 0) }
        if seconds.isFinite, drain.isFinite, seconds >= 900, drain > 0 {
            let rate = drain / (seconds / 3600)
            if rate.isFinite, rate > 0 {
                let starts = (usage?.recentSessions ?? []).filter(\.onBattery).compactMap(\.batteryStart)
                let start = starts.isEmpty ? 100 : starts.reduce(0.0) { $0 + Double($1) } / Double(starts.count)
                let hours = (start - Double(floor)) / rate
                let choices = SafetyPolicy.maxHoldChoices.sorted()
                let measured = choices.last { $0 <= hours } ?? choices.first ?? 1
                maximum = min(maximum, measured * 3600)
            }
        }
        return UserLimits(batteryFloor: floor, maxHoldHours: maximum / 3600)
    }

    private static func preparePrivateDirectory(_ path: String) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT, mkdir(path, 0o700) == 0 else { throw ServiceFailure("writeFailed") }
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o700 else { throw ServiceFailure("writeFailed") }
    }
}

public enum PreferenceMigration {
    public static func apply(defaults: UserDefaults, domain: String, legacyDomain: String,
                             backupDirectory: URL, hadExistingInstall: Bool) throws {
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        let old = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        if current["preferencesMigration2"] as? Bool != true, !current.isEmpty || !old.isEmpty {
            let originalData = try PropertyListSerialization.data(fromPropertyList: ["current": current, "legacy": old], format: .binary, options: 0)
            guard originalData.count <= JSONFile.maxSize else { throw ServiceFailure("writeFailed") }
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let backup = backupDirectory.appendingPathComponent("preferences-before-2.2.plist").path
            // The fixed recovery name belongs to one pair of source domains. Reuse
            // that original, never overwrite it or accumulate backups on a conflict.
            if try !publishBackup(originalData, to: backup) {
                guard let data = JSONFile.readBytes(from: backup, expectedOwner: geteuid(), expectedPermissions: 0o600),
                      let original = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                      Set(original.keys) == Set(["current", "legacy"]),
                      let originalCurrent = original["current"] as? [String: Any],
                      let originalLegacy = original["legacy"] as? [String: Any],
                      sameOriginal(originalCurrent, current), sameOriginal(originalLegacy, old) else {
                    throw ServiceFailure("writeFailed")
                }
            }
        }
        var result = merged(current: current, legacy: old, hadExistingInstall: hadExistingInstall || !current.isEmpty || !old.isEmpty)
        result["preferencesMigration2"] = true
        defaults.setPersistentDomain(result, forName: domain)
        // Keep the old domain and original plist for recovery.
    }

    /// Publish only a complete, durable original. A failed write must not occupy the
    /// recovery name, and another writer's existing original is never replaced.
    /// The write closure lets regression tests interrupt a real temporary-file write.
    static func publishBackup(_ data: Data, to path: String,
                              write: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) throws -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return false }
        guard errno == ENOENT else { throw ServiceFailure("writeFailed") }
        var template = Array("\(path).XXXXXX".utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw ServiceFailure("writeFailed") }
        let temporary = String(cString: template)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); unlink(temporary) }
        do {
            guard fchmod(fd, 0o600) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ServiceFailure("writeFailed") }
            try write(file, data)
            try file.synchronize()
            guard renamex_np(temporary, path, UInt32(RENAME_EXCL)) == 0 else {
                guard errno == EEXIST else { throw ServiceFailure("writeFailed") }
                return false
            }
            guard JSONFile.syncDirectory(containing: path) else { throw ServiceFailure("writeFailed") }
            return true
        } catch { throw ServiceFailure("writeFailed") }
    }

    private static func sameOriginal(_ original: Any, _ current: Any) -> Bool {
        if let left = original as? [String: Any], let right = current as? [String: Any] {
            return Set(left.keys) == Set(right.keys) && left.allSatisfy { key, value in
                right[key].map { sameOriginal(value, $0) } == true
            }
        }
        if let left = original as? [Any], let right = current as? [Any] {
            return left.count == right.count && zip(left, right).allSatisfy { pair in sameOriginal(pair.0, pair.1) }
        }
        if let left = original as? NSNumber, let right = current as? NSNumber {
            // Foundation dictionary equality considers false and numeric zero equal;
            // a recovery original must keep preference booleans distinct from numbers.
            return CFGetTypeID(left) == CFGetTypeID(right) && left.isEqual(to: right)
        }
        guard let left = original as? NSObject, let right = current as? NSObject else { return false }
        return left.isEqual(right)
    }

    /// Destination values win, including false. Keep the legacy domain as the rollback copy.
    /// Login-item intent is explicit after an upgrade, so an old choice of off remains off.
    public static func merged(current: [String: Any], legacy: [String: Any], hadExistingInstall: Bool) -> [String: Any] {
        var result = current
        if result["migratedFromLocalTether"] as? Bool != true {
            for (key, value) in legacy where result[key] == nil { result[key] = value }
            result["migratedFromLocalTether"] = true
        }
        if hadExistingInstall, result["launchAtLoginConfigured"] == nil { result["launchAtLoginConfigured"] = true }
        // Existing Sparkle choices win; otherwise carry over the app's update-check preference.
        if result["SUEnableAutomaticChecks"] == nil, let value = result["checkUpdates"] as? Bool {
            result["SUEnableAutomaticChecks"] = value
        }
        return result
    }
}
