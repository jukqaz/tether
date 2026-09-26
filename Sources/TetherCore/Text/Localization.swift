import Foundation

/// Tether speaks English and Korean. Strings sit side by side in code (`L("…", "…")`) so the app
/// bundle, the helper and the `tether` command share one mechanism with no resource bundles.
public enum Language: String, Sendable {
    case english, korean

    /// Korean when it leads the user's preferred languages, English otherwise.
    public static var preferred: Language {
        Locale.preferredLanguages.first?.hasPrefix("ko") == true ? .korean : .english
    }
}

/// The language picked in Settings › General; `system` follows macOS.
public enum LanguageChoice: String, CaseIterable, Sendable {
    case system, english, korean

    public var language: Language {
        switch self {
        case .system: .preferred
        case .english: .english
        case .korean: .korean
        }
    }
}

public enum Localization {
    /// The preferences key for the choice, in the app's domain.
    public static let defaultsKey = "language"

    /// Tests pin this; the app sets it when the choice changes.
    nonisolated(unsafe) public static var current: Language = savedChoice.language

    /// The choice saved by the app. The `tether` command reads the app's preferences, so it
    /// speaks the same language.
    public static var savedChoice: LanguageChoice {
        let defaults = Bundle.main.bundleIdentifier == TetherPaths.bundleID
            ? UserDefaults.standard : UserDefaults(suiteName: TetherPaths.bundleID)
        return defaults?.string(forKey: defaultsKey).flatMap(LanguageChoice.init) ?? .system
    }
}

/// The string for the current language.
public func L(_ english: String, _ korean: String) -> String {
    Localization.current == .korean ? korean : english
}
