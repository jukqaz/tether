import AppKit
import IOKit.pwr_mgt
import TetherCore

/// Keeps a clamshell session unlocked. This Mac locks the moment the display sleeps, so while
/// clamshell mode is on the display is held awake. With the lid shut and no external display the
/// built-in panel would stay lit under the lid, so it and the keyboard are dimmed to 0 instead of
/// being put to sleep, and restored once the lid is open again (see `ScreenPolicy`) or the app quits.
///
/// With a screen in view the same assertion would keep it lit forever while idle, so after a while
/// with no input the screen is blanked instead: every display's gamma goes to
/// black and the built-in panel and keyboard are dimmed. Any input brings it all back, unlocked.
@MainActor
final class ScreenGuard {
    private var assertion: IOPMAssertionID = 0
    private let defaults = UserDefaults.standard
    private var clamshellActive = false
    private var lidClosed = false
    private var lidSeen = false
    private var blankedAt: Date?
    private var inputWatch: Timer?
    /// Called when the screen blanks or comes back, so the panel can update.
    var onBlankChange: (() -> Void)?

    var isBlank: Bool { blankedAt != nil }
    /// The no-lock assertion is held (visible in Activity Monitor > Energy, "Preventing Sleep").
    var holdsDisplayAwake: Bool { assertion != 0 }

    // Persisted so levels survive a crash while dimmed.
    private enum Key {
        static let brightness = "savedBuiltInBrightness"
        static let keyboard = "savedKeyboardBrightness"
        static let keyboardAuto = "savedKeyboardAutoBrightness"
    }

    /// `lockOnLidClose`: the user wants the Mac locked when the lid closes. Display sleep, and so
    /// locking, is then left to macOS as usual; only the lid close itself is locked here, because
    /// with clamshell on it no longer sleeps the Mac. No dimming-instead-of-sleep, no blanking.
    func update(clamshellActive: Bool, lidClosed: Bool, idleBlankMinutes: Int, lockOnLidClose: Bool) {
        let lidJustClosed = lidSeen && lidClosed && !self.lidClosed
        lidSeen = true
        self.clamshellActive = clamshellActive
        self.lidClosed = lidClosed
        setDisplayAwake(clamshellActive && !lockOnLidClose)
        let external = Displays.hasExternal
        // Working on an external display with the lid shut is not walking away.
        if lockOnLidClose, clamshellActive, lidJustClosed, !external {
            appLog.notice("lid closed: locking the screen")
            ScreenLock.now()
        }
        let visible = ScreenPolicy.screenVisible(lidClosed: lidClosed, externalDisplay: external)
        if blankedAt != nil, !clamshellActive || !visible || lockOnLidClose {
            endBlank()
        } else if blankedAt == nil, !lockOnLidClose,
                  ScreenPolicy.isIdleBlank(clamshellActive: clamshellActive, lidClosed: lidClosed,
                                           externalDisplay: external, idleSeconds: UserInput.idleSeconds,
                                           thresholdMinutes: idleBlankMinutes),
                  !DisplayAssertions.heldByOthers {
            appLog.notice("idle for \(idleBlankMinutes, privacy: .public) min: screen off")
            startBlank()
        }
        applyScreenPolicy(external: external)
    }

    private func applyScreenPolicy(external: Bool = Displays.hasExternal) {
        switch ScreenPolicy.action(clamshellActive: clamshellActive, lidClosed: lidClosed,
                                   externalDisplay: external, dimmed: isDimmed,
                                   blank: blankedAt != nil) {
        case .dim: dim()
        case .restore: restore()
        case .none: break
        }
    }

    private func startBlank() {
        appLog.notice("screen off")
        blankedAt = Date()
        Blackout.apply()
        applyScreenPolicy()
        inputWatch?.invalidate()
        inputWatch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForInput() }
        }
        onBlankChange?()
    }

    private func checkForInput() {
        guard let blankedAt else { return }
        // Any mouse, trackpad or key event since the screen went black.
        if UserInput.idleSeconds < Date().timeIntervalSince(blankedAt) {
            endBlank()
            applyScreenPolicy()
        }
    }

    private func endBlank() {
        appLog.notice("screen back on")
        blankedAt = nil
        inputWatch?.invalidate()
        inputWatch = nil
        Blackout.restore()
        onBlankChange?()
    }

    private var isDimmed: Bool {
        defaults.object(forKey: Key.brightness) != nil || defaults.object(forKey: Key.keyboard) != nil
    }

    func releaseAll() {
        if blankedAt != nil { endBlank() }
        setDisplayAwake(false)
        restore()
    }

    private func setDisplayAwake(_ on: Bool) {
        if on, assertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Tether: clamshell mode keeps the screen unlocked" as CFString,
                                                     &id)
            if result == kIOReturnSuccess { assertion = id }
            appLog.notice("keep-screen-on request: \(result == kIOReturnSuccess ? "held" : "failed \(result)", privacy: .public)")
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
            appLog.notice("keep-screen-on request: released")
        }
    }

    private func dim() {
        if let level = BuiltInBrightness.get(), ScreenPolicy.worthSaving(level) {
            appLog.notice("dimming the built-in screen from \(level, privacy: .public) (\(self.lidClosed ? "lid closed" : "screen off", privacy: .public))")
            defaults.set(level, forKey: Key.brightness)
            BuiltInBrightness.set(0)
        }
        if let backlight = KeyboardBacklight.get() {
            // Kept even when the backlight is idle-off, so ambient control is handed back later.
            defaults.set(backlight.level, forKey: Key.keyboard)
            defaults.set(backlight.auto, forKey: Key.keyboardAuto)
            KeyboardBacklight.set(level: 0, auto: false)
        }
    }

    private func restore() {
        if defaults.object(forKey: Key.brightness) != nil {
            appLog.notice("restoring the built-in screen to \(self.defaults.float(forKey: Key.brightness), privacy: .public)")
            BuiltInBrightness.set(defaults.float(forKey: Key.brightness))
            defaults.removeObject(forKey: Key.brightness)
        }
        if defaults.object(forKey: Key.keyboard) != nil {
            KeyboardBacklight.set(level: defaults.float(forKey: Key.keyboard),
                                  auto: defaults.bool(forKey: Key.keyboardAuto))
            defaults.removeObject(forKey: Key.keyboard)
            defaults.removeObject(forKey: Key.keyboardAuto)
        }
    }
}
