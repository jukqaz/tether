import Foundation

/// Written by the helper, read by the menu bar app.
public struct Status: Codable, Equatable, Sendable {
    /// Older helpers did not report a build number. Nil requires an upgrade even when the
    /// marketing version happens to match a newer app build.
    public var build: Int?
    public var workSessionCoordinatorVersion: Int?
    public var workSession: WorkSessionLease?
    public var matchesCurrentBuild: Bool { version == TetherPaths.version && build == TetherPaths.build }
    public var updatedAt: Double
    public var version: String
    public var enabled: Bool
    public var power: PowerSource
    public var lidClosed: Bool
    public var sleepDisabled: Bool
    /// Availability is explicit so an old status or failed reader cannot imply an open
    /// lid, a cleared override or a full wake. Required legacy Bool fields remain compatible.
    public var lidObservationAvailable: Bool?
    public var sleepOverrideObservationAvailable: Bool?
    /// IOKit sleep/wake notifications were registered for this helper process.
    /// Nil means an older helper did not report this independent observation.
    public var systemPowerObservationAvailable: Bool?
    public var fullWake: Bool?
    public var observedLidClosed: Bool? { lidObservationAvailable == true ? lidClosed : nil }
    public var observedSleepDisabled: Bool? { sleepOverrideObservationAvailable == true ? sleepDisabled : nil }
    public var lastEvent: EventKind?
    public var lastEventAt: Double?
    /// Effective battery hold deadline, nil when no hold is armed.
    public var batteryHoldUntil: Double?
    public var batteryTemperature: Double?
    public var thermal: Int?
    public var batteryPercent: Int?
    /// The most recent end of a battery hold, kept apart from `lastEvent` (which the sleep
    /// that follows overwrites) so the app can report it after wake.
    public var lastHoldEnd: HoldEnd?
    public var lastHoldEndAt: Double?
    /// When the armed hold was first seen (the start of its countdown).
    public var batteryHoldSince: Double?
    /// The heat guard has Low Power Mode on (lid closed on AC, running hot).
    public var heatGuard: Bool?
    /// The most recent observed critical thermal-state alert, for the app to notify once.
    public var thermalAlertAt: Double?
    /// Legacy field name: time of the closed-lid thermal protection decision, not proof of Sleep.
    public var overheatSleepAt: Double?
    /// Legacy field name: time of the weak-charger protection decision, not proof of Sleep.
    public var weakChargerSleepAt: Double?
    public var protection: ProtectionStatus?
    public var displaySleeping: Bool?
    public var displayRecovery: DisplayRecoveryStatus?
    public var externalDisplay: Bool?
    public var displayTopology: DisplayTopology?
    /// Observed OS policy and matched wired path, not proof of actual Sleep/Wake or panel power.
    public var nativeDisplayVerified: Bool?
    public var ownsOverride: Bool?
    public var appConnected: Bool?
    public var appPID: Int32?
    public var guiSessionAuthority: GUISessionAuthorityStatus?
    public var powerReturnConfirmed: Bool?
    /// Own release and completed system sleep are different outcomes.
    public var sleepDeferralReason: String?
    public var manualSession: ManualSessionStatus?

    /// Interpret recovery only for the current closed-lid hold. A previous
    /// topology's retry phase is history, not a warning about an open display.
    public func currentDisplayRecovery(now: Date = Date()) -> DisplayRecoveryStatus? {
        let age = now.timeIntervalSince1970 - updatedAt
        guard age.isFinite, age >= 0, age < 30,
              observedLidClosed == true, fullWake == true,
              observedSleepDisabled == true, ownsOverride == true, appConnected == true,
              let topology = displayTopology, topology != .unknown,
              let recovery = displayRecovery else { return nil }
        if topology.mayHaveExternal {
            let phase: DisplaySleepGate.Phase = switch displaySleeping {
            case true: .asleep
            case false: .deferred
            case nil: .unavailable
            }
            return DisplayRecoveryStatus(phase: phase, requests: recovery.requests)
        }
        return recovery.phase == .inactive ? nil : recovery
    }

