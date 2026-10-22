import Foundation

public enum TetherCommand: Codable, Equatable, Sendable {
    case status, on, off, toggle, sleep
    case hold(minutes: Int)
    case extendHold(minutes: Int)
    case cancelHold
    case manual(minutes: Int?), extendManual(minutes: Int), endManual
    case automatic(Bool), condition(PowerCondition)

    public var isValid: Bool {
        switch self {
        case .hold(let minutes): (1...120).contains(minutes)
        case .manual(let minutes): minutes.map { $0 > 0 && $0 <= Int.max / 60 } ?? true
        case .extendHold(let minutes), .extendManual(let minutes): [15, 30].contains(minutes)
        case .condition(let condition): condition == .ac
        default: true
        }
    }

    /// `on`, `off`, `toggle`, `sleep`, `hold 90m`, `hold off`, `status`.
    /// Battery requests are 1–120 minutes. Only explicit +15/+30 extensions are accepted.
    public static func parse(_ words: [String]) -> TetherCommand? {
        guard let first = words.first?.lowercased() else { return .status }
        switch first {
        case "status": return words.count == 1 ? .status : nil
        case "on", "enable": return words.count == 1 ? .on : nil
        case "off", "disable": return words.count == 1 ? .off : nil
        case "toggle": return words.count == 1 ? .toggle : nil
        case "sleep": return words.count == 1 ? .sleep : nil
        case "hold":
            guard words.count >= 2 else { return nil }
            let argument = words[1...].joined().lowercased()
            if ["off", "cancel", "stop"].contains(argument) { return .cancelHold }
            if argument.hasPrefix("+") {
                return HoldDuration.minutes(String(argument.dropFirst())).flatMap { [15, 30].contains($0) ? .extendHold(minutes: $0) : nil }
            }
            return HoldDuration.minutes(argument).map { .hold(minutes: $0) }
        case "manual":
            if words.count == 1 { return .manual(minutes: nil) }
            let argument = words[1...].joined().lowercased()
            if ["off", "cancel", "stop"].contains(argument) { return .endManual }
            if argument == "unlimited" { return .manual(minutes: nil) }
            if argument.hasPrefix("+") {
                return HoldDuration.minutes(String(argument.dropFirst())).flatMap { [15, 30].contains($0) ? .extendManual(minutes: $0) : nil }
            }
            return HoldDuration.minutes(argument, maximum: Int.max / 60).map { .manual(minutes: $0) }
        case "auto":
            guard words.count == 2 else { return nil }
            switch words[1].lowercased() { case "on": return .automatic(true); case "off": return .automatic(false); default: return nil }
        case "condition":
            guard words.count == 2, let value = PowerCondition(rawValue: words[1].lowercased()), value == .ac else { return nil }
            return .condition(value)
        default: return nil
        }
    }

    /// `tether://sleep`, `tether://hold/90m`, `tether://hold?minutes=90`, `tether://hold/off`.
    public static func parse(url: URL) -> TetherCommand? {
        guard url.scheme?.lowercased() == "tether" else { return nil }
        var words = [url.host ?? ""] + url.pathComponents.filter { $0 != "/" }
        if let minutes = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "minutes" })?.value {
            words.append(minutes)
        }
        words = words.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return parse(words)
    }
}

public enum HoldDuration {
    /// Minutes from "90", "90m", "1h", "1h30m", "1.5h" or "1시간30분"; nil when it cannot be
    /// read or falls outside the supplied limit (default: 1–120 minutes).
    public static func minutes(_ text: String, maximum: Int = 120) -> Int? {
        let t = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "시간", with: "h")
            .replacingOccurrences(of: "분", with: "m")
        guard maximum > 0 else { return nil }
        if let plain = Int(t) { return valid(plain, maximum: maximum) }
        var total = 0.0
        var number = ""
        var sawUnit = false
        for ch in t {
            if ch.isNumber || ch == "." {
                number.append(ch)
                continue
            }
            guard let value = Double(number) else { return nil }
            switch ch {
            case "h": total += value * 60
            case "m": total += value
            default: return nil
            }
            number = ""
            sawUnit = true
        }
        guard number.isEmpty, sawUnit else { return nil }
        let rounded = total.rounded()
        guard rounded.isFinite, (1...Double(maximum)).contains(rounded) else { return nil }
        return Int(rounded)
    }

    private static func valid(_ minutes: Int, maximum: Int) -> Int? {
        (1...maximum).contains(minutes) ? minutes : nil
    }
}
