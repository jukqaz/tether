import Foundation

/// The app's observed general-work state. Lid support is reported separately.
public struct UserSessionStatus: Codable, Equatable, Sendable {
    public var power: PowerSource
    public var thermal: Int
    public var batteryPercent: Int?
    public var limits: UserLimits?
    public var enabled: Bool
    public var automaticEnabled: Bool
    public var automaticActive: Bool
    public var powerCondition: PowerCondition
    public var automaticMinutes: Int
    public var batteryHoldUntil: Date?
    public var pendingBatteryMinutes: Int?
    public var manualActive: Bool
    public var holding: Bool
    public var until: Date?
    public var blockReason: String?
    public var error: String?
    public var canStart: Bool
    public var manualBatteryRemaining: Double
    public var manualEndReason: ManualSessionEnd?
    public var manualMaximumMinutes: Int
    public var canStartBatteryHold: Bool
    public var batteryRemaining: Double
    /// Continuous-clock identity and cap; temporary deadlines are never persisted.
    public var manualStartedAt: Double?
    public var manualContinuousDeadline: Double?
    public var manualReschedulingLimit: Double?
    public var manualBatteryContinuationMinutes: Int?
    public var manualStartedOnBattery: Bool?
    /// Optional for older snapshots. A saved choice is not proof of a native request.
    public var keepDisplayAwake: Bool?
    public var displayHolding: Bool?
    public var displayError: String?
    public var manualRequestID: UUID?
    public var manualExtensionID: UUID?
    public var manualApprovalPending: Bool?
    /// Saved policy is separate from native release, helper restoration and OS Sleep evidence.
    public var disconnectPolicy: WorkSessionDisconnectPolicy?
    public var batteryTimeLimit: WorkSessionBatteryLimit?
    public var manualPowerCondition: PowerCondition?
    public var canResume: Bool?
    public var observationLimited: Bool?
    public var ownReleasePending: Bool?
    /// Saved automatic-only intent; the wall-clock date is presentation only.
    public var automaticPauseActive: Bool?
    public var automaticPauseUntil: Date?

    public init(power: PowerSource, thermal: Int, batteryPercent: Int?, limits: UserLimits?, enabled: Bool,
                automaticEnabled: Bool, automaticActive: Bool, powerCondition: PowerCondition, automaticMinutes: Int,
                batteryHoldUntil: Date?, pendingBatteryMinutes: Int?, manualActive: Bool, holding: Bool, until: Date?,
                blockReason: String?, error: String?, canStart: Bool, manualBatteryRemaining: Double,
                manualEndReason: ManualSessionEnd?, manualMaximumMinutes: Int, canStartBatteryHold: Bool, batteryRemaining: Double,
                manualStartedAt: Double? = nil, manualContinuousDeadline: Double? = nil, manualReschedulingLimit: Double? = nil,
                manualBatteryContinuationMinutes: Int? = nil, manualStartedOnBattery: Bool? = nil,
                keepDisplayAwake: Bool? = nil, displayHolding: Bool? = nil, displayError: String? = nil) {
        self.power = power; self.thermal = thermal; self.batteryPercent = batteryPercent; self.limits = limits
        self.enabled = enabled; self.automaticEnabled = automaticEnabled; self.automaticActive = automaticActive
        self.powerCondition = powerCondition; self.automaticMinutes = automaticMinutes
        self.batteryHoldUntil = batteryHoldUntil; self.pendingBatteryMinutes = pendingBatteryMinutes
        self.manualActive = manualActive; self.holding = holding; self.until = until
        self.blockReason = blockReason; self.error = error; self.canStart = canStart
        self.manualBatteryRemaining = manualBatteryRemaining; self.manualEndReason = manualEndReason
        self.manualMaximumMinutes = manualMaximumMinutes; self.canStartBatteryHold = canStartBatteryHold
        self.batteryRemaining = batteryRemaining
        self.manualStartedAt = manualStartedAt; self.manualContinuousDeadline = manualContinuousDeadline
        self.manualReschedulingLimit = manualReschedulingLimit
        self.manualBatteryContinuationMinutes = manualBatteryContinuationMinutes
        self.manualStartedOnBattery = manualStartedOnBattery
        self.keepDisplayAwake = keepDisplayAwake; self.displayHolding = displayHolding; self.displayError = displayError
    }
}

public enum UserLidSupport: String, Codable, Sendable { case notRequired, inactive, active, pending, unavailable, error }

/// Diagnostic recording is a same-account app operation, not a power command or URL action.
public enum UserSessionRecordingAction: Codable, Equatable, Sendable {
    case start(minutes: Int)
    case finish(recordingID: UUID)

