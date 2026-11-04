import Foundation

/// Persistent choices only. Runtime requests, permissions and recovery journals never belong here.
public struct V4Settings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    public var generation: UInt64 = 0
    public var automaticMode: V4AutomaticMode = .acConnected
    public var activePresetID: UUID?
    public var presets: [V4Preset] = []
    public var nextManualOptions = V4RequestOptions(display: true, closedLid: true)
    public var notifyManualExpiry = false
    public var notifyTaskEnd = false
    public var expiryNoticeEnabled = false
    public static let expiryNoticeMinuteChoices = [1, 2, 5, 10, 15]
    public var expiryNoticeMinutes = 5
    public var notificationSound = false
    public var stopOnLowPowerMode = false
    public var experimentalProvidersEnabled = false
    public var usesAdvancedAutomaticConditions: Bool { automaticMode == .advanced }
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, generation, automaticMode, activePresetID, presets, nextManualOptions, notifyManualExpiry
        case notifyTaskEnd, expiryNoticeEnabled, expiryNoticeMinutes, notificationSound, stopOnLowPowerMode, experimentalProvidersEnabled
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        generation = try c.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        automaticMode = try c.decodeIfPresent(V4AutomaticMode.self, forKey: .automaticMode) ?? .acConnected
        activePresetID = try c.decodeIfPresent(UUID.self, forKey: .activePresetID)
        presets = try c.decodeIfPresent([V4Preset].self, forKey: .presets) ?? []
        nextManualOptions = try c.decodeIfPresent(V4RequestOptions.self, forKey: .nextManualOptions)
            ?? .init(display: true, closedLid: true)
        notifyManualExpiry = try c.decodeIfPresent(Bool.self, forKey: .notifyManualExpiry) ?? false
        notifyTaskEnd = try c.decodeIfPresent(Bool.self, forKey: .notifyTaskEnd) ?? false
        expiryNoticeEnabled = try c.decodeIfPresent(Bool.self, forKey: .expiryNoticeEnabled) ?? false
        expiryNoticeMinutes = try c.decodeIfPresent(Int.self, forKey: .expiryNoticeMinutes) ?? 5
        notificationSound = try c.decodeIfPresent(Bool.self, forKey: .notificationSound) ?? false
        stopOnLowPowerMode = try c.decodeIfPresent(Bool.self, forKey: .stopOnLowPowerMode) ?? false
        experimentalProvidersEnabled = try c.decodeIfPresent(Bool.self, forKey: .experimentalProvidersEnabled) ?? false
    }
}

public enum V4AutomaticMode: String, Codable, Sendable { case acConnected, advanced }
public enum V4Power: String, Codable, Sendable { case ac, battery, ups, unknown }
public enum V4ObservationState: String, Codable, Sendable {
    case satisfied, notSatisfied, unknown, permissionRequired, unsupported
}
public enum V4CapabilityStatus: String, Codable, Sendable { case supported, experimental, unsupported }

public enum V4ConditionKind: String, Codable, CaseIterable, Sendable {
    case appRunning, appFrontmost, process, timeWindow, wifiSSID, vpn, ipAddress, dns
    case usb, bluetooth, volume, audioOutput, externalDisplay, cpuLoad, networkThroughput
    case calendar, microphoneInput, cameraUsage, audioPlayback, download, taskEvent, unsupported

    public var providerID: String {
        switch self {
        case .appRunning, .appFrontmost: return "apps"
        case .process: return "processes"
        case .timeWindow: return "clock"
        case .wifiSSID, .vpn, .ipAddress, .dns: return "network"
        case .usb, .bluetooth: return "devices"
        case .volume: return "volumes"
        case .audioOutput: return "audioDevices"
        case .externalDisplay: return "displays"
        case .cpuLoad: return "cpu"
        case .networkThroughput: return "throughput"
        case .calendar: return "calendar"
        case .microphoneInput, .cameraUsage, .audioPlayback: return "media"
        case .download: return "downloads"
        case .taskEvent: return "workEvents"
        case .unsupported: return "unsupported"
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = Self(rawValue: try c.decode(String.self)) ?? .unsupported
    }
}

/// AND within a group, OR between groups. The selected power/safety gate is outside this tree.
public struct V4RuleGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var conditions: [V4Condition]
    public init(id: UUID, conditions: [V4Condition]) { self.id = id; self.conditions = conditions }
}

