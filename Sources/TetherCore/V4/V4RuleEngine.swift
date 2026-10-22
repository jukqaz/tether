import Foundation

public struct V4ConditionResult: Codable, Equatable, Sendable {
    public var conditionID: UUID
    public var state: V4ObservationState
    public var validUntil: Double?
    public var reason: String
}

public struct V4RuleEvaluation: Codable, Equatable, Sendable {
    public var gate: V4AutomaticGate
    public var conditions: [V4ConditionResult]
    public var satisfiedGroupIDs: [UUID]
    public var options: V4RequestOptions
}

public enum V4RuleEngine {
    public static let maximumPresets = 64
    public static let maximumConditions = 256

    /// Selected providers only. Callers must not register/poll providers not in this set.
    public static func requiredConditions(settings: V4Settings, automaticEnabled: Bool) -> [V4Condition] {
        guard automaticEnabled, settings.version == V4Settings.currentVersion,
              settings.usesAdvancedAutomaticConditions,
              let preset = activePreset(settings), preset.enabled else { return [] }
        return preset.groups.flatMap(\.conditions).filter { $0.enabled && $0.kind != .timeWindow }
    }

    public static func validate(_ settings: V4Settings) -> [String] {
        guard settings.version == V4Settings.currentVersion else { return ["unsupported-version"] }
        guard settings.presets.count <= maximumPresets else { return ["too-many-presets"] }
        var errors: [String] = []
        if let idle = settings.nextManualOptions.releaseDisplayAfterIdle, ![300.0, 600, 900, 1800].contains(idle) {
            errors.append("invalid-manual-display-idle")
        }
        var presetIDs: Set<UUID> = []
        var conditionIDs: Set<UUID> = []
        var total = 0
        for preset in settings.presets {
            if !presetIDs.insert(preset.id).inserted { errors.append("duplicate-preset-id") }
            if preset.name.isEmpty || preset.name.count > 128 { errors.append("invalid-preset-name") }
            if let minutes = preset.nextManualMinutes, ![5, 10, 15, 30, 60, 120].contains(minutes) {
                errors.append("invalid-manual-default")
            }
            if let idle = preset.options.releaseDisplayAfterIdle, ![300.0, 600, 900, 1800].contains(idle) {
                errors.append("invalid-display-idle")
            }
            var groupIDs: Set<UUID> = []
            for group in preset.groups {
                if !groupIDs.insert(group.id).inserted { errors.append("duplicate-group-id") }
                if group.conditions.isEmpty { errors.append("empty-group") }
                for condition in group.conditions {
                    total += 1
                    if !conditionIDs.insert(condition.id).inserted { errors.append("duplicate-condition-id") }
                    if condition.kind == .unsupported { errors.append("unsupported-condition") }
                    if condition.target.count > 4096 || condition.label.count > 256 { errors.append("oversized-condition") }
                    if condition.kind == .timeWindow, condition.timeWindow?.isValid != true { errors.append("invalid-time-window") }
                    if let threshold = condition.threshold,
                       !threshold.isFinite || threshold < 0 || (condition.kind == .cpuLoad && threshold > 100) {
                        errors.append("invalid-threshold")
                    }
                }
            }
        }
        if total > maximumConditions { errors.append("too-many-conditions") }
        return errors
    }

    public static func activePreset(_ settings: V4Settings) -> V4Preset? {
        guard let id = settings.activePresetID else { return nil }
        let matches = settings.presets.filter { $0.id == id }
        return matches.count == 1 ? matches.first : nil
    }

    public static func evaluate(settings: V4Settings, context: V4ExecutionContext,
                                observations: [V4Observation], capabilities: [V4Capability],
                                now: Double, wallDate: Date, calendar: Calendar) -> V4RuleEvaluation {
        func blocked(_ reason: String, conditions: [V4ConditionResult] = []) -> V4RuleEvaluation {
            .init(gate: .init(isSatisfied: false, validUntil: nil, reason: reason),
                  conditions: conditions, satisfiedGroupIDs: [], options: .init())
        }
        guard settings.version == V4Settings.currentVersion else { return blocked("unsupported-settings") }
        guard context.permitsAutomatic(at: now) else { return blocked("automatic-gate-blocked") }
        if settings.automaticMode == .acConnected {
            return .init(gate: .init(isSatisfied: true, validUntil: context.validUntil,
                                    reason: context.power == .ac ? "ac-connected" : "selected-battery-power"),
                         conditions: [], satisfiedGroupIDs: [], options: .init(display: true, closedLid: true))
        }
        guard let preset = activePreset(settings), preset.enabled, !preset.groups.isEmpty else {
            return blocked("advanced-rules-unavailable")
        }
        var selected = V4Settings()
        selected.presets = [preset]
        guard validate(selected).isEmpty else { return blocked("invalid-rules") }
        let groupedObservations = Dictionary(grouping: observations, by: \.conditionID)
        let groupedCapabilities = Dictionary(grouping: capabilities, by: \.kind)
        var results: [V4ConditionResult] = []
        var satisfied: [UUID] = []
        var deadlines: [Double] = []
        for group in preset.groups {
            var groupDeadline = context.validUntil
            var groupSatisfied = !group.conditions.isEmpty
            for condition in group.conditions {
                let result = evaluateCondition(condition, context: context,
                    observations: groupedObservations[condition.id] ?? [],
                    capabilities: groupedCapabilities[condition.kind] ?? [],
                    experimentalAllowed: settings.experimentalProvidersEnabled,
                    now: now, wallDate: wallDate, calendar: calendar)
                results.append(result)
                if result.state == .satisfied, let expiry = result.validUntil {
                    groupDeadline = min(groupDeadline, expiry)
                } else { groupSatisfied = false }
            }
            if groupSatisfied && groupDeadline > now {
                satisfied.append(group.id); deadlines.append(groupDeadline)
            }
        }
        guard let expiry = deadlines.max() else { return blocked("no-satisfied-group", conditions: results) }
        return .init(gate: .init(isSatisfied: true, validUntil: expiry, reason: "advanced-conditions"),
                     conditions: results, satisfiedGroupIDs: satisfied, options: preset.options)
    }

