import AppKit
import TetherCore

/// Recovery-only adapter. New sessions never save or change brightness. Originals
/// remain until read-back confirms recovery of both level and automatic mode.
@MainActor
final class ScreenGuard {
    private let defaults: UserDefaults
    private let readPanel: () -> Float?
    private let writePanel: (Float) -> Void
    private let readKeyboard: () -> (level: Float, auto: Bool)?
    private let writeKeyboard: (Float, Bool) -> Void
    private var attempted = false
    private(set) var recoveryError: String?
    enum Key {
        static let brightness = "savedBuiltInBrightness"
        static let keyboard = "savedKeyboardBrightness"
        static let keyboardAuto = "savedKeyboardAutoBrightness"
    }
    init(defaults: UserDefaults = .standard,
         readPanel: @escaping () -> Float? = { BuiltInBrightness.get() },
         writePanel: @escaping (Float) -> Void = { BuiltInBrightness.set($0) },
         readKeyboard: @escaping () -> (level: Float, auto: Bool)? = { KeyboardBacklight.get() },
         writeKeyboard: @escaping (Float, Bool) -> Void = { KeyboardBacklight.set(level: $0, auto: $1) }) {
        self.defaults = defaults; self.readPanel = readPanel; self.writePanel = writePanel
        self.readKeyboard = readKeyboard; self.writeKeyboard = writeKeyboard
    }
    var hasRecoveryDebt: Bool {
        [Key.brightness, Key.keyboard, Key.keyboardAuto].contains { defaults.object(forKey: $0) != nil }
    }
    func update(clamshellActive: Bool, lidClosed: Bool) { if !lidClosed { restore() } }
    func releaseAll() { restore() }
    /// Retry only after explicit recovery, never on every status observation.
    func retryRecovery() { attempted = false; restore() }

    private func restore() {
        guard !attempted, hasRecoveryDebt else { return }
        attempted = true
        if let raw = defaults.object(forKey: Key.brightness), let saved = level(raw) {
            writePanel(saved)
            if let actual = readPanel(), actual.isFinite, abs(actual - saved) <= 0.01 {
                defaults.removeObject(forKey: Key.brightness)
            }
        }
        if let raw = defaults.object(forKey: Key.keyboard), let saved = level(raw),
           let auto = defaults.object(forKey: Key.keyboardAuto) as? NSNumber,
           CFGetTypeID(auto) == CFBooleanGetTypeID() {
            let wantedAuto = auto.boolValue
            writeKeyboard(saved, wantedAuto)
            if let actual = readKeyboard(), actual.level.isFinite,
               abs(actual.level - saved) <= 0.01, actual.auto == wantedAuto {
                defaults.removeObject(forKey: Key.keyboard)
                defaults.removeObject(forKey: Key.keyboardAuto)
            }
        }
        recoveryError = hasRecoveryDebt ? "legacyDisplayRecoveryPending" : nil
        if hasRecoveryDebt { appLog.error("legacy display recovery unverified; originals retained") }
        else { appLog.notice("legacy display recovery verified") }
    }
    private func level(_ raw: Any) -> Float? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.floatValue
        return value.isFinite && (0...1).contains(value) ? value : nil
    }
}