public struct V4Condition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: V4ConditionKind
    /// Opaque selected bundle/device/calendar/path identity. Never a complete process argument list.
    public var target: String
    public var label: String
    /// CPU is normalized 0...100; network throughput is bytes/second.
    public var threshold: Double?
    public var timeWindow: V4TimeWindow?
    public var enabled: Bool
    public init(id: UUID, kind: V4ConditionKind, target: String = "", label: String = "",
                threshold: Double? = nil, timeWindow: V4TimeWindow? = nil, enabled: Bool = true) {
        self.id = id; self.kind = kind; self.target = target; self.label = label
        self.threshold = threshold; self.timeWindow = timeWindow; self.enabled = enabled
    }
}

public struct V4TimeWindow: Codable, Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int
    /// Calendar weekday numbering: Sunday=1. Empty means every day; the start day owns overnight windows.
    public var weekdays: Set<Int>
    public init(startMinute: Int, endMinute: Int, weekdays: Set<Int> = []) {
        self.startMinute = startMinute; self.endMinute = endMinute; self.weekdays = weekdays
    }
    public var isValid: Bool {
        (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute)
            && weekdays.allSatisfy { (1...7).contains($0) }
    }
    private enum CodingKeys: String, CodingKey { case startMinute, endMinute, weekdays }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startMinute = try c.decode(Int.self, forKey: .startMinute)
        endMinute = try c.decode(Int.self, forKey: .endMinute)
        weekdays = Set(try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? [])
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startMinute, forKey: .startMinute); try c.encode(endMinute, forKey: .endMinute)
        try c.encode(weekdays.sorted(), forKey: .weekdays)
    }
}

public struct V4RequestOptions: Codable, Equatable, Sendable {
    public var display = false
    public var closedLid = false
    public var releaseDisplayAfterIdle: Double?
    public init(display: Bool = false, closedLid: Bool = false, releaseDisplayAfterIdle: Double? = nil) {
        self.display = display; self.closedLid = closedLid; self.releaseDisplayAfterIdle = releaseDisplayAfterIdle
    }
}

public struct V4Preset: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var groups: [V4RuleGroup]
    public var options: V4RequestOptions
    public var nextManualMinutes: Int?
    /// Imported copies are disabled; preview/selection is not application.
    public var enabled: Bool
    public init(id: UUID, name: String, groups: [V4RuleGroup], options: V4RequestOptions = .init(),
                nextManualMinutes: Int? = 30, enabled: Bool = true) {
        self.id = id; self.name = name; self.groups = groups; self.options = options
        self.nextManualMinutes = nextManualMinutes; self.enabled = enabled
    }
}

public struct V4Capability: Codable, Equatable, Sendable {
    public var kind: V4ConditionKind
    public var status: V4CapabilityStatus
    public var permissionGranted: Bool
    public init(kind: V4ConditionKind, status: V4CapabilityStatus, permissionGranted: Bool = true) {
        self.kind = kind; self.status = status; self.permissionGranted = permissionGranted
    }
}

/// Replaced on boot/owner/power generation change. Comparing IDs is not OS authorization.
public struct V4Scope: Codable, Equatable, Hashable, Sendable {
    public var bootID: String
    public var ownerID: String
    public var powerGeneration: UInt64
    public init(bootID: String, ownerID: String, powerGeneration: UInt64) {
        self.bootID = bootID; self.ownerID = ownerID; self.powerGeneration = powerGeneration
    }
    public var isValid: Bool { !bootID.isEmpty && bootID != "unknown" && !ownerID.isEmpty }
}

