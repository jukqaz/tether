import Foundation

/// Serial, bounded brightness ownership. No timer and no sleep fallback: the GUI
/// supplies fresh lid/work/GUI authority and reuses its existing observation loop.
@MainActor
public final class ClosedLidDisplayDriver {
    public private(set) var state: ClosedLidDisplayState = .inactive
    public var support: ClosedLidDisplaySupport { backend.support }
    public var hasRecoveryDebt: Bool { record != nil || journalUnreadable }
    private let backend: ClosedLidDisplayBrightnessBackend
    private let journal: ClosedLidDisplayRecoveryJournaling
    private var record: ClosedLidDisplayRecoveryRecord?
    private var journalUnreadable = false
    private var ownsRecord = false
    private var requestedLast = false
    private var attempted = false
    private var recoveryAttempted = false
    private var observedTarget: ClosedLidDisplayTarget?
    private static let tolerance: Float = 0.005

    public init(backend: ClosedLidDisplayBrightnessBackend,
                journal: ClosedLidDisplayRecoveryJournaling) {
        self.backend = backend; self.journal = journal
        do {
            let loaded = try journal.load()
            if let loaded, !loaded.isValid { journalUnreadable = true }
            else { record = loaded }
        } catch { journalUnreadable = true }
        if hasRecoveryDebt { state = .recoveryPending(.journalUnavailable) }
    }

    /// Call at startup before new acquisitions. A retained record is recovery
    /// authority only; it never resumes a prior work session or zero-brightness hold.
    public func recover() {
        guard !recoveryAttempted else { return }
        recoveryAttempted = true
        restore()
    }

    /// Explicit retry re-reads a retained/corrupt journal instead of replacing it.
    public func retryRecovery() {
        if journalUnreadable {
            do {
                let loaded = try journal.load()
                guard loaded?.isValid ?? true else { state = .recoveryPending(.journalUnavailable); return }
                record = loaded; journalUnreadable = false
            } catch { state = .recoveryPending(.journalUnavailable); return }
        }
        recoveryAttempted = false
        recover()
    }

    /// `eligible` requires a live authorized lid hold and confirmed closed lid.
    /// Unreadable observations must be passed as false. A protected/stopped/open
    /// session restores its own brightness; unrelated system work stays independent.
    public func update(mode: ClosedLidDisplayMode, eligible: Bool,
                       destructiveChangeAllowed: Bool = true) {
        let requested = mode == .zeroBrightness && eligible && destructiveChangeAllowed
        if !requested {
            if requestedLast { recoveryAttempted = false }
            requestedLast = false; attempted = false; observedTarget = nil
            if hasRecoveryDebt { recover(); return }
            state = mode == .unchanged && eligible ? .unchanged
                : (mode == .zeroBrightness && eligible && !destructiveChangeAllowed ? .deferred : .inactive)
            return
        }
        if !requestedLast { attempted = false }
        requestedLast = true
        if journalUnreadable { state = .recoveryPending(.journalUnavailable); return }
        // A crash journal must first be recovered, never adopted as a new hold.
        if record != nil && !ownsRecord { attempted = true; recover(); return }
        let capability = backend.support
        guard capability.canAttemptZeroBrightness, let target = capability.target else {
            if hasRecoveryDebt { recover(); if hasRecoveryDebt { return } }
            attempted = true
            state = .unavailable(capability.issue ?? .builtInDisplayUnavailable)
            return
        }
        if let observedTarget {
            guard target == observedTarget else {
                recover(); if !hasRecoveryDebt { state = .unavailable(.recoveryTargetUnavailable) }
                return
            }
            observeHolding(target: observedTarget)
            return
        }
        guard !attempted else { return }
        attempted = true
        guard let original = valid(backend.read(target: target)) else {
            state = .unavailable(.brightnessReadUnavailable); return
        }
        observedTarget = target
        // Already zero belongs to its previous writer. Observe, but do not invent
        // a nonzero restore value or claim ownership of that setting.
        if close(original, 0) { state = .brightnessZero; return }
        let prepared = ClosedLidDisplayRecoveryRecord(target: target, original: original)
        do { try journal.save(prepared); record = prepared; recoveryAttempted = false }
        catch { state = .unavailable(.journalUnavailable); return }
        // A user's brightness key can race the durable journal write. Recheck
        // ownership before applying; a changed value belongs to that writer.
        guard let beforeWrite = valid(backend.read(target: target)) else {
            state = .recoveryPending(.brightnessReadUnavailable); return
        }
        guard close(beforeWrite, original) else { relinquish(); return }
        guard backend.write(0, target: target) else {
            state = .recoveryPending(.brightnessWriteFailed); return
        }
        guard let actual = valid(backend.read(target: target)) else {
            state = .recoveryPending(.brightnessReadUnavailable); return
        }
        guard close(actual, 0) else {
            state = .recoveryPending(.readbackMismatch); return
        }
        var applied = prepared; applied.phase = .applied
        do { try journal.save(applied); record = applied }
        catch { state = .recoveryPending(.journalUnavailable); return }
        ownsRecord = true; recoveryAttempted = false
        state = .brightnessZero
    }

