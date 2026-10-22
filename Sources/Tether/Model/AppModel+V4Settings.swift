import Foundation
import TetherCore

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
        guard v4Settings.automaticMode == .advanced else { return v3Settings.condition.title }
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
        guard acceptingUserCommands, canFinishOnboarding(allowClosedLid: allowClosedLid), let controller = userSession,
              !allowClosedLid || capabilities.lidControlAvailable else { return false }
        // Reopening setup never resets an existing user's choices.
        if defaults.bool(forKey: "onboarded") {
            if allowClosedLid != controller.settings.allowClosedLid {
                guard !allowClosedLid, controller.disableClosedLidForGeneralSetup() else { return false }
            }
            finishOnboarding()
            return !needsOnboarding
        }
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
    /// Keep only the generation used to reject stale rule/import drafts.
    /// The retired settings history is neither loaded, collected nor replayed.
    func loadV4ConfigurationGeneration() {
        v4ConfigurationGeneration = UInt64(max(0, defaults.integer(forKey: "v4ConfigurationGeneration")))
        v4PreviousDocument = v4Document
    }
    func refreshV4ConfigurationGeneration() {
        guard !v4ConfigurationTransaction, acceptingUserCommands, userSession != nil else { return }
        var after = v4Document
        guard let before = v4PreviousDocument else { v4PreviousDocument = after; return }
        guard !V4SettingsTransfer.changedParts(from: before, to: after).isEmpty,
              v4ConfigurationGeneration < UInt64.max else { return }
        v4ConfigurationGeneration += 1
        after.generation = v4ConfigurationGeneration
        after.settings.generation = v4ConfigurationGeneration
        v4PreviousDocument = after
        defaults.set(Int(clamping: v4ConfigurationGeneration), forKey: "v4ConfigurationGeneration")
    }
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
        v4ImportCandidate = nil
        return applyV4Document(document)
    }
    private func applyV4Document(_ document: V4SettingsDocument) -> Bool {
        guard acceptingUserCommands else { return false }
        let selectedChannel = UpdateChannel(rawValue: document.preferences.updateChannel)
        guard selectedChannel == updateChannel || canSelectUpdateChannel else {
            errorText = L("An update is in progress. Review this settings selection after it finishes.", "업데이트가 진행 중입니다. 끝난 뒤 선택한 설정을 다시 확인하세요.")
            return false
        }
        v4ConfigurationTransaction = true
        defer { v4ConfigurationTransaction = false; refreshV4ConfigurationGeneration() }
        guard userSession?.applyConfiguration(document) == true else {
            errorText = L("Settings could not be saved; previous choices remain.", "설정을 저장하지 못했습니다. 이전 선택을 유지합니다."); return false
        }
        // External OS registration is reported independently from the atomic preferences record.
        if let choice = LanguageChoice(rawValue: document.preferences.language) { language = choice }
        notifyHeat = document.preferences.notifyHeat
        notifyBatteryProtection = document.preferences.notifyBatteryProtection
        if let channel = selectedChannel, channel != updateChannel { _ = setUpdateChannel(channel) }
        checkUpdates = document.preferences.automaticUpdateCheck
        if document.preferences.launchAtLogin != launchAtLogin { setLaunchAtLogin(document.preferences.launchAtLogin) }
        refreshV4ConfigurationGeneration()
        return true
    }
}