    var isValid: Bool {
        switch self {
        case .start(let minutes): (1...240).contains(minutes)
        case .finish: true
        }
    }
}

public struct UserSessionRequest: Codable, Equatable, Sendable {
    public static let maximumLifetime: Double = 15
    public var version = 1
    public var build = TetherPaths.build
    public var id: UUID
    public var command: TetherCommand
    public var epoch: UUID?
    public var revision: UInt64?
    /// Structured, same-account task input. Never inferred from command arguments or transcripts.
    public var workEvent: V4WorkEvent?
    /// Legacy wire compatibility only. The app rejects process-bound manual requests;
    /// decoding this field must never fall back to an ordinary manual timer.
    public var manualPID: V4ProcessIdentity?
    public var recording: UserSessionRecordingAction?
    public var deadline: Double
    public init(_ command: TetherCommand = .status, id: UUID = UUID(), epoch: UUID? = nil,
                revision: UInt64? = nil, now: Double = ContinuousTime.now,
                workEvent: V4WorkEvent? = nil, manualPID: V4ProcessIdentity? = nil,
                recording: UserSessionRecordingAction? = nil) {
        self.id = id; self.command = command; self.epoch = epoch; self.revision = revision
        self.workEvent = workEvent; self.manualPID = manualPID
        self.recording = recording
        deadline = now + Self.maximumLifetime
    }
    public func isValid(now: Double) -> Bool {
        version == 1 && build == TetherPaths.build && command.isValid && now.isFinite && deadline.isFinite
            && deadline > now && deadline <= now + Self.maximumLifetime && payloadIsValid
    }
    private var payloadIsValid: Bool {
        if let recording {
            return command == .status && workEvent == nil && manualPID == nil && recording.isValid
        }
        guard workEvent == nil || manualPID == nil else { return false }
        if let event = workEvent {
            return command == .status && event.scope.isValid && !event.producerID.isEmpty
                && event.producerID.count <= 128 && event.ttl.isFinite && event.ttl > 0 && event.ttl <= 300
                && event.fixedDeadline.map(\.isFinite) != false
        }
        if let pid = manualPID {
            guard pid.isValid, pid.pid > 1, pid.startIdentity > 0, pid.executableIdentity.utf8.count <= 4096 else { return false }
            if case .manual = command { return true }
            return false
        }
        return true
    }
}

public struct UserSessionReply: Codable, Sendable {
    public var version = 1
    public var build = TetherPaths.build
    public var id: UUID
    public var epoch: UUID
    public var revision: UInt64
    /// The command was accepted by the app policy, not proof of actual Sleep/Wake.
    public var ok: Bool
    public var error: String?
    public var observedAt: Double
    public var status: UserSessionStatus?
    public var lidSupport: UserLidSupport = .unavailable
    public var lidClosed: Bool?
    public var lidError: String?
    public var helperBuild: Int?
    public var helperConnected: Bool?
    /// A replay preserves the original command outcome while exposing current state.
    public var replayed: Bool?
    public var workScope: V4Scope?
    public var workEventResult: V4WorkEventResult?
    /// Positive acknowledgement of this recording operation. Older same-build
    /// apps may ignore optional request fields and return an ordinary status reply.
    public var recordingID: UUID?
    public var recordingUntil: Date?
    /// Allowlisted, bounded app decisions, including this process's opt-in detail buffer.
    public var commonActivity: [UserSessionActivity.Entry]?
    public init(id: UUID, epoch: UUID, revision: UInt64, ok: Bool, error: String? = nil, status: UserSessionStatus? = nil) {
        self.id = id; self.epoch = epoch; self.revision = revision; self.ok = ok; self.error = error
        observedAt = Date().timeIntervalSince1970; self.status = status
    }
}

/// Same-account companion commands are delegated to the app's graphical owner.
/// A non-graphical CLI (for example SSH) never becomes the root lease owner.
public enum UserSessionAccess {
    public static func permits(client: ProcessIdentity?, uid: UInt32, peerLogin: GUISessionIdentity?,
                               owner: GUISessionObservation, expectedExecutable: String,
                               sameExecutable: (String, String) -> Bool = ProcessIdentity.sameExecutable) -> Bool {
        guard let client, client.uid == uid, uid != 0, let login = owner.login, login.isValid,
              login.uid == uid, owner.consoleUID == uid, sameExecutable(client.executable, expectedExecutable) else { return false }
        return peerLogin == nil || peerLogin == login
    }
}