    public var sleepDeferralSummary: String? {
        switch sleepDeferralReason {
        case "otherRequests": L("Automatic sleep deferred for another app's work request", "다른 앱의 작업 유지 요청으로 자동 잠자기를 보류했습니다")
        case "observationUnavailable": L("Automatic sleep deferred because request observation failed", "작업 유지 요청을 확인하지 못해 자동 잠자기를 보류했습니다")
        default: nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case lidObservationAvailable, sleepOverrideObservationAvailable, systemPowerObservationAvailable, fullWake
        case workSessionCoordinatorVersion, workSession
        case displayTopology, nativeDisplayVerified, ownsOverride, appConnected, appPID, guiSessionAuthority, powerReturnConfirmed, displayRecovery, sleepDeferralReason, manualSession
        case updatedAt, version, build, enabled, power, lidClosed, sleepDisabled, lastEvent, lastEventAt
        case batteryHoldUntil, batteryTemperature, thermal, batteryPercent, lastHoldEnd, lastHoldEndAt
        case batteryHoldSince, heatGuard, thermalAlertAt, overheatSleepAt, weakChargerSleepAt, protection, displaySleeping, externalDisplay
    }

    /// Tolerates an event this build does not know, so an app and helper from different
    /// versions still read each other's status.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        version = try c.decode(String.self, forKey: .version)
        build = try c.decodeIfPresent(Int.self, forKey: .build)
        workSessionCoordinatorVersion = try? c.decodeIfPresent(Int.self, forKey: .workSessionCoordinatorVersion)
        workSession = try? c.decodeIfPresent(WorkSessionLease.self, forKey: .workSession)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        power = (try? c.decode(PowerSource.self, forKey: .power)) ?? .unknown
        lidClosed = try c.decode(Bool.self, forKey: .lidClosed)
        sleepDisabled = try c.decode(Bool.self, forKey: .sleepDisabled)
        lidObservationAvailable = try? c.decodeIfPresent(Bool.self, forKey: .lidObservationAvailable)
        sleepOverrideObservationAvailable = try? c.decodeIfPresent(Bool.self, forKey: .sleepOverrideObservationAvailable)
        systemPowerObservationAvailable = try? c.decodeIfPresent(Bool.self, forKey: .systemPowerObservationAvailable)
        fullWake = try? c.decodeIfPresent(Bool.self, forKey: .fullWake)
        lastEvent = try? c.decodeIfPresent(EventKind.self, forKey: .lastEvent)
        lastEventAt = try c.decodeIfPresent(Double.self, forKey: .lastEventAt)
        batteryHoldUntil = try? c.decodeIfPresent(Double.self, forKey: .batteryHoldUntil)
        batteryTemperature = try? c.decodeIfPresent(Double.self, forKey: .batteryTemperature)
        thermal = try? c.decodeIfPresent(Int.self, forKey: .thermal)
        batteryPercent = try? c.decodeIfPresent(Int.self, forKey: .batteryPercent)
        lastHoldEnd = try? c.decodeIfPresent(HoldEnd.self, forKey: .lastHoldEnd)
        lastHoldEndAt = try? c.decodeIfPresent(Double.self, forKey: .lastHoldEndAt)
        batteryHoldSince = try? c.decodeIfPresent(Double.self, forKey: .batteryHoldSince)
        heatGuard = try? c.decodeIfPresent(Bool.self, forKey: .heatGuard)
        thermalAlertAt = try? c.decodeIfPresent(Double.self, forKey: .thermalAlertAt)
        overheatSleepAt = try? c.decodeIfPresent(Double.self, forKey: .overheatSleepAt)
        weakChargerSleepAt = try? c.decodeIfPresent(Double.self, forKey: .weakChargerSleepAt)
        displaySleeping = try? c.decodeIfPresent(Bool.self, forKey: .displaySleeping)
        displayRecovery = try? c.decodeIfPresent(DisplayRecoveryStatus.self, forKey: .displayRecovery)
        externalDisplay = try? c.decodeIfPresent(Bool.self, forKey: .externalDisplay)
        displayTopology = try? c.decodeIfPresent(DisplayTopology.self, forKey: .displayTopology)
        nativeDisplayVerified = try? c.decodeIfPresent(Bool.self, forKey: .nativeDisplayVerified)
        ownsOverride = try? c.decodeIfPresent(Bool.self, forKey: .ownsOverride)
        appConnected = try? c.decodeIfPresent(Bool.self, forKey: .appConnected)
        appPID = try? c.decodeIfPresent(Int32.self, forKey: .appPID)
        guiSessionAuthority = try? c.decodeIfPresent(GUISessionAuthorityStatus.self, forKey: .guiSessionAuthority)
        powerReturnConfirmed = try? c.decodeIfPresent(Bool.self, forKey: .powerReturnConfirmed)
        sleepDeferralReason = try? c.decodeIfPresent(String.self, forKey: .sleepDeferralReason)
        manualSession = try? c.decodeIfPresent(ManualSessionStatus.self, forKey: .manualSession)
        protection = try? c.decodeIfPresent(ProtectionStatus.self, forKey: .protection)
    }

