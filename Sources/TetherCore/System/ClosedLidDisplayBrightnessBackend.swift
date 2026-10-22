import Foundation
import CoreGraphics
import Darwin

/// Narrow private-API adapter. Only a single currently identified built-in panel
/// is addressable; the presence of ANY additional output blocks new acquisition.
/// Loading symbols is not a hardware compatibility claim. Every value is queried
/// and bounded, and writes never fall back to an all-display command or IOKit knob.
public final class NativeClosedLidDisplayBrightnessBackend: ClosedLidDisplayBrightnessBackend {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let getter: GetBrightness?
    private let setter: SetBrightness?

    public init() {
        let opened = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        handle = opened
        getter = opened.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: GetBrightness.self) }
        setter = opened.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: SetBrightness.self) }
    }
    deinit { if let handle { dlclose(handle) } }

    public var support: ClosedLidDisplaySupport {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            return unavailable(.unsupportedSystem)
        }
        guard getter != nil, setter != nil else { return unavailable(.privateAPIUnavailable) }
        guard let displays = DisplayProbe.observations(), Set(displays.map(\.id)).count == displays.count else {
            return unavailable(.topologyUnavailable)
        }
        guard !displays.contains(where: { !$0.builtIn }) else { return unavailable(.externalDisplayPresent) }
        guard displays.count == 1, let panel = displays.first, panel.builtIn, panel.id != 0 else {
            return unavailable(.builtInDisplayUnavailable)
        }
        let target = ClosedLidDisplayTarget(id: panel.id, vendor: panel.vendor, model: panel.model)
        guard read(target: target) != nil else { return unavailable(.brightnessReadUnavailable) }
        return .init(availability: .candidateRequiresPhysicalValidation, target: target)
    }

    public func read(target: ClosedLidDisplayTarget) -> Float? {
        guard let getter, identifiesCurrentBuiltIn(target) else { return nil }
        var brightness: Float = .nan
        guard getter(target.id, &brightness) == 0, brightness.isFinite, (0...1).contains(brightness) else { return nil }
        return brightness
    }

    public func write(_ brightness: Float, target: ClosedLidDisplayTarget) -> Bool {
        guard brightness.isFinite, (0...1).contains(brightness), let setter,
              identifiesCurrentBuiltIn(target) else { return false }
        // Still address only the confirmed panel if external topology changed
        // during restoration. No command in this adapter can target all screens.
        return setter(target.id, brightness) == 0
    }

    private func identifiesCurrentBuiltIn(_ target: ClosedLidDisplayTarget) -> Bool {
        guard target.id != 0, let displays = DisplayProbe.observations(),
              Set(displays.map(\.id)).count == displays.count else { return false }
        let builtIn = displays.filter(\.builtIn)
        guard builtIn.count == 1, let panel = builtIn.first else { return false }
        return panel.id == target.id && panel.vendor == target.vendor && panel.model == target.model
    }
    private func unavailable(_ issue: ClosedLidDisplayIssue) -> ClosedLidDisplaySupport {
        .init(availability: .unavailable, issue: issue)
    }
}
