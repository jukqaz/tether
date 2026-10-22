/// UI presets only. Saved values and active requests keep their independent policy limits.
public enum SessionDuration {
    public static let presets = [5, 10, 15, 30, 60, 120]

    public static func choices(maximum: Int, including saved: Int? = nil) -> [Int] {
        let cap = max(1, maximum)
        var values = presets.filter { $0 <= cap }
        if values.isEmpty { values = [cap] }
        // A previous custom choice remains selectable until the user replaces it.
        // Never silently round a saved limit or offer the policy's overflow ceiling.
        if let saved, (1...cap).contains(saved) { values.append(saved) }
        return Array(Set(values)).sorted()
    }
}