    private func observeHolding(target: ClosedLidDisplayTarget) {
        guard let actual = valid(backend.read(target: target)) else {
            state = .recoveryPending(.brightnessReadUnavailable); return
        }
        guard close(actual, 0) else {
            if record != nil { relinquish() }
            else { state = .userChangePreserved }
            return
        }
        state = .brightnessZero
    }

    private func restore() {
        guard !journalUnreadable else { state = .recoveryPending(.journalUnavailable); return }
        guard var saved = record else { ownsRecord = false; state = .inactive; return }
        guard saved.isValid else { state = .recoveryPending(.journalUnavailable); return }
        if saved.phase == .relinquished { finishRemoval(final: .userChangePreserved); return }
        guard let current = valid(backend.read(target: saved.target)) else {
            state = .recoveryPending(.recoveryTargetUnavailable); return
        }
        if close(current, saved.original) { finishRemoval(final: .inactive); return }
        // A later user/other-app change wins. Never re-zero it and never overwrite
        // it with an old original, including during recovery after a forced exit.
        guard close(current, saved.applied) else { relinquish(); return }
        saved.phase = .restoring
        do { try journal.save(saved); record = saved }
        catch { state = .recoveryPending(.journalUnavailable); return }
        // Recheck after the durable write. There is no atomic brightness CAS; this
        // narrows the race without claiming to lock out the hardware brightness keys.
        guard let beforeWrite = valid(backend.read(target: saved.target)) else {
            state = .recoveryPending(.brightnessReadUnavailable); return
        }
        guard close(beforeWrite, saved.applied) else {
            if close(beforeWrite, saved.original) { finishRemoval(final: .inactive) }
            else { relinquish() }
            return
        }
        let accepted = backend.write(saved.original, target: saved.target)
        guard let actual = valid(backend.read(target: saved.target)), close(actual, saved.original) else {
            state = .recoveryPending(accepted ? .readbackMismatch : .brightnessWriteFailed); return
        }
        finishRemoval(final: .inactive)
    }

    private func relinquish() {
        guard var saved = record else { state = .userChangePreserved; return }
        saved.phase = .relinquished
        do { try journal.save(saved); record = saved }
        catch { state = .recoveryPending(.journalUnavailable); return }
        ownsRecord = false
        finishRemoval(final: .userChangePreserved)
    }
    private func finishRemoval(final: ClosedLidDisplayState) {
        do { try journal.remove(); record = nil; ownsRecord = false; state = final }
        catch { state = .recoveryPending(.journalUnavailable) }
    }
    private func valid(_ value: Float?) -> Float? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
    private func close(_ lhs: Float, _ rhs: Float) -> Bool { abs(lhs - rhs) <= Self.tolerance }
}
