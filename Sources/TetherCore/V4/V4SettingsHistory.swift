import Foundation
import CryptoKit

public struct V4AppPreferences: Codable, Equatable, Sendable {
    public var automaticEnabled = false
    public var allowDisplay = false
    public var allowClosedLid = false
    public var batteryLowerBound = 20
    public var nextManualMinutes: Int? = 30
    public var launchAtLogin = false
    public var language = "system"
    public var updateChannel = "stable"
    public var automaticUpdateCheck = true
    public var disconnectAction: WorkSessionEndAction = .sleepIfClosed
    public var notifyHeat = true
    public var notifyBatteryProtection = true
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case automaticEnabled, allowDisplay, allowClosedLid, batteryLowerBound, nextManualMinutes
        case launchAtLogin, language, updateChannel, automaticUpdateCheck
        case disconnectAction, notifyHeat, notifyBatteryProtection
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        automaticEnabled = try c.decode(Bool.self, forKey: .automaticEnabled)
        allowDisplay = try c.decode(Bool.self, forKey: .allowDisplay)
        allowClosedLid = try c.decode(Bool.self, forKey: .allowClosedLid)
        batteryLowerBound = try c.decode(Int.self, forKey: .batteryLowerBound)
        // Legacy synthesized Codable omitted nil. Preserve that AC-unlimited choice on decode.
        nextManualMinutes = try c.decodeIfPresent(Int.self, forKey: .nextManualMinutes)
        launchAtLogin = try c.decode(Bool.self, forKey: .launchAtLogin)
        language = try c.decode(String.self, forKey: .language)
        updateChannel = try c.decode(String.self, forKey: .updateChannel)
        automaticUpdateCheck = try c.decode(Bool.self, forKey: .automaticUpdateCheck)
        disconnectAction = try c.decodeIfPresent(WorkSessionEndAction.self, forKey: .disconnectAction) ?? .sleepIfClosed
        notifyHeat = try c.decodeIfPresent(Bool.self, forKey: .notifyHeat) ?? true
        notifyBatteryProtection = try c.decodeIfPresent(Bool.self, forKey: .notifyBatteryProtection) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(automaticEnabled, forKey: .automaticEnabled); try c.encode(allowDisplay, forKey: .allowDisplay)
        try c.encode(allowClosedLid, forKey: .allowClosedLid); try c.encode(batteryLowerBound, forKey: .batteryLowerBound)
        try c.encodeIfPresent(nextManualMinutes, forKey: .nextManualMinutes)
        try c.encode(launchAtLogin, forKey: .launchAtLogin); try c.encode(language, forKey: .language)
        try c.encode(updateChannel, forKey: .updateChannel); try c.encode(automaticUpdateCheck, forKey: .automaticUpdateCheck)
        try c.encode(disconnectAction, forKey: .disconnectAction); try c.encode(notifyHeat, forKey: .notifyHeat)
        try c.encode(notifyBatteryProtection, forKey: .notifyBatteryProtection)
    }
}

/// Export/rollback schema has no slot for runtime state, OS permissions or execution tokens.
public struct V4SettingsDocument: Codable, Equatable, Sendable {
    public var version = 1
    public var generation: UInt64
    public var settings: V4Settings
    public var preferences: V4AppPreferences
    public init(generation: UInt64 = 0, settings: V4Settings = .init(), preferences: V4AppPreferences = .init()) {
        self.generation = generation; self.settings = settings; self.preferences = preferences
    }
}

public enum V4SettingsPart: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic, presets, manualDefaults, notifications, globalFeatures, batteryProtection, application
}
public enum V4SettingsChangeSource: String, Codable, Sendable { case user, importing, migration, rollback }
public struct V4SettingsIssue: Codable, Equatable, Sendable {
    public var code: String
    public var blocking: Bool
    public init(_ code: String, blocking: Bool = true) { self.code = code; self.blocking = blocking }
}
public struct V4SettingsPreview: Equatable, Sendable {
    public var baseGeneration: UInt64
    public var baseFingerprint: String
    public var sourceFingerprint: String
    public var candidate: V4SettingsDocument
    public var candidateFingerprint: String
    public var changedParts: Set<V4SettingsPart>
    public var issues: [V4SettingsIssue]
    public var affectsActiveManual: Bool
}
public struct V4SettingsApplyResult: Equatable, Sendable {
    public var disposition: V4CommandDisposition
    public var reason: String
    /// Caller must atomically save this value; OS registrations have their own result.
    public var document: V4SettingsDocument?
}

