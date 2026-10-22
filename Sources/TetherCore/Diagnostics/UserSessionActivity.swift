import Foundation

/// Allowlisted common-session evidence held in memory. No custom log file, identifiers,
/// process arguments or free-form errors are retained; OS logging is owned by the caller.
public struct UserSessionActivity: Sendable {
    public static let capacity = 128
    public enum Kind: String, Codable, Sendable {
        case decision, powerConnected, powerDisconnected, applied, released, manualStarted, manualEnded
        case marker, recordingStarted, recordingEnded, detail
        public var title: String {
            switch self {
            case .decision: L("Common work decision updated", "공통 작업 판단 변경")
            case .powerConnected: L("Power connected", "전원 연결 감지")
            case .powerDisconnected: L("Power disconnected", "전원 분리 감지")
            case .applied: L("Common idle-sleep request verified", "공통 유휴 절전 방지 요청 확인")
            case .released: L("Common idle-sleep request no longer verified", "공통 유휴 절전 방지 요청 해제 또는 미확인")
            case .manualStarted: L("Manual work started", "수동 작업 시작")
            case .manualEnded: L("Manual work ended", "수동 작업 종료")
            case .marker: L("Problem moment marked", "문제 발생 시점 표시")
            case .recordingStarted: L("Detailed recording started", "상세 기록 시작")
            case .recordingEnded: L("Detailed recording ended", "상세 기록 종료")
            case .detail: L("Common work observations", "공통 작업 관측값")
            }
        }
    }
    public struct State: Codable, Equatable, Sendable {
        public let power: PowerSource
        public let enabled: Bool
        public let automaticEnabled: Bool
        public let automaticActive: Bool
        public let condition: PowerCondition
        public let automaticMinutes: Int
        public let manualActive: Bool
        public let holding: Bool
        public let canStart: Bool
        public let until: Date?
        public let batteryUntil: Date?
        public let pendingMinutes: Int?
        public let block: String
        public let failed: Bool
        public let manualEnd: ManualSessionEnd?

