import Foundation

/// Safe, bounded categories only. Never retain a tab, document or conversation title.
public enum PowerRequestPurpose: String, Hashable, Sendable {
    case screenCapture, videoPlayback

    init?(assertionName: String?) {
        switch assertionName {
        case "Capturing": self = .screenCapture
        case "Video Wake Lock": self = .videoPlayback
        default: return nil
        }
    }

    public var summary: String {
        switch self {
        case .screenCapture: L("Screen capture request", "화면 캡처·공유 요청")
        case .videoPlayback: L("Video playback request", "영상 재생 요청")
        }
    }
}

/// Diagnostic evidence, never a work-session reason or permission to keep a lid closed.
public struct PowerActivitySignal: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case userActivity, displayDelay }
    public var id: String { "\(pid):\(kind.rawValue):\(sourcePID ?? 0)" }
    public let pid: Int32
    public var process: String
    public let kind: Kind
    public let sourcePID: Int32?
    public var source: String?
    public init(pid: Int32, process: String, kind: Kind, sourcePID: Int32? = nil, source: String? = nil) {
        self.pid = pid; self.process = process; self.kind = kind
        self.sourcePID = sourcePID; self.source = source
    }

    public var summary: String {
        switch kind {
        case .userActivity: L("User activity reported · display idle time can restart", "사용자 활동 보고 · 화면 대기 시간 갱신 가능")
        case .displayDelay: L("macOS is delaying display sleep", "macOS가 화면 꺼짐을 잠시 지연 중")
        }
    }

    /// Only the known WindowServer HID record is interpreted. The PID is an OS
    /// metadata hint, not proof of remote authentication or input round-trip.
    static func inputSourcePID(owner: String, name: String?) -> Int32? {
        guard owner == "WindowServer", let name, name.utf8.count <= 512,
              name.hasPrefix("com.apple.iohideventsystem.queue.tickle.nxevent ") else { return nil }
        let fields = name.split(separator: " ").dropFirst()
        guard fields.count == 3, fields.contains("service:IOHIDSystem"),
              fields.filter({ $0.hasPrefix("process:") }).count == 1,
              let field = fields.first(where: { $0.hasPrefix("pid:") }),
              fields.filter({ $0.hasPrefix("pid:") }).count == 1 else { return nil }
        let value = field.dropFirst(4)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let pid = Int32(value), pid > 0 else { return nil }
        return pid
    }
}

public struct PowerActivityObservation: Sendable {
    public var blockers: [SleepBlocker]?
    public var signals: [PowerActivitySignal]?
}

/// Saved macOS timeouts, not the current assertion state or proof of actual sleep.
public struct PowerSleepPreferences: Equatable, Sendable {
    public struct Setting: Equatable, Sendable {
        public var systemMinutes: Int?
        public var displayMinutes: Int?
        public var terminalKeepsAwake: Bool?
        public init(systemMinutes: Int? = nil, displayMinutes: Int? = nil, terminalKeepsAwake: Bool? = nil) {
            self.systemMinutes = systemMinutes; self.displayMinutes = displayMinutes
            self.terminalKeepsAwake = terminalKeepsAwake
        }
    }
    public var ac: Setting?
    public var battery: Setting?
    public init(ac: Setting? = nil, battery: Setting? = nil) { self.ac = ac; self.battery = battery }
    public func setting(for power: PowerSource) -> Setting? {
        switch power { case .ac: ac; case .battery: battery; case .unknown: nil }
    }

    public static func read() -> Self {
        decode(Shell.run("/usr/bin/pmset", ["-g", "custom"], timeout: 2, maxOutputBytes: 65_536))
    }

    public static func decode(_ result: Shell.Result) -> Self {
        guard result.status == 0, !result.timedOut, result.terminationConfirmed,
              result.output.utf8.count < 65_536 else { return Self() }
        var sections: [String: [String: String]] = [:]
        var invalid: Set<String> = []
        var current: String?
        let relevant: Set<String> = ["sleep", "displaysleep", "ttyskeepawake"]
        for line in result.output.split(whereSeparator: \.isNewline) {
            if line.first?.isWhitespace != true {
                let header = String(line)
                current = ["AC Power:", "Battery Power:"].contains(header) ? header : nil
                if let current {
                    if sections[current] != nil { invalid.insert(current) }
                    sections[current] = [:]
                }
                continue
            }
            guard let current else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first, relevant.contains(String(first)) else { continue }
            guard fields.count == 2, sections[current]?[String(first)] == nil else {
                invalid.insert(current); continue
            }
            sections[current]?[String(first)] = String(fields[1])
        }
        func setting(_ section: String) -> Setting? {
            guard !invalid.contains(section), let values = sections[section], !values.isEmpty else { return nil }
            func minutes(_ key: String) -> Int? {
                guard let value = values[key], !value.isEmpty,
                      value.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let minutes = Int(value), (0...Int(Int32.max)).contains(minutes) else { return nil }
                return minutes
            }
            let terminal = values["ttyskeepawake"].flatMap { $0 == "0" ? false : $0 == "1" ? true : nil }
            return Setting(systemMinutes: minutes("sleep"), displayMinutes: minutes("displaysleep"), terminalKeepsAwake: terminal)
        }
        return Self(ac: setting("AC Power:"), battery: setting("Battery Power:"))
    }
}
