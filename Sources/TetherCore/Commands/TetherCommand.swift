import Foundation

public enum TetherCommand: Equatable, Sendable {
    case status, on, off, toggle, sleep
    case hold(minutes: Int)
    case extendHold(minutes: Int)
    case cancelHold

    /// `on`, `off`, `toggle`, `sleep`, `hold 90m`, `hold +30m`, `hold off`, `status`.
    /// Returns nil for anything else, including a hold length outside 1 min–4 h.
    public static func parse(_ words: [String]) -> TetherCommand? {
        guard let first = words.first?.lowercased() else { return .status }
        switch first {
        case "status": return .status
        case "on", "enable": return .on
        case "off", "disable": return .off
        case "toggle": return .toggle
        case "sleep": return .sleep
        case "hold":
            guard words.count >= 2 else { return nil }
            let argument = words[1...].joined().lowercased()
            if ["off", "cancel", "stop"].contains(argument) { return .cancelHold }
            if argument.hasPrefix("+") { return HoldDuration.minutes(String(argument.dropFirst())).map { .extendHold(minutes: $0) } }
            return HoldDuration.minutes(argument).map { .hold(minutes: $0) }
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
    /// read or falls outside 1 minute to the 4-hour cap.
    public static func minutes(_ text: String) -> Int? {
        let t = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "시간", with: "h")
            .replacingOccurrences(of: "분", with: "m")
        if let plain = Int(t) { return valid(plain) }
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
        return valid(Int(total.rounded()))
    }

    private static func valid(_ minutes: Int) -> Int? {
        (1...Int(SafetyPolicy.maxHold / 60)).contains(minutes) ? minutes : nil
    }
}