    public init(updatedAt: Double, version: String, enabled: Bool, power: PowerSource,
                lidClosed: Bool, sleepDisabled: Bool, lastEvent: EventKind?, lastEventAt: Double?, fullWake: Bool? = true,
                batteryHoldUntil: Double? = nil, batteryTemperature: Double? = nil,
                thermal: Int? = nil, batteryPercent: Int? = nil) {
        self.updatedAt = updatedAt
        self.version = version
        self.enabled = enabled
        self.power = power
        self.lidClosed = lidClosed
        self.sleepDisabled = sleepDisabled
        self.lidObservationAvailable = true
        self.sleepOverrideObservationAvailable = true
        self.fullWake = fullWake
        self.lastEvent = lastEvent
        self.lastEventAt = lastEventAt
        self.batteryHoldUntil = batteryHoldUntil
        self.batteryTemperature = batteryTemperature
        self.thermal = thermal
        self.batteryPercent = batteryPercent
    }
}

/// One helper observation, not proof of electrical panel power-off or completed system sleep.
public struct DisplayRecoveryStatus: Codable, Equatable, Sendable {
    public var phase: DisplaySleepGate.Phase
    public var requests: Int
    public var maximumRequests: Int
    public init(phase: DisplaySleepGate.Phase, requests: Int) {
        self.phase = phase; self.requests = requests
        maximumRequests = DisplaySleepGate.maximumRequests
    }
    public var summary: String {
        switch phase {
        case .inactive: L("Display sleep follows macOS", "화면 절전은 macOS가 관리합니다")
        case .checking: L("Checking display sleep", "화면 절전 확인 중")
        case .recovering: L("Restoring display sleep · \(requests)/\(maximumRequests) requests", "화면 절전 복구 중 · \(requests)/\(maximumRequests)회 요청")
        case .asleep: L("macOS reports the display asleep", "macOS에서 화면 꺼짐을 관측했습니다")
        case .unavailable: L("Display observation unavailable · rechecking", "화면 상태 조회 지연 · 다시 확인 중")
        case .deferred: L("Display sleep deferred · screen requests need review", "화면 끄기 보류 · 화면 필요 요청을 확인하세요")
        case .stopped: L("Display sleep retries stopped · work stays active", "화면 끄기 재시도 중단 · 작업 유지 계속")
        }
    }
}

public enum EventKind: String, Codable, Sendable {
    case started, clamshellOn, clamshellOffPower, clamshellOffDisabled, clamshellOffSleepNow
    case clamshellReleased
    case lidSleep, sleepNow, sleepRefused, stopping
    /// A protection-stop request without assuming its power source or protection cause.
    case protectionSleep
    case holdOnBattery, holdEndedTime, holdEndedBattery, holdEndedHeat, holdEndedThermal
    case holdEndedSensor, holdCancelled
    case heatGuardOn, heatGuardOff, heatCritical, overheatSleep, weakChargerSleep

    public static func holdEnded(_ reason: HoldEnd) -> EventKind {
        switch reason {
        case .time: .holdEndedTime
        case .battery: .holdEndedBattery
        case .heat: .holdEndedHeat
        case .thermal: .holdEndedThermal
        case .sensor: .holdEndedSensor
        case .cancelled: .holdCancelled
        }
    }

    /// Events that end a battery hold; a sleep request or completed sleep is separate.
    public var isHoldEnd: Bool {
        switch self {
        case .holdEndedTime, .holdEndedBattery, .holdEndedHeat, .holdEndedThermal, .holdEndedSensor: true
        default: false
        }
    }

    public var logText: String {
        switch self {
        case .started: "helper started"
        case .clamshellOn: "on power: clamshell on"
        case .clamshellOffPower: "power disconnected: clamshell off"
        case .clamshellOffDisabled: "Tether turned off: clamshell off"
        case .clamshellOffSleepNow: "sleep now: clamshell off"
        case .clamshellReleased: "clamshell override released"
        case .lidSleep: "lid already closed: sleep requested"
        case .sleepNow: "sleep now requested"
        case .sleepRefused: "sleep request refused by the system"
        case .protectionSleep: "protection stop: sleep requested"
        case .stopping: "helper stopping: clamshell off"
        case .holdOnBattery: "on battery with a battery hold: clamshell kept"
        case .holdEndedTime: "battery hold ended: time is up"
        case .holdEndedBattery: "battery hold ended: battery at the floor"
        case .holdEndedHeat: "battery hold ended: battery too hot"
        case .holdEndedThermal: "battery hold ended: system thermal pressure"
        case .holdEndedSensor: "battery hold ended: charge or macOS thermal state unreadable"
        case .holdCancelled: "battery hold cancelled"
        case .heatGuardOn: "lid closed on AC and running hot: Low Power Mode on"
        case .heatGuardOff: "heat guard released: Low Power Mode restored"
        case .heatCritical: "lid closed on AC: critical thermal pressure detected"
        case .overheatSleep: "lid closed on AC and overheating: sleep requested"
        case .weakChargerSleep: "lid closed on a charger that can't keep up, battery at the floor and draining: sleep requested"
        }
    }
}
