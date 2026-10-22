import Foundation

/// Bounded pmset output, parsed without storing assertion descriptions or process names.
/// A missing interval boundary is unknown, never an authoritative zero.
public struct SystemSleepEvents: Sendable {
    private enum Kind: Sendable { case sleep, wake, darkWake }
    private struct Event: Sendable { let time: Double; let kind: Kind }
    private var events: [Event] = []
    private var earliest: Double?

    public init(_ output: String) {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        date.isLenient = false
        var seen = Set<String>()
        for line in output.split(separator: "\n") {
            // Skip summaries, truncated first lines and commands such as "Wake Requests".
            guard line.count > 25, line.first?.isNumber == true else { continue }
            let rest = line.dropFirst(25).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard rest.count == 2 else { continue }
            // Only the first timestamp and power transitions need date parsing. Large
            // assertion/maintenance sections must not add work to every wake.
            guard earliest == nil || ["Sleep", "Wake", "DarkWake"].contains(rest[0]),
                  let at = date.date(from: String(line.prefix(25)))?.timeIntervalSince1970 else { continue }
            earliest = min(earliest ?? at, at)
            let detail = rest[1].trimmingCharacters(in: .whitespaces)
            let kind: Kind
            switch rest[0] {
            case "Sleep" where detail.hasPrefix("Entering Sleep state"): kind = .sleep
            case "DarkWake" where detail.hasPrefix("DarkWake from"): kind = .darkWake
            case "Wake" where detail.hasPrefix("Wake from") || detail.hasPrefix("DarkWake to FullWake"): kind = .wake
            default: continue
            }
            let identity = "\(at)|\(rest[0])|\(detail)"
            guard seen.insert(identity).inserted else { continue }
            events.append(Event(time: at, kind: kind))
        }
        events.sort { $0.time < $1.time }
    }

    public func darkWakeCount(for record: SleepRecord) -> Int? {
        guard let end = record.wokeAt, end >= record.sleptAt,
              let earliest, earliest <= floor(record.sleptAt) else { return nil }
        let interval = events.filter { $0.time >= floor(record.sleptAt) && $0.time <= floor(end) }
        guard let first = interval.first, first.kind == .sleep,
              let last = interval.last, last.kind == .wake,
              interval.filter({ $0.kind == .wake }).count == 1 else { return nil }
        return interval.filter { $0.kind == .darkWake }.count
    }
}
