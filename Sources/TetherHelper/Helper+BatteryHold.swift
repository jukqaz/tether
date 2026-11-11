import Foundation
import TetherCore

/// The battery hold: its safety limits and Low Power Mode.
extension Helper {
    func updatePendingHold(_ snapshot: Snapshot) {
        guard let minutes = control.pendingHoldMinutes else { return }
        guard !effectiveEnabled || snapshot.power != .ac else { return }
        var next = control; next.pendingHoldMinutes = nil
        // Unknown power and Dark Wake cancel the reservation, never defer a surprise activation.
        if effectiveEnabled, snapshot.power == .battery, snapshot.fullWake,
           !enforcesGUIAuthority || guiControlConfirmed {
            next.batteryHoldUntil = Date().addingTimeInterval(Double(minutes * 60)).timeIntervalSince1970
        } else { next.holdSource = nil }
        if !commitControl(next) { protection.block("stateWriteFailed") }
    }

    func updateAutomaticHold(_ snapshot: Snapshot) {
        if enforcesGUIAuthority, !guiControlConfirmed { return }
        // Wake state is not a new power transition. A dark wake must neither cancel a
        // running timer nor re-arm one that the user already canceled.
        let eligible = effectiveEnabled && control.condition.includesBattery && snapshot.power == .battery
        // Brief AC/unknown observations must not re-arm a canceled timer.
        let entered: Bool
        if snapshot.power == .battery || !effectiveEnabled || !control.condition.includesBattery {
            entered = automaticHoldGate.entering(eligible: eligible)
        } else {
            if powerGate.confirmedAC { automaticHoldGate.reset(eligible: false) }
            entered = false
        }
        if control.holdSource == "automatic", !eligible {
            var next = control; next.batteryHoldUntil = nil; next.holdSource = nil
            if !commitControl(next) { protection.block("stateWriteFailed") }
        }
        guard entered, snapshot.fullWake, !holdWasActive,
              state.holdDeadline(requested: control.batteryHoldUntil, now: Date()) == nil else { return }
        var next = control
        next.batteryHoldUntil = Date().addingTimeInterval(Double(control.automaticMinutes * 60)).timeIntervalSince1970
        next.holdSource = "automatic"
        if !commitControl(next) { protection.block("stateWriteFailed") }
    }

    /// Applies the hold's safety limits and Low Power Mode; returns whether the hold is active.
    func updateBatteryHold(_ s: Snapshot, readings: SafetyReadings) -> Bool {
        let now = Date()
        let user = limits
        var deadline = effectiveEnabled
            ? state.holdDeadline(requested: control.batteryHoldUntil, now: now, maxHold: SafetyPolicy.maxHold(user))
            : nil
        protection.prepareBatteryBudget(power: s.power, needed: deadline != nil, clock: ContinuousTime.now, boot: currentBootID)
        if let requested = deadline, s.power == .battery {
            let remaining = protection.batteryRemaining(clock: ContinuousTime.now, user: user)
            if remaining <= 0 { protection.block("budget") }
            deadline = min(requested, now.addingTimeInterval(remaining))
        }
        if let requested = deadline, let continuous = state.holdContinuousDeadline {
            deadline = min(requested, now.addingTimeInterval(max(0, continuous - ContinuousTime.now)))
        }
        if deadline == nil, holdWasActive { endHold(.cancelled, readings: nil) }

        if let d = deadline {
            if s.power == .battery {
                let clock = ContinuousTime.now
                if let end = readings.batteryPercent == nil ? HoldEnd.sensor : SafetyPolicy.verdict(readings, lidClosed: s.lidClosed, now: Date(timeIntervalSince1970: clock),
                                                  holdUntil: Date(timeIntervalSince1970: clock + d.timeIntervalSince(now)), warmSince: nil, user: user) {
                    endHold(end, readings: readings)
                    deadline = nil
                }
            } else if now >= d {
                endHold(.time, readings: nil)  // ran out while plugged in: nothing to undo
                deadline = nil
            }
        }

        let active = deadline != nil
        holdWasActive = active
        let onBattery = active && s.power == .battery
        // Recorded whether or not Low Power Mode is allowed to help.
        if onBattery, !holdingOnBattery {
            note(.holdOnBattery)
            usage.stats.recordBatteryHold(now: now)
        }
        holdingOnBattery = onBattery
        return active
    }

    func endHold(_ reason: HoldEnd, readings: SafetyReadings?) {
        if reason != .cancelled, reason != .time {
            protection.block(reason.rawValue)
        }
        consumeHold()
        lastHoldEnd = reason
        lastHoldEndAt = Date().timeIntervalSince1970
        note(.holdEnded(reason))
        if let readings { logReadings(readings) }
    }

    func logReadings(_ r: SafetyReadings) {
        log(String(format: "  battery %.1f°C, thermal %d, charge %@%%, current %@ mA", r.temperature ?? -1, r.thermal,
                   r.batteryPercent.map(String.init) ?? "?", r.current.map(String.init) ?? "?"))
    }

    /// Marks the hold used up, so it never comes back on its own.
    func consumeHold() {
        state.consumedHold = state.holdValue
        saveState()
        holdWasActive = false
    }

}
