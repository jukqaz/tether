import Foundation
import TetherCore

/// The battery hold: its safety limits and Low Power Mode.
extension Helper {
    /// Applies the hold's safety limits and Low Power Mode; returns whether the hold is active.
    func updateBatteryHold(_ s: Snapshot, readings: SafetyReadings) -> Bool {
        let now = Date()
        let user = limits
        var deadline = control.enabled
            ? state.holdDeadline(requested: control.batteryHoldUntil, now: now, maxHold: SafetyPolicy.maxHold(user))
            : nil
        if deadline == nil, holdWasActive { endHold(.cancelled, readings: nil) }

        if let d = deadline {
            if s.power == .battery {
                // A lid change switches between the open and closed limits: restart the countdown.
                if warmLidClosed != s.lidClosed {
                    warmSince = nil
                    warmLidClosed = s.lidClosed
                }
                if SafetyPolicy.isWarm(readings, lidClosed: s.lidClosed, user: user) {
                    if warmSince == nil { warmSince = now }
                } else {
                    warmSince = nil
                }
                if let end = SafetyPolicy.verdict(readings, lidClosed: s.lidClosed, now: now,
                                                  holdUntil: d, warmSince: warmSince, user: user) {
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
        manageLowPower(on: LowPowerPolicy.wantsOnBattery(holdingOnBattery: onBattery, allowed: control.holdLowPower))
        return active
    }

    func endHold(_ reason: HoldEnd, readings: SafetyReadings?) {
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
        warmSince = nil
    }

    /// Low Power Mode caps heat and drain while a closed Mac runs on battery, unless the user
    /// turned that off (see `LowPowerPolicy`).
    func manageLowPower(on: Bool) {
        if on, state.savedBatteryLowPower == nil {
            let current = SystemProbe.lowPowerMode(section: "Battery Power") ?? 0
            state.savedBatteryLowPower = current
            saveState()
            log("battery hold: Low Power Mode on\(current == 1 ? " (already on)" : "")")
            if current != 1 { pmset(["-b", "lowpowermode", "1"]) }
        } else if !on, let saved = state.savedBatteryLowPower {
            let restore = LowPowerPolicy.shouldRestore(current: SystemProbe.lowPowerMode(section: "Battery Power"), saved: saved)
            log("battery hold: Low Power Mode off, \(restore ? "restored" : "left as it is")")
            if restore { pmset(["-b", "lowpowermode", String(saved)]) }
            state.savedBatteryLowPower = nil
            saveState()
        }
    }
}
