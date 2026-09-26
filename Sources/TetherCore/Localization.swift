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

public enum Localization {
    /// Tests pin this; everything else keeps the user's preference.
    nonisolated(unsafe) public static var current: Language = .preferred
}

/// The string for the current language.
public func L(_ english: String, _ korean: String) -> String {
    Localization.current == .korean ? korean : english
}