    private static func evaluateCondition(_ condition: V4Condition, context: V4ExecutionContext,
        observations: [V4Observation], capabilities: [V4Capability], experimentalAllowed: Bool,
        now: Double, wallDate: Date, calendar: Calendar) -> V4ConditionResult {
        func result(_ state: V4ObservationState, _ reason: String, _ expiry: Double? = nil) -> V4ConditionResult {
            .init(conditionID: condition.id, state: state, validUntil: expiry, reason: reason)
        }
        guard condition.enabled else { return result(.notSatisfied, "condition-disabled") }
        if condition.kind == .timeWindow {
            guard let window = condition.timeWindow, window.isValid else { return result(.unsupported, "invalid-time-window") }
            let evaluated = window.evaluate(at: wallDate, calendar: calendar)
            guard evaluated.satisfied, let end = evaluated.endsAt else { return result(.notSatisfied, "outside-time-window") }
            let expiry = min(context.validUntil, now + end.timeIntervalSince(wallDate))
            return expiry > now ? result(.satisfied, "time-window", expiry) : result(.unknown, "invalid-time-boundary")
        }
        guard condition.kind != .unsupported, capabilities.count == 1, let capability = capabilities.first,
              capability.status == .supported || (capability.status == .experimental && experimentalAllowed) else {
            return result(.unsupported, "provider-unavailable")
        }
        guard capability.permissionGranted else { return result(.permissionRequired, "permission-required") }
        guard observations.count == 1, let observation = observations.first,
              observation.isFresh(at: now, scope: context.scope) else { return result(.unknown, "observation-unavailable") }
        let state = observation.state
        if [.cpuLoad, .networkThroughput].contains(condition.kind), state == .satisfied || state == .notSatisfied {
            guard let value = observation.numericValue, value.isFinite, value >= 0,
                  condition.kind != .cpuLoad || value <= 100 else { return result(.unknown, "invalid-activity-value") }
            // The shared provider already applies its mean/hysteresis/grace window.
            // Re-thresholding numericValue here would revoke a still-valid release grace.
        }
        return result(state, state.rawValue, min(context.validUntil, observation.validUntil))
    }
}

public extension V4TimeWindow {
    func evaluate(at date: Date, calendar: Calendar) -> (satisfied: Bool, endsAt: Date?) {
        guard isValid, date.timeIntervalSince1970.isFinite else { return (false, nil) }
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, let hour = c.hour, let minute = c.minute else { return (false, nil) }
        let minutes = hour * 60 + minute
        func starts(_ day: Int) -> Bool { weekdays.isEmpty || weekdays.contains(day) }
        let active: Bool
        if startMinute < endMinute {
            active = starts(weekday) && minutes >= startMinute && minutes < endMinute
        } else if minutes >= startMinute { active = starts(weekday) }
        else { active = starts(weekday == 1 ? 7 : weekday - 1) && minutes < endMinute }
        guard active else { return (false, nil) }
        let end = calendar.nextDate(after: date, matching: DateComponents(hour: endMinute / 60, minute: endMinute % 60),
                                    matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        return (true, end)
    }
}

public struct V4ActivitySample: Codable, Equatable, Sendable {
    public var at: Double
    public var value: Double
    public init(at: Double, value: Double) { self.at = at; self.value = value }
}

public enum V4ActivityWindow {
    /// No grace survives stale observations. A quiet window never means task completion.
    public static func evaluate(samples: [V4ActivitySample], now: Double, threshold: Double,
                                window: Double = 10, freshness: Double = 15,
                                lastSatisfiedAt: Double? = nil, releaseGrace: Double = 30,
                                previouslyAboveThreshold: Bool = false,
                                offThreshold: Double? = nil) -> V4ObservationState {
        guard now.isFinite, threshold.isFinite, threshold >= 0, window > 0, freshness > 0,
              releaseGrace.isFinite, releaseGrace >= 0 else { return .unknown }
        let values = samples.filter { $0.at.isFinite && $0.value.isFinite && $0.value >= 0 && $0.at <= now && now - $0.at <= window }
        guard let last = values.map(\.at).max(), now - last < freshness, !values.isEmpty else { return .unknown }
        let average = values.reduce(0) { $0 + $1.value / Double(values.count) }
        let off = offThreshold ?? threshold * 0.8
        guard off.isFinite, off >= 0, off <= threshold else { return .unknown }
        if average >= threshold || (previouslyAboveThreshold && average >= off) { return .satisfied }
        if let lastSatisfiedAt, lastSatisfiedAt.isFinite, lastSatisfiedAt <= now,
           now - lastSatisfiedAt < releaseGrace { return .satisfied }
        return .notSatisfied
    }
}
