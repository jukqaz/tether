import Foundation

/// Parsing has no process, socket, file or execution effects. Scope is an identity, never an authorization token.
public struct V4CLITaskInput: Equatable, Sendable {
    public var kind: V4WorkEventKind
    public var jobID: UUID
    public var eventID: UUID
    public var sequence: UInt64
    public var producerID: String
    public var scope: V4Scope?
    public var ttl: Double
    public var fixedDeadline: Double?
    public init?(words: [String], newJobID: UUID, newEventID: UUID) {
        guard words.count >= 2, words[0] == "task" else { return nil }
        switch words[1] {
        case "begin": kind = .start
        case "working": kind = .working
        case "waiting": kind = .waiting
        case "idle": kind = .idle
        case "heartbeat": kind = .heartbeat
        case "finish": kind = .finished
        case "fail": kind = .failed
        case "cancel": kind = .cancelled
        default: return nil
        }
        var values: [String: String] = [:]
        var index = 2
        let allowed: Set<String> = ["--job-id", "--event-id", "--seq", "--producer", "--scope", "--ttl", "--deadline"]
        while index < words.count {
            let key = words[index]
            if key == "--json" { index += 1; continue }
            guard allowed.contains(key), values[key] == nil, index + 1 < words.count else { return nil }
            values[key] = words[index + 1]; index += 2
        }
        if let value = values["--job-id"] { guard let id = UUID(uuidString: value) else { return nil }; jobID = id }
        else { guard kind == .start else { return nil }; jobID = newJobID }
        if let value = values["--event-id"] { guard let id = UUID(uuidString: value) else { return nil }; eventID = id }
        else { eventID = newEventID }
        if let value = values["--seq"] { guard let number = UInt64(value) else { return nil }; sequence = number }
        else { guard kind == .start else { return nil }; sequence = 0 }
        producerID = values["--producer"] ?? "tether-cli"
        guard !producerID.isEmpty, producerID.count <= 128 else { return nil }
        if let value = values["--scope"] { guard let decoded = Self.decodeScope(value) else { return nil }; scope = decoded }
        else { guard kind == .start else { return nil }; scope = nil }
        if let value = values["--ttl"] { guard let number = Double(value), number.isFinite, number >= 1, number <= 300 else { return nil }; ttl = number }
        else { ttl = 120 }
        if let value = values["--deadline"] { guard let number = Double(value), number.isFinite else { return nil }; fixedDeadline = number }
        else { fixedDeadline = nil }
    }
    public func event(scope: V4Scope) -> V4WorkEvent {
        .init(jobID: jobID, eventID: eventID, sequence: sequence, scope: self.scope ?? scope,
              producerID: producerID, kind: kind, ttl: ttl, fixedDeadline: fixedDeadline)
    }
    public static func encodeScope(_ scope: V4Scope) -> String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(scope))?.base64EncodedString()
    }
    public static func decodeScope(_ token: String) -> V4Scope? {
        guard token.utf8.count <= 4096, let data = Data(base64Encoded: token),
              let scope = try? JSONDecoder().decode(V4Scope.self, from: data), scope.isValid else { return nil }
        return scope
    }
}

public struct V4CLIRunInput: Equatable, Sendable {
    public var minutes: Int?
    public var executable: String
    public var arguments: [String]
    /// Minutes or unlimited must be explicit; a child argument is never interpreted as a Tether option.
    public init?(words: [String]) {
        guard words.first == "run", let separator = words.firstIndex(of: "--"), separator + 1 < words.count else { return nil }
        let options = Array(words[1..<separator])
        if options == ["--unlimited"] { minutes = nil }
        else if options.count == 2, options[0] == "--minutes", let number = Int(options[1]), number > 0, number <= Int.max / 60 {
            minutes = number
        } else { return nil }
        executable = words[separator + 1]
        guard !executable.isEmpty, !executable.utf8.contains(0) else { return nil }
        arguments = Array(words.dropFirst(separator + 2))
        guard arguments.allSatisfy({ !$0.utf8.contains(0) }) else { return nil }
    }
    /// Unix wait status reports process exit only, never application-level task success.
    public static func exitCode(waitStatus: Int32) -> Int32? {
        let signal = waitStatus & 0x7f
        if signal == 0 { return (waitStatus >> 8) & 0xff }
        if signal != 0x7f { return min(255, 128 + signal) }
        return nil
    }
}
