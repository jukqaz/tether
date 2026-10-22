import Foundation
import TetherCore

struct V4HistoryPresentation: Identifiable {
    var id: UUID
    var title: String
    var date: Date
    var detail: String
}
struct V4HistoryRestorePreview {
    var id: UUID
    var generation: UInt64
    var groups: [String]
    var summary: String
    var blockedReason: String?
}

@MainActor
extension AppModel {
    var v4Settings: V4Settings {
        var value = userSession?.v4Settings ?? .init()
        value.generation = v4ConfigurationGeneration
        return value
    }
    var notifySessionEnd: Bool { v4Settings.notifyManualExpiry }
    var notifyExpiryWarning: Bool { v4Settings.expiryNoticeEnabled }
    func setNotifySessionEnd(_ value: Bool) {
        var next = v4Settings; next.notifyManualExpiry = value; next.notifyTaskEnd = value
        _ = saveV4AutomaticRules(next)
    }
    func setNotifyExpiryWarning(_ value: Bool) {
        var next = v4Settings; next.expiryNoticeEnabled = value
        _ = saveV4AutomaticRules(next)
    }
    func setV4StopOnLowPowerMode(_ value: Bool) {
        var next = v4Settings; next.stopOnLowPowerMode = value
        _ = saveV4AutomaticRules(next)
    }
    var v4RuleSummary: String {
        guard v4Settings.automaticMode == .advanced else { return L("While connected to power", "AC 연결 동안") }
        guard let preset = V4RuleEngine.activePreset(v4Settings), preset.enabled else {
            return L("Select an advanced preset", "고급 프리셋 선택 필요")
        }
        return preset.name + " · " + L("\(preset.groups.count) groups", "조건 묶음 \(preset.groups.count)개")
    }
    func setV4BasicAutomaticMode() {
        var next = v4Settings; next.automaticMode = .acConnected
        _ = saveV4AutomaticRules(next)
    }
    func v4ConditionLimitation(id: UUID) -> String? {
        guard automaticEnabled, v4Settings.usesAdvancedAutomaticConditions,
              let result = userSession?.v4RuleEvaluation?.conditions.first(where: { $0.conditionID == id }) else { return nil }
        switch result.state {
        case .permissionRequired: return L("The selected condition needs permission. This group cannot start until it is available.", "선택한 조건에 권한이 필요합니다. 확인 전에는 이 묶음으로 시작하지 않습니다.")
        case .unsupported: return L("This condition is not supported by the current version. Choose another condition.", "현재 버전에서 지원하지 않는 조건입니다. 다른 조건을 선택하세요.")
        case .unknown: return L("This selected condition could not be checked. Other valid groups can still run.", "이 조건을 확인하지 못했습니다. 다른 유효한 묶음은 계속 동작할 수 있습니다.")
        case .satisfied, .notSatisfied: return nil
        }
    }
    private func v4PresetDescription(_ preset: V4Preset) -> String {
        func minute(_ value: Int) -> String { String(format: "%02d:%02d", value / 60, value % 60) }
        func condition(_ item: V4Condition) -> String {
            var detail = item.label.isEmpty ? item.target : item.label + (item.target.isEmpty ? "" : " [" + item.target + "]")
            if let window = item.timeWindow { detail = minute(window.startMinute) + "–" + minute(window.endMinute) + " · " + window.weekdays.sorted().map(String.init).joined(separator: ",") }
            if let threshold = item.threshold { detail += " ≥ " + String(format: "%.2f", threshold) }
            return (item.enabled ? "" : L("Off: ", "끔: ")) + item.kind.rawValue + (detail.isEmpty ? "" : " = " + detail)
        }
        let groups = preset.groups.map { "(" + $0.conditions.map(condition).joined(separator: " AND ") + ")" }.joined(separator: " OR ")
        let minutes = preset.nextManualMinutes.map { L("\($0) min", "\($0)분") } ?? L("Unlimited on AC", "AC 무제한")
        let options = L("display ", "화면 ") + (preset.options.display ? L("On", "켬") : L("Off", "끔")) + " · "
            + L("lid ", "덮개 ") + (preset.options.closedLid ? L("On", "켬") : L("Off", "끔"))
        return preset.name + (preset.enabled ? "" : L(" [disabled]", " [비활성]")) + " · " + minutes + " · " + options
            + (groups.isEmpty ? L(" · No conditions", " · 조건 없음") : "\n" + groups)
    }
    @discardableResult
    func saveV4AutomaticRules(_ draft: V4Settings) -> Bool {
        guard acceptingUserCommands, let controller = userSession else { return false }
        let errors = V4RuleEngine.validate(draft)
        guard errors.isEmpty, draft.generation == v4Settings.generation,
              v4ConfigurationGeneration < UInt64.max else {
            errorText = errors.isEmpty ? L("Settings changed. Review the current choices again.", "설정이 바뀌었습니다. 현재 선택을 다시 확인하세요.")
                : L("These rules could not be saved: ", "규칙을 저장하지 못했습니다: ") + errors.joined(separator: ", ")
            return false
        }
        var next = draft; next.generation = v4ConfigurationGeneration + 1
        let selected = V4RuleEngine.activePreset(next)
        let old = V4RuleEngine.activePreset(controller.v4Settings)
        let appliesDefaults = next.usesAdvancedAutomaticConditions && selected != nil
            && (next.automaticMode != controller.v4Settings.automaticMode || selected?.id != old?.id
                || selected?.options != old?.options || selected?.nextManualMinutes != old?.nextManualMinutes)
        if appliesDefaults, let selected { next.nextManualOptions = selected.options }
        return controller.setV4Settings(next, presetDefaults: appliesDefaults ? selected : nil)
    }
    @discardableResult
    func finishOnboarding(automaticEnabled: Bool, allowClosedLid: Bool) -> Bool {
        guard acceptingUserCommands, canFinishOnboarding, let controller = userSession,
              !allowClosedLid || capabilities.lidControlAvailable else { return false }
        // Reopening setup never resets an existing user's choices.
        if defaults.bool(forKey: "onboarded") { return true }
        guard controller.applyInitialChoices(automatic: automaticEnabled, allowClosedLid: allowClosedLid) else {
            errorText = L("The initial choices could not be saved. No setup completion was recorded.", "처음 선택을 저장하지 못했습니다. 설정 완료로 처리하지 않았습니다.")
            return false
        }
        finishOnboarding()
        return !needsOnboarding
    }
    func requestV4CalendarAccess() async {
        guard acceptingUserCommands, let controller = userSession else { return }
        do {
            let granted = try await controller.v4ConditionSource.requestCalendarAccess()
            if !granted { errorText = L("Calendar full access is required for the selected calendar condition.", "선택한 일정 조건에는 캘린더 전체 접근 권한이 필요합니다.") }
            controller.v4ConditionSource.refresh(force: true)
        } catch { errorText = error.localizedDescription }
    }