/// In-memory command receipts. Temporary work and request IDs never survive app restart.
public struct UserCommandLedger {
    public enum Check { case ready, stale, busy, invalidReplay, replay(UserSessionReply) }
    public let epoch = UUID()
    public private(set) var revision: UInt64 = 0
    private struct Receipt { var request: UserSessionRequest; var client: ProcessIdentity; var reply: UserSessionReply }
    private var receipts: [UUID: Receipt] = [:]
    public init() {}
    public mutating func advance() { revision &+= 1 }
    public mutating func check(_ request: UserSessionRequest, client: ProcessIdentity, now: Double = ContinuousTime.now) -> Check {
        // Keep every live receipt until retries are forbidden by the deadline.
        // Evicting a live receipt could apply an extension or toggle twice.
        receipts = receipts.filter { $0.value.request.deadline > now }
        if let cached = receipts[request.id] {
            guard cached.request == request, cached.client.matchesLifetime(client),
                  cached.client.executable == client.executable else { return .invalidReplay }
            return .replay(cached.reply)
        }
        guard request.epoch == epoch && request.revision == revision else { return .stale }
        return receipts.count < 64 ? .ready : .busy
    }
    public mutating func record(_ request: UserSessionRequest, client: ProcessIdentity, reply: UserSessionReply) {
        receipts[request.id] = Receipt(request: request, client: client, reply: reply)
    }
}

public struct UserSessionFailure: LocalizedError {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var errorDescription: String? {
        switch code {
        case "appUnavailable": L("Open the matching Tether app first. No temporary session was created.", "같은 버전의 Tether 앱을 먼저 열어 주세요. 임시 세션은 만들지 않았습니다.")
        case "coordinatorUnavailable": L("The app's common session is not ready. Check the app and matching helper.", "앱의 공통 세션이 준비되지 않았습니다. 앱과 같은 버전의 도우미를 확인해 주세요.")
        case "unsafeEndpoint", "unexpectedServer", "unauthorized": L("The local app identity or command endpoint could not be verified.", "로컬 앱의 신원 또는 명령 연결 경로를 확인하지 못했습니다.")
        case "staleRevision": L("The app state changed during this request. Read its current state and retry.", "요청 중 앱 상태가 바뀌었습니다. 현재 상태를 확인한 뒤 다시 시도해 주세요.")
        case "superseded": L("A newer app action replaced this request. It was not retried.", "더 최근의 앱 조작이 이 요청을 대체했습니다. 요청을 다시 실행하지 않았습니다.")
        case "requestVerificationFailed": L("The native sleep-prevention request could not be verified. Check the app's current state.", "macOS 절전 방지 요청을 확인하지 못했습니다. 앱의 현재 상태를 확인해 주세요.")
        case "releaseUnconfirmed": L("Tether's request could not be confirmed released. The sleep action was not sent; review diagnostics.", "Tether의 요청 해제를 확인하지 못해 잠자기 명령을 보내지 않았습니다. 진단에서 확인해 주세요.")
        case "notApplicable": L("This Mac has no internal battery. Use a general work session or the power-connected trigger.", "이 Mac에는 내장 배터리가 없습니다. 일반 작업 유지 또는 전원 연결 조건을 사용하세요.")
        case "batteryCapabilityUnavailable": L("The internal battery could not be confirmed. Existing work continues; retry this battery action after the device check recovers.", "내장 배터리를 확인하지 못했습니다. 기존 작업은 계속 유지하며, 기기 정보가 확인되면 배터리 조작을 다시 시도할 수 있습니다.")
        case "busy": L("Another app command is still being handled. Try again shortly.", "앱에서 다른 명령을 처리하고 있습니다. 잠시 뒤 다시 시도해 주세요.")
        case "processBoundManualRemoved": L("Process-bound manual sessions are no longer supported. Start a timed session with 'tether manual 30m' instead.", "프로세스 종료에 연동한 수동 유지는 더 이상 지원하지 않습니다. 'tether manual 30m'로 시간을 정해 시작해 주세요.")
        case "expired", "invalidRequest", "invalidReplay": L("This app request expired or is invalid; it was not replayed.", "앱 요청의 시간이 지났거나 유효하지 않아 다시 실행하지 않았습니다.")
        case "sleepUnavailable": L("Sleep execution is unavailable in this test context.", "이 시험 환경에서는 실제 잠자기를 실행하지 않습니다.")
        case "recordingUnavailable": L("The app did not confirm detailed recording. Open the matching Tether app and retry.", "앱이 상세 기록을 확인하지 않았습니다. 같은 버전의 Tether 앱을 열고 다시 시도해 주세요.")
        default: ServiceFailure(code).localizedDescription
        }
    }
}
