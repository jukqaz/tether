import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

public struct MacCapabilities: Equatable, Sendable {
    public enum Hardware: String, Codable, Sendable { case portable, desktop, unknown }
    public enum HelperInstallTarget: String, Sendable { case portable, desktop, unavailable, unsupported }
    public let supportedPlatform: Bool
    public let hardware: Hardware
    public let internalBattery: Bool?
    public let lid: Bool?
    public var generalIdleAvailable: Bool { supportedPlatform }
    public var lidControlAvailable: Bool { supportedPlatform && internalBattery == true && lid == true }
    /// A desktop uses user-session assertions. Missing observations do not authorize
    /// a privileged lid helper, even if one observation suggests a portable Mac.
    public var helperInstallTarget: HelperInstallTarget {
        guard supportedPlatform else { return .unsupported }
        if lidControlAvailable { return .portable }
        if hardware == .desktop { return .desktop }
        return .unavailable
    }

    public init(supportedPlatform: Bool, internalBattery: Bool?, lid: Bool?) {
        self.supportedPlatform = supportedPlatform
        self.internalBattery = internalBattery; self.lid = lid
        if internalBattery == true || lid == true { hardware = .portable }
        else if internalBattery == false && lid == false { hardware = .desktop }
        else { hardware = .unknown }
    }
}

extension SystemProbe {
    public static var capabilities: MacCapabilities {
        #if arch(arm64)
        let platform = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        #else
        let platform = false
        #endif
        var battery: Bool?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            var descriptions = [[String: Any]]()
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                    descriptions = []; battery = nil; break
                }
                descriptions.append(description)
            }
            if descriptions.count == sources.count {
                // A UPS is a separate source, never an internal battery.
                battery = descriptions.contains { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
            }
        }
        var lid: Bool?
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if root != 0 {
            defer { IOObjectRelease(root) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(root, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let values = properties?.takeRetainedValue() as? [String: Any] {
                lid = values["AppleClamshellState"] != nil
            }
        }
        return MacCapabilities(supportedPlatform: platform, internalBattery: battery, lid: lid)
    }

    /// Public console-user observation. Nil does not authorize a new user-owned session.
    /// No account names are retained or logged.
    public static var consoleUserID: UInt32? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              name != "loginwindow", uid != 0, uid != UInt32.max else { return nil }
        return uid
    }
}
