import Foundation
import TetherCore

/// Templates modify a value copy only; applying it still belongs to AppModel.
enum V4RuleStarter: String, CaseIterable, Identifiable {
    case workHours, application, externalDisplay
    var id: String { rawValue }

    var title: String {
        switch self {
        case .workHours: L("Work hours", "업무시간")
        case .application: L("An app", "특정 앱")
        case .externalDisplay: L("External display", "외장 화면")
        }
    }

    static func canAdd(to settings: V4Settings) -> Bool {
        settings.presets.count < V4RuleEngine.maximumPresets
            && settings.presets.reduce(0) { $0 + $1.groups.reduce(0) { $0 + $1.conditions.count } }
                < V4RuleEngine.maximumConditions
    }

    func adding(to settings: V4Settings, nextManualMinutes: Int?) -> V4Settings {
        guard Self.canAdd(to: settings) else { return settings }
        let condition: V4Condition
        switch self {
        case .workHours:
            condition = .init(id: UUID(), kind: .timeWindow,
                timeWindow: .init(startMinute: 9 * 60, endMinute: 17 * 60, weekdays: Set(2...6)))
        case .application:
            condition = .init(id: UUID(), kind: .appRunning)
        case .externalDisplay:
            condition = .init(id: UUID(), kind: .externalDisplay)
        }
        // A saved duration outside the preset editor's choices must not create an invalid preset.
        let minutes = nextManualMinutes.map { [5, 10, 15, 30, 60, 120].contains($0) ? $0 : 30 }
        var name = title
        var suffix = 2
        while settings.presets.contains(where: { $0.name == name }) {
            name = "\(title) (\(suffix))"; suffix += 1
        }
        let preset = V4Preset(id: UUID(), name: name,
            groups: [.init(id: UUID(), conditions: [condition])],
            options: settings.nextManualOptions, nextManualMinutes: minutes)
        var draft = settings
        draft.presets.append(preset)
        draft.activePresetID = preset.id
        draft.automaticMode = .advanced
        return draft
    }

    static func needsTargetSelection(_ settings: V4Settings) -> Bool {
        guard settings.usesAdvancedAutomaticConditions,
              let preset = V4RuleEngine.activePreset(settings), preset.enabled else { return false }
        return preset.groups.flatMap(\.conditions).contains {
            $0.enabled && [.appRunning, .appFrontmost, .externalDisplay].contains($0.kind)
                && $0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// A selected app is read, never opened. The bundle identifier is the provider's match key.
struct V4SelectedApplication: Equatable {
    let bundleIdentifier: String
    let name: String

    init?(url: URL) {
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { return nil }
        self.init(url: url, info: info, localizedInfo: bundle.localizedInfoDictionary ?? [:])
    }

    init?(url: URL, info: [String: Any], localizedInfo: [String: Any] = [:]) {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              info["CFBundlePackageType"] as? String == "APPL",
              let identifier = info["CFBundleIdentifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        bundleIdentifier = identifier
        let names = [localizedInfo["CFBundleDisplayName"], info["CFBundleDisplayName"],
                     localizedInfo["CFBundleName"], info["CFBundleName"]]
        name = names.compactMap { $0 as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? url.deletingPathExtension().lastPathComponent
    }
}
