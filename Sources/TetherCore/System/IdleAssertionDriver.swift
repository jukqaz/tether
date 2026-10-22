import Foundation
import IOKit.pwr_mgt

/// User-process-owned finite idle assertions. Each driver owns a separate allocation;
/// it never changes a foreign assertion, lock settings or the global SleepDisabled flag.
public protocol IdleAssertionBackend: AnyObject {
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?)
    func renew(id: UInt32, timeout: TimeInterval) -> Int32
    func level(id: UInt32) -> Int?
    func release(id: UInt32) -> Int32
}

public final class NativeIdleAssertionBackend: IdleAssertionBackend {
    /// A display assertion prevents idle display sleep. It does not promise to bypass
    /// screen locks, change lock settings or simulate user input.
    public enum AssertionType: Equatable, Sendable {
        case system, display
        var nativeType: String {
            switch self {
            case .system: kIOPMAssertPreventUserIdleSystemSleep
            case .display: kIOPMAssertPreventUserIdleDisplaySleep
            }
        }
        var name: String {
            switch self {
            case .system: "Tether work session"
            case .display: "Tether display session"
            }
        }
    }
    public let type: AssertionType
    public convenience init() { self.init(type: .system) }
    public init(type: AssertionType) { self.type = type }
    public func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        guard timeout.isFinite, timeout >= IdleAssertionDriver.minimumLease else { return (Int32(kIOReturnBadArgument), nil) }
        var id: IOPMAssertionID = 0
        let code = IOPMAssertionCreateWithDescription(type.nativeType as CFString,
            type.name as CFString, nil, nil, nil, timeout,
            kIOPMAssertionTimeoutActionTurnOff as CFString, &id)
        return (Int32(code), code == kIOReturnSuccess ? id : nil)
    }
    public func renew(id: UInt32, timeout: TimeInterval) -> Int32 {
        guard timeout.isFinite, timeout >= IdleAssertionDriver.minimumLease else { return Int32(kIOReturnBadArgument) }
        let code = IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: timeout))
        guard code == kIOReturnSuccess else { return Int32(code) }
        return Int32(IOPMAssertionSetProperty(id, kIOPMAssertionLevelKey as CFString, NSNumber(value: kIOPMAssertionLevelOn)))
    }
    public func level(id: UInt32) -> Int? {
        let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
        guard let active = PowerAssertionSnapshot.read(relevantTypes: [type.nativeType]) else { return nil }
        return Self.confirmedLevel(id: id, pid: getpid(), properties: properties, active: active, type: type)
    }
    /// CopyProperties can retain level-on after a TurnOff timeout on the tested OS. Confirm
    /// the allocation against powerd's active list, rather than claiming it still holds.
    /// Undocumented identity fields are observation data only; missing fields fail closed.
    static func confirmedLevel(id: UInt32, pid: Int32, properties: [String: Any]?,
                               active: [NSNumber: [[String: Any]]]?, type: AssertionType = .system) -> Int? {
        guard let properties, let active,
              (properties["AssertionId"] as? NSNumber)?.uint32Value == id,
              (properties["AssertPID"] as? NSNumber)?.int32Value == pid,
              properties[kIOPMAssertionTypeKey as String] as? String == type.nativeType else { return nil }
        let uniqueID = properties["GlobalUniqueID"] as? NSNumber
        for entry in active[NSNumber(value: pid)] ?? [] {
            guard let entryID = entry["AssertionId"] as? NSNumber else { return nil }
            let sameID = entryID.uint32Value == id
            let sameUniqueID = uniqueID.map { $0 == entry["GlobalUniqueID"] as? NSNumber } ?? false
            guard sameID || sameUniqueID else { continue }
            guard entry[kIOPMAssertionTypeKey as String] as? String == type.nativeType,
                  let level = entry[kIOPMAssertionLevelKey as String] as? NSNumber,
                  [kIOPMAssertionLevelOff, kIOPMAssertionLevelOn].contains(level.intValue) else { return nil }
            return level.intValue
        }
        // A successfully queried active list without this allocation proves that it is
        // not currently active. Query failure or an ambiguous identity never proves off.
        return kIOPMAssertionLevelOff
    }
    public func release(id: UInt32) -> Int32 { Int32(IOPMAssertionRelease(id)) }
}

@MainActor
public final class IdleAssertionDriver {
    /// IOKit's timeout path can truncate fractional seconds. Never submit a sub-second
    /// lease that could become timeout=0 (unlimited); end our request slightly early.
    public nonisolated static let minimumLease: TimeInterval = 1
    public enum State: Equatable, Sendable { case inactive, holding, unverified, failed(Int32) }
    public private(set) var state: State = .inactive
    public private(set) var assertionID: UInt32?
    public private(set) var expiry: Double?
    /// The last observed-on finite deadline. Successful writes alone do not
    /// extend this evidence when powerd cannot be queried.
    public private(set) var confirmedExpiry: Double?
    /// A failed release is cleanup debt, not an allocation that may be renewed
    /// for a later policy request. The exact owned ID must be released first.
    public private(set) var releasePending = false
    private let backend: IdleAssertionBackend
    public init(backend: IdleAssertionBackend = NativeIdleAssertionBackend()) { self.backend = backend }

    /// Only a successful policy evaluation may supply a deadline. Nil ends our request.
    /// An elapsed deadline is never converted to the API's unlimited timeout=0.
    public func apply(expiry deadline: Double?, now: Double) {
        if releasePending {
            end()
            guard !releasePending else { return }
        }
        guard let deadline, deadline.isFinite, now.isFinite, deadline > now else { end(); return }
        let leaseDeadline = min(deadline, now + IdleSessionPolicy.healthTTL)
        guard leaseDeadline.isFinite, leaseDeadline - now >= Self.minimumLease else { end(); return }
        if let id = assertionID {
            observe()
            if state == .unverified {
                // Query before extending a known allocation. A shorter policy
                // deadline or the original evidence horizon ends it; never renew
                // while unobserved, even when this is the first failed query.
                guard let expiry, min(expiry, confirmedExpiry ?? expiry) > now,
                      leaseDeadline >= expiry else { end(); return }
                return
            }
            let code = backend.renew(id: id, timeout: leaseDeadline - now)
            guard code == 0 else { state = .failed(code); return }
        } else {
            let result = backend.create(timeout: leaseDeadline - now)
            guard result.code == 0, let id = result.id else { state = .failed(result.code == 0 ? Int32(kIOReturnError) : result.code); return }
            assertionID = id
        }
        expiry = leaseDeadline
        observe()
    }

    public func observe() {
        // Seeing the old allocation on cannot cancel an accepted end request.
        // Only successful cleanup authorizes a later, separate allocation.
        guard !releasePending else { return }
        guard let id = assertionID else { state = .inactive; confirmedExpiry = nil; return }
        guard let level = backend.level(id: id) else { state = .unverified; return }
        state = level == kIOPMAssertionLevelOn ? .holding : .inactive
        confirmedExpiry = state == .holding ? expiry : nil
    }

    public func end() {
        guard let id = assertionID else { state = .inactive; expiry = nil; confirmedExpiry = nil; releasePending = false; return }
        let code = backend.release(id: id)
        guard code == 0 else {
            // Preserve the ID and old OS expiry; do not create a second request or claim
            // completion when release is unconfirmed. A later end can retry this same ID.
            releasePending = true; state = .failed(code); return
        }
        assertionID = nil; expiry = nil; confirmedExpiry = nil; releasePending = false; state = .inactive
    }

    deinit { if let id = assertionID { _ = backend.release(id: id) } }
}