public enum V4SettingsTransfer {
    public static let maximumBytes = 1_048_576
    public static func encode(_ document: V4SettingsDocument) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return data
    }
    public static func decode(_ data: Data) throws -> V4SettingsDocument {
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(V4SettingsDocument.self, from: data)
        guard validate(value).allSatisfy({ !$0.blocking }) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    public static func fingerprint(_ document: V4SettingsDocument) -> String {
        guard let data = try? encode(document) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func validate(_ document: V4SettingsDocument) -> [V4SettingsIssue] {
        var issues = V4RuleEngine.validate(document.settings).map { V4SettingsIssue($0) }
        if document.version != 1 { issues.append(.init("unsupported-document-version")) }
        if !(20...80).contains(document.preferences.batteryLowerBound) { issues.append(.init("invalid-battery-protection")) }
        // Preserve safe custom defaults saved by earlier versions. New preset editors still expose six choices;
        // decoding/export/history must not erase unrelated settings merely because an old default was 17m.
        if let minutes = document.preferences.nextManualMinutes, !(1...(Int.max / 60)).contains(minutes) {
            issues.append(.init("invalid-manual-default"))
        }
        if !["system", "ko", "en"].contains(document.preferences.language) { issues.append(.init("unsupported-language")) }
        if !["stable", "beta"].contains(document.preferences.updateChannel) { issues.append(.init("unsupported-update-channel")) }
        if !["followOS", "sleepIfClosed"].contains(document.preferences.disconnectAction.rawValue) {
            issues.append(.init("unsupported-disconnect-action"))
        }
        if document.settings.usesAdvancedAutomaticConditions, let id = document.settings.activePresetID,
           !document.settings.presets.contains(where: { $0.id == id }) { issues.append(.init("missing-active-preset")) }
        return issues
    }

    public static func changedParts(from before: V4SettingsDocument, to after: V4SettingsDocument) -> Set<V4SettingsPart> {
        var parts: Set<V4SettingsPart> = []
        if before.preferences.automaticEnabled != after.preferences.automaticEnabled
            || before.settings.automaticMode != after.settings.automaticMode
            || before.settings.activePresetID != after.settings.activePresetID { parts.insert(.automatic) }
        if before.settings.presets != after.settings.presets { parts.insert(.presets) }
        if before.preferences.nextManualMinutes != after.preferences.nextManualMinutes
            || before.settings.nextManualOptions != after.settings.nextManualOptions { parts.insert(.manualDefaults) }
        if before.settings.notifyManualExpiry != after.settings.notifyManualExpiry
            || before.settings.notifyTaskEnd != after.settings.notifyTaskEnd
            || before.settings.expiryNoticeEnabled != after.settings.expiryNoticeEnabled
            || before.preferences.notifyHeat != after.preferences.notifyHeat
            || before.preferences.notifyBatteryProtection != after.preferences.notifyBatteryProtection { parts.insert(.notifications) }
        if before.preferences.allowDisplay != after.preferences.allowDisplay
            || before.preferences.allowClosedLid != after.preferences.allowClosedLid
            || before.preferences.disconnectAction != after.preferences.disconnectAction { parts.insert(.globalFeatures) }
        if before.preferences.batteryLowerBound != after.preferences.batteryLowerBound
            || before.settings.stopOnLowPowerMode != after.settings.stopOnLowPowerMode { parts.insert(.batteryProtection) }
        if before.preferences.language != after.preferences.language
            || before.preferences.launchAtLogin != after.preferences.launchAtLogin
            || before.preferences.updateChannel != after.preferences.updateChannel
            || before.preferences.automaticUpdateCheck != after.preferences.automaticUpdateCheck
            || before.settings.experimentalProvidersEnabled != after.settings.experimentalProvidersEnabled { parts.insert(.application) }
        return parts
    }

    public static func preview(source: V4SettingsDocument, current: V4SettingsDocument,
                               selected: Set<V4SettingsPart>, activeManual: Bool,
                               capabilities: [V4Capability] = []) -> V4SettingsPreview {
        var candidate = current
        for part in selected {
            switch part {
            case .automatic:
                candidate.preferences.automaticEnabled = source.preferences.automaticEnabled
                candidate.settings.automaticMode = source.settings.automaticMode
                candidate.settings.activePresetID = source.settings.activePresetID
            case .presets: candidate.settings.presets = source.settings.presets
            case .manualDefaults:
                candidate.preferences.nextManualMinutes = source.preferences.nextManualMinutes
                candidate.settings.nextManualOptions = source.settings.nextManualOptions
            case .notifications:
                candidate.settings.notifyManualExpiry = source.settings.notifyManualExpiry
                candidate.settings.notifyTaskEnd = source.settings.notifyTaskEnd
                candidate.settings.expiryNoticeEnabled = source.settings.expiryNoticeEnabled
                candidate.preferences.notifyHeat = source.preferences.notifyHeat
                candidate.preferences.notifyBatteryProtection = source.preferences.notifyBatteryProtection
            case .globalFeatures:
                candidate.preferences.allowDisplay = source.preferences.allowDisplay
                candidate.preferences.allowClosedLid = source.preferences.allowClosedLid
                candidate.preferences.disconnectAction = source.preferences.disconnectAction
            case .batteryProtection:
                candidate.preferences.batteryLowerBound = source.preferences.batteryLowerBound
                candidate.settings.stopOnLowPowerMode = source.settings.stopOnLowPowerMode
            case .application:
                candidate.preferences.language = source.preferences.language
                candidate.preferences.launchAtLogin = source.preferences.launchAtLogin
                candidate.preferences.updateChannel = source.preferences.updateChannel
                candidate.preferences.automaticUpdateCheck = source.preferences.automaticUpdateCheck
                candidate.settings.experimentalProvidersEnabled = source.settings.experimentalProvidersEnabled
            }
        }
        let changed = changedParts(from: current, to: candidate)
        let affects = activeManual && !changed.isDisjoint(with: [.globalFeatures, .batteryProtection])
        var issues = validate(candidate)
        if affects { issues.append(.init("active-manual-would-change")) }
        let catalog = Dictionary(grouping: capabilities, by: \.kind)
        for condition in candidate.settings.presets.flatMap(\.groups).flatMap(\.conditions) {
            guard condition.kind != .timeWindow else { continue }
            if catalog[condition.kind]?.count != 1 || catalog[condition.kind]?.first?.status == .unsupported {
                issues.append(.init("provider-unavailable:\(condition.kind.rawValue)", blocking: false))
            } else if catalog[condition.kind]?.first?.permissionGranted != true {
                issues.append(.init("permission-required:\(condition.kind.rawValue)", blocking: false))
            }
        }
        return .init(baseGeneration: current.generation, baseFingerprint: fingerprint(current),
            sourceFingerprint: fingerprint(source), candidate: candidate, candidateFingerprint: fingerprint(candidate),
            changedParts: changed, issues: issues, affectsActiveManual: affects)
    }

    public static func apply(_ preview: V4SettingsPreview, current: V4SettingsDocument,
                             activeManual: Bool) -> V4SettingsApplyResult {
        guard preview.baseGeneration == current.generation, preview.baseFingerprint == fingerprint(current) else {
            return .init(disposition: .rejected, reason: "settings-changed-repreview", document: nil)
        }
        guard preview.candidateFingerprint == fingerprint(preview.candidate),
              !preview.issues.contains(where: \.blocking), validate(preview.candidate).isEmpty else {
            return .init(disposition: .rejected, reason: "invalid-selection", document: nil)
        }
        let parts = changedParts(from: current, to: preview.candidate)
        guard !activeManual || parts.isDisjoint(with: [.globalFeatures, .batteryProtection]) else {
            return .init(disposition: .limited, reason: "active-manual-would-change", document: nil)
        }
        guard current.generation < UInt64.max else { return .init(disposition: .rejected, reason: "generation-exhausted", document: nil) }
        var result = preview.candidate
        result.generation = current.generation + 1; result.settings.generation = result.generation
        return .init(disposition: .accepted, reason: "save-required", document: result)
    }

    /// New IDs are supplied by the caller so the operation is deterministic and replay-safe.
    public static func previewImport(_ source: V4SettingsDocument, current: V4SettingsDocument,
                                     replacementIDs: [UUID: UUID], capabilities: [V4Capability] = []) -> V4SettingsPreview {
        var candidate = current
        var names = Set(current.settings.presets.map { $0.name.lowercased() })
        var issues = validate(source)
        var allocated = Set(current.settings.presets.map(\.id)
            + current.settings.presets.flatMap(\.groups).map(\.id)
            + current.settings.presets.flatMap(\.groups).flatMap(\.conditions).map(\.id))
        func replacement(_ id: UUID) -> UUID {
            guard let fresh = replacementIDs[id], allocated.insert(fresh).inserted else {
                issues.append(.init("missing-or-colliding-copy-id")); return id
            }
            return fresh
        }
        for preset in source.settings.presets {
            var copy = preset
            copy.id = replacement(preset.id); copy.enabled = false
            var name = preset.name; var suffix = 2
            while names.contains(name.lowercased()) { name = "\(preset.name) (\(suffix))"; suffix += 1 }
            copy.name = name; names.insert(name.lowercased())
            copy.groups = preset.groups.map { group in
                var groupCopy = group; groupCopy.id = replacement(group.id)
                groupCopy.conditions = group.conditions.map { condition in
                    var conditionCopy = condition; conditionCopy.id = replacement(condition.id); return conditionCopy
                }
                return groupCopy
            }
            candidate.settings.presets.append(copy)
        }
        var plan = preview(source: candidate, current: current, selected: [.presets], activeManual: false, capabilities: capabilities)
        plan.sourceFingerprint = fingerprint(source); plan.issues += issues
        return plan
    }
}

public struct V4SettingsHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var at: Double
    public var source: V4SettingsChangeSource
    public var before: V4SettingsDocument
    public var after: V4SettingsDocument
    public var fingerprint: String
}