public struct V4ExecutionContext: Codable, Equatable, Sendable {
    public var scope: V4Scope
    public var power: V4Power
    /// Earliest expiry of required power/thermal/owner facts, in injected continuous seconds.
    public var validUntil: Double
    public var automaticEnabled: Bool
    public var paused: Bool
    public var protectionActive: Bool
    public var ownerValid: Bool
    public var isMacBook: Bool
    public var lidClosed: Bool?
    public var allowDisplay: Bool
    public var allowClosedLid: Bool
    /// Absent in older saved contexts: automatic acquisition still defaults to AC.
    public var automaticPowerCondition: PowerCondition?
    public init(scope: V4Scope, power: V4Power, validUntil: Double, automaticEnabled: Bool = true,
                paused: Bool = false, protectionActive: Bool = false, ownerValid: Bool = true,
                isMacBook: Bool = true, lidClosed: Bool? = nil,
                allowDisplay: Bool = false, allowClosedLid: Bool = false,
                automaticPowerCondition: PowerCondition? = nil) {
        self.scope = scope; self.power = power; self.validUntil = validUntil
        self.automaticEnabled = automaticEnabled; self.paused = paused; self.protectionActive = protectionActive
        self.ownerValid = ownerValid; self.isMacBook = isMacBook; self.lidClosed = lidClosed
        self.allowDisplay = allowDisplay; self.allowClosedLid = allowClosedLid
        self.automaticPowerCondition = automaticPowerCondition
    }
    public func permitsWork(at now: Double) -> Bool {
        now.isFinite && validUntil.isFinite && now < validUntil && scope.isValid && ownerValid
            && !paused && !protectionActive && (power == .ac || power == .battery)
    }
    public func permitsAutomatic(at now: Double) -> Bool {
        guard permitsWork(at: now), automaticEnabled else { return false }
        switch automaticPowerCondition ?? .ac {
        case .ac: return power == .ac
        case .battery: return power == .battery
        case .any: return power == .ac || power == .battery
        }
    }
}

public struct V4Observation: Codable, Equatable, Sendable {
    public var conditionID: UUID
    public var scope: V4Scope
    public var state: V4ObservationState
    public var observedAt: Double
    public var validUntil: Double
    public var numericValue: Double?
    public init(conditionID: UUID, scope: V4Scope, state: V4ObservationState,
                observedAt: Double, validUntil: Double, numericValue: Double? = nil) {
        self.conditionID = conditionID; self.scope = scope; self.state = state
        self.observedAt = observedAt; self.validUntil = validUntil; self.numericValue = numericValue
    }
    public func isFresh(at now: Double, scope: V4Scope) -> Bool {
        self.scope == scope && now.isFinite && observedAt.isFinite && validUntil.isFinite
            && observedAt <= now && observedAt < validUntil && now < validUntil
    }
}

public struct V4AutomaticGate: Codable, Equatable, Sendable {
    public var isSatisfied: Bool
    public var validUntil: Double?
    public var reason: String
    public init(isSatisfied: Bool, validUntil: Double?, reason: String) {
        self.isSatisfied = isSatisfied; self.validUntil = validUntil; self.reason = reason
    }
}

/// Read-only view of the existing manual policy. It does not grant or mutate execution authority.
public struct V4ManualSnapshot: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var revisionID: UUID
    public var ownerID: String
    public var startedAt: Double
    public var deadline: Double?
    public var batteryStartedAt: Double?
    public var batteryTimeLimit: WorkSessionBatteryLimit?
    public var batteryLimitEnforced: Bool?
    public var confirmed: Bool
    public var canExtend15: Bool
    public var canExtend30: Bool
    public var options: V4RequestOptions
    public init(requestID: UUID, revisionID: UUID, ownerID: String, startedAt: Double, deadline: Double?,
                batteryStartedAt: Double? = nil, confirmed: Bool = true,
                canExtend15: Bool = false, canExtend30: Bool = false, options: V4RequestOptions = .init(),
                batteryTimeLimit: WorkSessionBatteryLimit? = nil, batteryLimitEnforced: Bool? = nil) {
        self.requestID = requestID; self.revisionID = revisionID; self.ownerID = ownerID
        self.startedAt = startedAt; self.deadline = deadline; self.batteryStartedAt = batteryStartedAt
        self.confirmed = confirmed; self.canExtend15 = canExtend15; self.canExtend30 = canExtend30
        self.options = options
        self.batteryTimeLimit = batteryTimeLimit
        self.batteryLimitEnforced = batteryLimitEnforced
    }
    public func isActive(at now: Double) -> Bool {
        now.isFinite && startedAt.isFinite && startedAt <= now && confirmed && !ownerID.isEmpty
            && deadline.map { $0.isFinite && now < $0 } != false
            && (batteryLimitEnforced == false || batteryStartedAt.map { start in
                start.isFinite && start <= now
                    && ((batteryTimeLimit ?? .twoHours).seconds.map { now < start + $0 } ?? true)
            } != false)
    }
}