    var v4Document: V4SettingsDocument {
        var prefs = V4AppPreferences()
        prefs.automaticEnabled = v3Settings.automaticEnabled; prefs.allowDisplay = v3Settings.keepDisplayAwake
        prefs.allowClosedLid = v3Settings.allowClosedLid; prefs.batteryLowerBound = SafetyPolicy.floor(v3Settings.limits)
        prefs.nextManualMinutes = v3Settings.lastManualDurationSeconds.map { Int($0 / 60) }
        prefs.disconnectAction = v3Settings.disconnectAction
        prefs.notifyHeat = notifyHeat; prefs.notifyBatteryProtection = notifyBatteryProtection
        prefs.launchAtLogin = launchAtLogin; prefs.language = language.rawValue
        prefs.updateChannel = updateChannel.rawValue; prefs.automaticUpdateCheck = checkUpdates
        return V4SettingsDocument(generation: v4ConfigurationGeneration, settings: v4Settings, preferences: prefs)
    }
    func loadV4History() {
        v4ConfigurationGeneration = UInt64(max(0, defaults.integer(forKey: "v4ConfigurationGeneration")))
        if let data = defaults.data(forKey: "v4SettingsHistory") {
            if data.count <= V4SettingsTransfer.maximumBytes,
               let history = try? JSONDecoder().decode(V4SettingsHistory.self, from: data) { v4History = history }
            else { v4History.noteHistoryWriteFailure() }
        }
        // Persisted diagnostic limits are not user-configurable execution settings.
        v4History.maximumEntries = 20; v4History.maximumAge = 30 * 86400
        v4History.maximumBytes = V4SettingsTransfer.maximumBytes
        v4History.trim(now: Date().timeIntervalSince1970)
        v4PreviousDocument = v4Document
    }
    func recordV4SettingsIfChanged() {
        guard !v4HistoryTransaction, acceptingUserCommands, userSession != nil else { return }
        var after = v4Document
        guard let before = v4PreviousDocument else { v4PreviousDocument = after; return }
        guard !V4SettingsTransfer.changedParts(from: before, to: after).isEmpty else { return }
        guard v4ConfigurationGeneration < UInt64.max else { return }
        v4ConfigurationGeneration += 1; after.generation = v4ConfigurationGeneration
        after.settings.generation = v4ConfigurationGeneration
        _ = v4History.recordChange(before: before, after: after, id: UUID(), at: Date().timeIntervalSince1970, source: v4ChangeSource)
        v4PreviousDocument = after; v4ChangeSource = .user
        saveV4History()
    }
    func saveV4History() {
        guard hasCoordinatorAuthority else { return }
        defaults.set(Int(clamping: v4ConfigurationGeneration), forKey: "v4ConfigurationGeneration")
        guard let data = try? JSONEncoder().encode(v4History), data.count <= V4SettingsTransfer.maximumBytes else {
            v4History.noteHistoryWriteFailure(); return
        }
        defaults.set(data, forKey: "v4SettingsHistory")
        if !defaults.synchronize() || defaults.data(forKey: "v4SettingsHistory") != data { v4History.noteHistoryWriteFailure() }
    }
    var v4HistoryItems: [V4HistoryPresentation] {
        v4History.entries.reversed().map { entry in
            V4HistoryPresentation(id: entry.id, title: entry.source == .rollback ? L("Settings restored", "설정 되돌림")
                : entry.source == .importing ? L("Presets imported", "프리셋 가져오기") : L("Settings changed", "설정 변경"),
                date: Date(timeIntervalSince1970: entry.at),
                detail: V4SettingsTransfer.changedParts(from: entry.before, to: entry.after).map { partTitle($0) }.sorted().joined(separator: " · "))
        }
    }
    func partTitle(_ part: V4SettingsPart) -> String {
        switch part {
        case .automatic: L("AC automatic", "AC 자동")
        case .presets: L("Presets", "프리셋")
        case .manualDefaults: L("Next manual defaults", "다음 수동 기본값")
        case .notifications: L("Notifications", "알림")
        case .globalFeatures: L("Display, lid and disconnect", "화면·덮개·분리 동작")
        case .batteryProtection: L("Battery protection", "배터리 보호")
        case .application: L("App preferences", "앱 기본 설정")
        }
    }
    func historyRestorePreview(id: UUID) -> V4HistoryRestorePreview? {
        guard let entry = v4History.entries.first(where: { $0.id == id }) else { return nil }
        let parts = V4SettingsTransfer.changedParts(from: entry.before, to: v4Document)
        guard let preview = v4History.previewRollback(id: id, current: v4Document, selected: parts, activeManual: manualSessionActive) else { return nil }
        v4RollbackPreviews[id] = preview
        return V4HistoryRestorePreview(id: id, generation: preview.baseGeneration,
            groups: parts.map(\.rawValue).sorted(), summary: historyDifference(from: v4Document, to: preview.candidate, parts: parts),
            blockedReason: preview.affectsActiveManual ? L("Exclude display/lid or protection changes while a manual session is active, or finish it first.", "수동 유지 중에는 화면·덮개·보호 변경을 제외하거나 먼저 수동 유지를 끝내세요.") : nil)
    }
    private func historyDifference(from old: V4SettingsDocument, to new: V4SettingsDocument, parts: Set<V4SettingsPart>) -> String {
        func flag(_ value: Bool) -> String { value ? L("On", "켬") : L("Off", "끔") }
        func describe(_ doc: V4SettingsDocument, _ part: V4SettingsPart) -> String {
            let p = doc.preferences, s = doc.settings
            switch part {
            case .automatic: return flag(p.automaticEnabled) + " · " + (s.automaticMode == .acConnected ? L("AC connected", "AC 연결 동안") : L("Advanced conditions", "고급 조건"))
            case .presets: return s.presets.map(v4PresetDescription).joined(separator: "\n")
            case .manualDefaults: return (p.nextManualMinutes.map { L("\($0) min", "\($0)분") } ?? L("Unlimited on AC", "AC 무제한")) + " · " + L("display ", "화면 ") + flag(s.nextManualOptions.display) + " · " + L("lid ", "덮개 ") + flag(s.nextManualOptions.closedLid)
            case .notifications: return L("end ", "종료 ") + flag(s.notifyManualExpiry) + " · " + L("warning ", "예고 ") + flag(s.expiryNoticeEnabled) + " · " + L("heat ", "발열 ") + flag(p.notifyHeat) + " · " + L("battery ", "배터리 ") + flag(p.notifyBatteryProtection)
            case .globalFeatures: return L("display ", "화면 ") + flag(p.allowDisplay) + " · " + L("lid ", "덮개 ") + flag(p.allowClosedLid) + " · " + (p.disconnectAction == .sleepIfClosed ? L("Sleep on closed unplug", "닫힌 분리 시 잠자기 요청") : L("Let macOS decide Sleep", "잠자기는 macOS에 맡김"))
            case .batteryProtection: return "\(p.batteryLowerBound)% · " + L("Low Power Mode stop ", "저전력 모드 종료 ") + flag(s.stopOnLowPowerMode)
            case .application: return p.language + " · " + p.updateChannel + " · " + L("login ", "로그인 시 시작 ") + flag(p.launchAtLogin) + " · " + L("update checks ", "업데이트 확인 ") + flag(p.automaticUpdateCheck)
            }
        }
        return parts.sorted { $0.rawValue < $1.rawValue }.map { partTitle($0) + ": " + describe(old, $0) + " → " + describe(new, $0) }.joined(separator: "\n")
    }
    @discardableResult
    func applyHistoryRestore(id: UUID, generation: UInt64, groups: Set<String>) -> Bool {
        guard acceptingUserCommands, let original = v4RollbackPreviews[id], generation == v4ConfigurationGeneration,
              original.baseFingerprint == V4SettingsTransfer.fingerprint(v4Document),
              let selected = validParts(groups), !selected.isEmpty,
              let preview = v4History.previewRollback(id: id, current: v4Document, selected: selected, activeManual: manualSessionActive) else {
            errorText = L("The settings or history changed. Review the differences again.", "설정이나 이력이 바뀌었습니다. 차이를 다시 확인하세요."); return false
        }
        let result = v4History.applyRollback(id: id, preview: preview, current: v4Document, activeManual: manualSessionActive)
        guard let document = result.document else { errorText = result.reason; return false }
        v4ChangeSource = .rollback
        return applyV4Document(document)
    }
    private func validParts(_ names: Set<String>) -> Set<V4SettingsPart>? {
        let parts = names.compactMap(V4SettingsPart.init(rawValue:))
        return parts.count == names.count ? Set(parts) : nil
    }
    func deleteV4History(id: UUID) { guard acceptingUserCommands else { return }; v4History.delete(id: id); v4RollbackPreviews[id] = nil; saveV4History() }
    func clearV4History() { guard acceptingUserCommands else { return }; v4History.deleteAll(); v4RollbackPreviews = [:]; saveV4History() }
    func exportV4Settings() -> Data? { try? V4SettingsTransfer.encode(v4Document) }
    func previewV4Import(_ data: Data) -> String? {
        guard let imported = try? V4SettingsTransfer.decode(data) else { return nil }
        var replacements: [UUID: UUID] = [:]
        for preset in imported.settings.presets {
            replacements[preset.id] = UUID()
            for group in preset.groups { replacements[group.id] = UUID(); for condition in group.conditions { replacements[condition.id] = UUID() } }
        }
        let preview = V4SettingsTransfer.previewImport(imported, current: v4Document, replacementIDs: replacements, capabilities: userSession?.v4ReviewCapabilities(for: imported.settings) ?? [])
        guard !preview.issues.contains(where: \.blocking) else { return nil }
        v4ImportCandidate = (data, preview)
        let review = imported.settings.presets.map(v4PresetDescription).joined(separator: "\n\n")
        let limitations = preview.issues.filter { !$0.blocking }.map { issue in
            issue.code.hasPrefix("permission-required")
                ? L("Permission needed: ", "권한 필요: ") + issue.code.components(separatedBy: ":").last!
                : L("Not available in this version: ", "현재 버전에서 사용할 수 없음: ") + issue.code.components(separatedBy: ":").last!
        }
        return L("Add \(imported.settings.presets.count) disabled preset copies. Current work and automatic selection are preserved.", "프리셋 \(imported.settings.presets.count)개를 비활성 사본으로 추가합니다. 현재 작업과 자동 선택은 보존됩니다.")
            + "\n\n" + review + (limitations.isEmpty ? "" : "\n\n" + Array(Set(limitations)).sorted().joined(separator: "\n"))
            + L("\nOther required permissions and current conditions are checked when the copied preset is explicitly selected.", "\n그 밖의 권한·현재 조건은 복사본을 직접 선택해 적용할 때 다시 확인합니다.")
    }
    @discardableResult
    func applyV4Import(_ data: Data) -> Bool {
        guard let candidate = v4ImportCandidate, candidate.0 == data else { return false }
        let result = V4SettingsTransfer.apply(candidate.1, current: v4Document, activeManual: manualSessionActive)
        guard let document = result.document else { errorText = result.reason; return false }
        v4ImportCandidate = nil; v4ChangeSource = .importing
        return applyV4Document(document)
    }
    private func applyV4Document(_ document: V4SettingsDocument) -> Bool {
        guard acceptingUserCommands else { return false }
        let selectedChannel = UpdateChannel(rawValue: document.preferences.updateChannel)
        guard selectedChannel == updateChannel || canSelectUpdateChannel else {
            v4ChangeSource = .user
            errorText = L("An update is in progress. Review this settings selection after it finishes.", "업데이트가 진행 중입니다. 끝난 뒤 선택한 설정을 다시 확인하세요.")
            return false
        }
        v4HistoryTransaction = true
        defer { v4HistoryTransaction = false; recordV4SettingsIfChanged() }
        guard userSession?.applyConfiguration(document) == true else {
            v4ChangeSource = .user; errorText = L("Settings could not be saved; previous choices remain.", "설정을 저장하지 못했습니다. 이전 선택을 유지합니다."); return false
        }
        // External OS registration is reported independently from the atomic preferences record.
        if let choice = LanguageChoice(rawValue: document.preferences.language) { language = choice }
        notifyHeat = document.preferences.notifyHeat
        notifyBatteryProtection = document.preferences.notifyBatteryProtection
        if let channel = selectedChannel, channel != updateChannel { _ = setUpdateChannel(channel) }
        checkUpdates = document.preferences.automaticUpdateCheck
        if document.preferences.launchAtLogin != launchAtLogin { setLaunchAtLogin(document.preferences.launchAtLogin) }
        recordV4SettingsIfChanged()
        return true
    }
}
