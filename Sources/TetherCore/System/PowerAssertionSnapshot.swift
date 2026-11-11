import Foundation
import IOKit.pwr_mgt

/// Read-only powerd observations shared by request diagnostics and our owned assertion.
/// A missing dictionary is ambiguous: Apple's implementation also returns it when no
/// process assertions are active. Require a separate, complete status proving that the
/// caller's relevant assertion types are off; unrelated types such as EnableIdleSleep
/// do not mean that an app is preventing sleep.
enum PowerAssertionSnapshot {
    typealias ByProcess = [NSNumber: [[String: Any]]]
    static let blockerTypes = [kIOPMAssertPreventUserIdleSystemSleep,
                               kIOPMAssertPreventUserIdleDisplaySleep,
                               kIOPMAssertionTypePreventSystemSleep,
                               kIOPMAssertNetworkClientActive as String]
    // Display and network activity are observed for diagnostics/screen commands.
    // They do not acquire authority over the end of our closed-lid work session.
    static let closedLidSleepBlockerTypes = [kIOPMAssertPreventUserIdleSystemSleep,
                                            kIOPMAssertionTypePreventSystemSleep]
    // Observed powerd metadata only; these strings do not create private assertions.
    static let activityTypes = blockerTypes + ["UserIsActive", "InternalPreventDisplaySleep"]

    static func read(relevantTypes: [String]) -> ByProcess? {
        var raw: Unmanaged<CFDictionary>?
        let code = IOPMCopyAssertionsByProcess(&raw)
        let value = raw?.takeRetainedValue()
        return decode(code: code, byProcess: value, relevantTypes: relevantTypes) {
            var status: Unmanaged<CFDictionary>?
            let code = IOPMCopyAssertionsStatus(&status)
            return (code, status?.takeRetainedValue())
        }
    }

    static func decode(code: IOReturn, byProcess: Any?, relevantTypes: [String] = blockerTypes,
                       status: () -> (code: IOReturn, value: Any?)) -> ByProcess? {
        guard code == kIOReturnSuccess else { return nil }
        if let byProcess { return byProcess as? ByProcess }

        let observed = status()
        guard observed.code == kIOReturnSuccess,
              let levels = observed.value as? [String: NSNumber],
              !levels.isEmpty else { return nil }
        guard !relevantTypes.isEmpty,
              relevantTypes.allSatisfy({ levels[$0]?.doubleValue == 0 }),
              levels.values.allSatisfy({
                  CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && $0.doubleValue >= 0
              }) else { return nil }
        return [:]
    }
}
