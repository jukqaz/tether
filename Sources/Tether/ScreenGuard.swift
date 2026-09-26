import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import TetherCore

/// Keeps a clamshell session unlocked. This Mac locks the moment the display sleeps, so while
/// clamshell mode is on the display is held awake. With the lid shut and no external display the
/// built-in panel would stay lit under the lid, so it and the keyboard are dimmed to 0 instead of
/// being put to sleep, and restored once the lid is open again (see `ScreenPolicy`) or the app quits.
///
/// With a screen in view the same assertion would keep it lit forever while idle, so after a while
/// with no input (or on request) the screen is blanked instead: every display's gamma goes to
/// black and the built-in panel and keyboard are dimmed. Any input brings it all back, unlocked.
@MainActor
final class ScreenGuard {
    private var assertion: IOPMAssertionID = 0
    private let defaults = UserDefaults.standard
    private var clamshellActive = false
    private var lidClosed = false
    private var lidSeen = false
    private var lockMode = false
    private var blankedAt: Date?
    /// Input within this long after blanking is ignored: it is the click or hotkey that asked.
    private var blankGrace: TimeInterval = 0
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
        lockMode = lockOnLidClose
        setDisplayAwake(clamshellActive && !lockOnLidClose)
        // Working on an external display with the lid shut is not walking away.
        if lockOnLidClose, clamshellActive, lidJustClosed, !Displays.hasExternal {
            ScreenLock.now()
        }
        let visible = ScreenPolicy.screenVisible(lidClosed: lidClosed, externalDisplay: Displays.hasExternal)
        if blankedAt != nil, !clamshellActive || !visible || lockOnLidClose {
            endBlank()
        } else if blankedAt == nil, !lockOnLidClose,
                  ScreenPolicy.isIdleBlank(clamshellActive: clamshellActive, lidClosed: lidClosed,
                                           externalDisplay: Displays.hasExternal, idleSeconds: UserInput.idleSeconds,
                                           thresholdMinutes: idleBlankMinutes),
                  !DisplayAssertions.heldByOthers {
            startBlank(grace: 0)
        }
        applyScreenPolicy()
    }

    private func applyScreenPolicy() {
        switch ScreenPolicy.action(clamshellActive: clamshellActive, lidClosed: lidClosed,
                                   externalDisplay: Displays.hasExternal, dimmed: isDimmed,
                                   blank: blankedAt != nil) {
        case .dim: dim()
        case .restore: restore()
        case .none: break
        }
    }

    /// "Screen off" from the panel, a hotkey or a URL. Only while clamshell mode keeps a visible
    /// screen unlocked; otherwise macOS's own display sleep (and lock) is the right behaviour.
    @discardableResult
    func blankNow() -> Bool {
        guard clamshellActive, !lockMode,
              ScreenPolicy.screenVisible(lidClosed: lidClosed, externalDisplay: Displays.hasExternal)
        else { return false }
        if blankedAt == nil { startBlank(grace: 1.5) }
        return true
    }

    private func startBlank(grace: TimeInterval) {
        blankedAt = Date()
        blankGrace = grace
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
        let sinceBlank = Date().timeIntervalSince(blankedAt)
        guard sinceBlank > blankGrace else { return }
        // Any mouse, trackpad or key event after the grace period.
        if UserInput.idleSeconds < sinceBlank - blankGrace {
            endBlank()
            applyScreenPolicy()
        }
    }

    private func endBlank() {
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
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    private func dim() {
        if let level = BuiltInBrightness.get(), ScreenPolicy.worthSaving(level) {
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

/// Another app (a video player, a presentation, a call) keeping the display awake on purpose.
enum DisplayAssertions {
    static var heldByOthers: Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let me = Int(getpid())
        return byProcess.contains { pid, assertions in
            pid.intValue != me && assertions.contains { assertion in
                let type = assertion["AssertType"] as? String
                let level = assertion["AssertLevel"] as? Int ?? 255
                return level != 0 && (type == "PreventUserIdleDisplaySleep" || type == "NoDisplaySleepAssertion")
            }
        }
    }
}

/// Locks the screen at once, the way ⌃⌘Q does, through private login.framework.
enum ScreenLock {
    private typealias LockFn = @convention(c) () -> Int32
    private static let lockFn: LockFn? =
        dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
            .flatMap { dlsym($0, "SACLockScreenImmediate") }
            .map { unsafeBitCast($0, to: LockFn.self) }

    static var available: Bool { lockFn != nil }

    static func now() {
        _ = lockFn?()
    }
}

/// Every display's gamma to black: the screen shows nothing but stays awake, so nothing locks.
/// WindowServer also restores gamma by itself if this process exits.
enum Blackout {
    static func apply() {
        for display in Displays.online {
            CGSetDisplayTransferByFormula(display, 0, 0, 1, 0, 0, 1, 0, 0, 1)
        }
    }

    static func restore() {
        CGDisplayRestoreColorSyncSettings()
    }
}

enum Displays {
    static var online: [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static var builtIn: CGDirectDisplayID? { online.first { CGDisplayIsBuiltin($0) != 0 } }
    static var hasExternal: Bool { online.contains { CGDisplayIsBuiltin($0) == 0 } }
}

/// Built-in panel brightness through private DisplayServices, the path the brightness keys use.
enum BuiltInBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                                       RTLD_NOW)
    private static let getFn = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFn.self) }

    static func get() -> Float? {
        guard let getFn, let display = Displays.builtIn else { return nil }
        var value: Float = 0
        return getFn(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        guard let setFn, let display = Displays.builtIn else { return }
        _ = setFn(display, value)
    }
}

/// Keyboard backlight through private CoreBrightness, the path the backlight keys use.
enum KeyboardBacklight {
    private static let client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }()

    private static let keyboardID: UInt64? = {
        let selector = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let client, client.responds(to: selector),
              let ids = client.perform(selector)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return ids.first?.uint64Value
    }()

    private static func implementation<F>(_ name: String, as type: F.Type) -> (NSObject, Selector, F)? {
        let selector = NSSelectorFromString(name)
        guard let client, let method = class_getInstanceMethod(object_getClass(client), selector) else { return nil }
        return (client, selector, unsafeBitCast(method_getImplementation(method), to: type))
    }

    static func get() -> (level: Float, auto: Bool)? {
        typealias LevelFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
        typealias AutoFn = @convention(c) (AnyObject, Selector, UInt64) -> Bool
        guard let id = keyboardID,
              let (client, levelSelector, level) = implementation("brightnessForKeyboard:", as: LevelFn.self),
              let (_, autoSelector, isAuto) = implementation("isAutoBrightnessEnabledForKeyboard:", as: AutoFn.self)
        else { return nil }
        return (level(client, levelSelector, id), isAuto(client, autoSelector, id))
    }

    static func set(level: Float, auto: Bool) {
        typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        typealias EnableAutoFn = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Void
        guard let id = keyboardID,
              let (client, setSelector, setLevel) = implementation("setBrightness:forKeyboard:", as: SetFn.self),
              let (_, autoSelector, enableAuto) = implementation("enableAutoBrightness:forKeyboard:",
                                                                 as: EnableAutoFn.self)
        else { return }
        // Turn ambient-light control off first so it cannot raise the level again.
        if !auto { enableAuto(client, autoSelector, false, id) }
        _ = setLevel(client, setSelector, level, id)
        if auto { enableAuto(client, autoSelector, true, id) }
    }
}