        public init(_ status: UserSessionStatus) {
            power = status.power; enabled = status.enabled; automaticEnabled = status.automaticEnabled
            automaticActive = status.automaticActive; condition = status.powerCondition
            automaticMinutes = min(240, max(0, status.automaticMinutes))
            manualActive = status.manualActive; holding = status.holding; canStart = status.canStart
            until = Self.validDate(status.until); batteryUntil = Self.validDate(status.batteryHoldUntil)
            pendingMinutes = status.pendingBatteryMinutes.map { min(240, max(0, $0)) }
            let allowed = ["thermal", "battery", "sensor", "time", "budget", "guiSessionUnavailable", "powerUnknown", "migration", "settings"]
            block = status.blockReason.map { allowed.contains($0) ? $0 : "other" } ?? "none"
            failed = status.error != nil; manualEnd = status.manualEndReason
        }
        private static func validDate(_ value: Date?) -> Date? {
            guard let value, value.timeIntervalSince1970.isFinite,
                  (-62_135_596_800...253_402_300_799).contains(value.timeIntervalSince1970) else { return nil }
            return value
        }
        public var line: String {
            "power=\(power.rawValue) enabled=\(enabled) automaticEnabled=\(automaticEnabled) automatic=\(automaticActive) condition=\(condition.rawValue) manual=\(manualActive) holding=\(holding) canStart=\(canStart) block=\(block) failed=\(failed) automaticMinutes=\(automaticMinutes) pendingMinutes=\(pendingMinutes.map(String.init) ?? "none") until=\(until.map { String(Int64($0.timeIntervalSince1970)) } ?? "none") batteryUntil=\(batteryUntil.map { String(Int64($0.timeIntervalSince1970)) } ?? "none") manualEnd=\(manualEnd?.rawValue ?? "none")"
        }
    }
    public struct Inputs: Codable, Equatable, Sendable {
        public let thermal: Int?
        public let batteryPercent: Int?
        public let manualRemaining: Int?
        public let batteryRemaining: Int?
        public init(_ status: UserSessionStatus) {
            thermal = (0...3).contains(status.thermal) ? status.thermal : nil
            batteryPercent = status.batteryPercent.flatMap { (0...100).contains($0) ? $0 : nil }
            manualRemaining = Self.seconds(status.manualBatteryRemaining)
            batteryRemaining = Self.seconds(status.batteryRemaining)
        }
        private static func seconds(_ value: Double) -> Int? {
            value.isFinite && value >= 0 ? Int(min(24 * 3600, value.rounded(.down))) : nil
        }
        public var line: String {
            "thermal=\(thermal.map(String.init) ?? "unknown") batteryPercent=\(batteryPercent.map(String.init) ?? "unknown") manualRemaining=\(manualRemaining.map(String.init) ?? "unknown") batteryRemaining=\(batteryRemaining.map(String.init) ?? "unknown")"
        }
    }
    public struct Entry: Codable, Identifiable, Sendable {
        public let id: UInt64
        public let date: Date
        public let kind: Kind
        public let state: State?
        public let inputs: Inputs?
        public var title: String {
            guard let state else { return kind.title }
            if [.decision, .released, .manualEnded].contains(kind), state.block != "none" {
                return L("Work stopped for protection", "보호로 작업 유지 중단")
            }
            return kind.title
        }
        /// Only allowlisted facts. A policy release is never presented as completed Sleep.
        public var detail: String? {
            guard let state else { return nil }
            var parts: [String] = []
            if state.block != "none" { parts.append(protectionReason(state.block)) }
            else if !state.manualActive, let reason = state.manualEnd {
                switch reason {
                case .taskEnded: parts.append(L("Linked process ended; success unverified", "연결한 프로세스 종료 · 성공 여부 미확인"))
                case .time: parts.append(L("Manual duration ended", "수동 유지 시간 만료"))
                case .batteryBudget: parts.append(L("Manual battery allowance ended", "수동 배터리 한도 만료"))
                case .powerDisconnected: parts.append(L("Manual session ended on unplug", "전원 분리로 수동 유지 종료"))
                case .cancelled: parts.append(L("Manual session ended by user", "직접 수동 유지 종료"))
                case .sessionEnded: parts.append(L("Previous work session ended", "이전 작업 세션 종료"))
                case .observationUnavailable: parts.append(L("Manual session observations unavailable", "수동 유지 관측 확인 불가"))
                case .protection: parts.append(L("Manual session ended for protection", "보호로 수동 유지 종료"))
                }
            }
            if state.failed { parts.append(L("Request or observation needs review", "요청 처리·관측 확인 필요")) }
            parts.append(state.automaticActive ? L("Automatic active", "자동 유지 조건 적용") : L("Automatic inactive", "자동 유지 조건 미적용"))
            parts.append(state.manualActive ? L("Manual active", "수동 유지 실행 중") : L("Manual inactive", "수동 유지 없음"))
            return parts.joined(separator: " · ")
        }
        public var line: String {
            "event=\(kind.rawValue) \(state?.line ?? "state=unavailable")\(inputs.map { " " + $0.line } ?? "")"
        }
    }
    public private(set) var entries: [Entry] = []
    public private(set) var recordingUntil: Date?
    private var deadline: Double?
    private var recordingStart: Double?
    private var previous: State?
    private var previousInputs: Inputs?
    private var sequence: UInt64 = 0
    private var retainedDecisions: [Entry] = []
    public static let maximumArchiveBytes = 262_144
    private struct Archive: Codable { var version = 1; var entries: [Entry] }
    public init() {}
    public init(archive: Data, date: Date = Date()) throws {
        guard archive.count <= Self.maximumArchiveBytes else { throw CocoaError(.fileReadTooLarge) }
        let saved = try JSONDecoder().decode(Archive.self, from: archive)
        let allowed = Set(["none", "thermal", "battery", "sensor", "time", "budget", "guiSessionUnavailable", "powerUnknown", "migration", "settings", "other"])
        guard saved.version == 1, saved.entries.count <= Self.capacity,
              saved.entries.allSatisfy({ $0.kind != .detail && $0.date.timeIntervalSince1970.isFinite
                  && $0.id > 0 && $0.id < UInt64.max && $0.state.map { allowed.contains($0.block) } != false }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        retainedDecisions = saved.entries.filter { date.timeIntervalSince($0.date) <= 72 * 3600 && $0.date <= date.addingTimeInterval(300) }
        entries = retainedDecisions
        sequence = saved.entries.map(\.id).max() ?? 0
        // No prior request, recording timer, input snapshot or execution authority is restored.
    }
    public func archivedDecisions(date: Date = Date()) throws -> Data {
        let selected = retainedDecisions.filter { date.timeIntervalSince($0.date) <= 72 * 3600 && $0.date <= date.addingTimeInterval(300) }
        let data = try JSONEncoder().encode(Archive(entries: Array(selected.suffix(Self.capacity))))
        guard data.count <= Self.maximumArchiveBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return data
    }

    public func isRecording(now: Double = ContinuousTime.now) -> Bool {
        guard now.isFinite, let deadline, let recordingStart else { return false }
        return now >= recordingStart && now < deadline
    }
    /// Basic decisions ignore a changing countdown. Detail snapshots are opt-in,
    /// deduplicated and cease at the continuous-time deadline, even after wall-clock edits.
    @discardableResult
    public mutating func observe(_ status: UserSessionStatus, now: Double = ContinuousTime.now, date: Date = Date()) -> [Entry] {
        guard now.isFinite, date.timeIntervalSince1970.isFinite else { return [] }
        var added: [Entry] = []
        let state = State(status), inputs = Inputs(status)
        if deadline != nil, !isRecording(now: now) {
            deadline = nil; recordingStart = nil; recordingUntil = nil
            added.append(append(.recordingEnded, state: state, date: date))
        }
        if previous != state {
            let kind: Kind
            if let previous, previous.power != state.power, state.power == .ac { kind = .powerConnected }
            else if let previous, previous.power != state.power, state.power == .battery { kind = .powerDisconnected }
            else if let previous, previous.holding != state.holding { kind = state.holding ? .applied : .released }
            else if let previous, previous.manualActive != state.manualActive { kind = state.manualActive ? .manualStarted : .manualEnded }
            else { kind = .decision }
            added.append(append(kind, state: state, date: date))
        }
        if isRecording(now: now), previous != state || previousInputs != inputs {
            added.append(append(.detail, state: state, inputs: inputs, date: date))
        }
        previous = state; previousInputs = inputs
        return added
    }
    @discardableResult
    public mutating func setRecording(_ on: Bool, minutes: Int = 15, now: Double = ContinuousTime.now, date: Date = Date()) -> [Entry] {
        guard now.isFinite, date.timeIntervalSince1970.isFinite else { return [] }
        if on {
            let duration = Double(min(240, max(1, minutes))) * 60
            recordingStart = now; deadline = now + duration; recordingUntil = date.addingTimeInterval(duration)
            previousInputs = nil
            return [append(.recordingStarted, state: previous, date: date)]
        }
        guard deadline != nil else { return [] }
        deadline = nil; recordingStart = nil; recordingUntil = nil
        return [append(.recordingEnded, state: previous, date: date)]
    }
    @discardableResult
    public mutating func mark(date: Date = Date()) -> Entry? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        return append(.marker, state: previous, date: date)
    }
    public func recent(limit: Int = 20) -> [Entry] {
        Array(entries.suffix(min(Self.capacity, max(0, limit))).reversed())
    }
    /// Keep insertion order: wall-clock corrections must not reverse the causal chain.
    public func report(since: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let selected = entries.filter { $0.date >= since }
        return (["## Common work activity", "", "Source: bounded local decisions (up to 128 events / 72 hours); detailed observations are current-process only. OS logs have separate retention. These decisions do not prove physical Sleep/Wake, display power or remote readiness.", ""]
            + (selected.isEmpty ? ["No retained events in the selected range."] : selected.map { "- \(formatter.string(from: $0.date)) · sequence \($0.id) · \($0.line)" }) + [""]).joined(separator: "\n")
    }
    private mutating func append(_ kind: Kind, state: State?, inputs: Inputs? = nil, date: Date) -> Entry {
        sequence &+= 1
        let entry = Entry(id: sequence, date: date, kind: kind, state: state, inputs: inputs)
        entries.append(entry)
        if kind != .detail {
            retainedDecisions.append(entry)
            retainedDecisions.removeAll { date.timeIntervalSince($0.date) > 72 * 3600 }
            if retainedDecisions.count > Self.capacity { retainedDecisions.removeFirst(retainedDecisions.count - Self.capacity) }
        }
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        return entry
    }
}
