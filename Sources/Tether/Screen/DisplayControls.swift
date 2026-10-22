import AppKit
import IOKit

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