public struct V4SettingsHistory: Codable, Equatable, Sendable {
    public private(set) var entries: [V4SettingsHistoryEntry] = []
    public private(set) var missingHistory = false
    public var maximumEntries = 20
    public var maximumAge: Double = 30 * 86400
    public var maximumBytes = 1_048_576
    public init() {}

    @discardableResult
    public mutating func recordChange(before: V4SettingsDocument, after: V4SettingsDocument,
        id: UUID, at: Double, source: V4SettingsChangeSource) -> V4CommandDisposition {
        guard at.isFinite else { missingHistory = true; return .rejected }
        guard !V4SettingsTransfer.changedParts(from: before, to: after).isEmpty else { return .alreadyProcessed }
        guard !entries.contains(where: { $0.id == id }) else { return .alreadyProcessed }
        let entry = V4SettingsHistoryEntry(id: id, at: at, source: source, before: before, after: after,
                                          fingerprint: V4SettingsTransfer.fingerprint(before))
        guard let bytes = try? JSONEncoder().encode(entry), bytes.count <= max(0, maximumBytes) else {
            missingHistory = true; return .limited
        }
        entries.append(entry); trim(now: at)
        return .accepted
    }
    public mutating func noteHistoryWriteFailure() { missingHistory = true }
    public mutating func delete(id: UUID) { entries.removeAll { $0.id == id } }
    public mutating func deleteAll() { entries.removeAll() }
    public mutating func trim(now: Double) {
        guard now.isFinite else { return }
        entries.removeAll { !$0.at.isFinite || $0.at > now || now - $0.at > max(0, maximumAge) }
        while entries.count > max(0, maximumEntries) { entries.removeFirst() }
        while !entries.isEmpty && ((try? JSONEncoder().encode(entries).count) ?? Int.max) > max(0, maximumBytes) {
            entries.removeFirst()
        }
    }
    public func previewRollback(id: UUID, current: V4SettingsDocument, selected: Set<V4SettingsPart>,
                                activeManual: Bool, capabilities: [V4Capability] = []) -> V4SettingsPreview? {
        guard let entry = entries.first(where: { $0.id == id }),
              entry.fingerprint == V4SettingsTransfer.fingerprint(entry.before) else { return nil }
        return V4SettingsTransfer.preview(source: entry.before, current: current, selected: selected,
                                         activeManual: activeManual, capabilities: capabilities)
    }
    public func applyRollback(id: UUID, preview: V4SettingsPreview, current: V4SettingsDocument,
                              activeManual: Bool) -> V4SettingsApplyResult {
        guard let entry = entries.first(where: { $0.id == id }), entry.fingerprint == preview.sourceFingerprint,
              entry.fingerprint == V4SettingsTransfer.fingerprint(entry.before) else {
            return .init(disposition: .rejected, reason: "history-unavailable-reselect", document: nil)
        }
        return V4SettingsTransfer.apply(preview, current: current, activeManual: activeManual)
    }
}
