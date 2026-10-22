import Foundation
import CoreGraphics
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import TetherCore

// Function-like IOKit macros are not imported into Swift; values from IOMessage.h and IOPM.h.
private let kMessageCanSystemSleep: UInt32 = 0xE000_0270
private let kMessageSystemWillSleep: UInt32 = 0xE000_0280
private let kMessageSystemHasPoweredOn: UInt32 = 0xE000_0300
private let kMessageClamshellStateChange: UInt32 = 0xE003_4100

/// IOKit and Darwin notifications: power source, sleep and wake, and the lid.

extension Helper {
    var systemPowerObservationAvailable: Bool {
        if dryRun {
            // Existing fixtures have a working observer unless failure is
            // explicitly injected. A malformed/null injected fact is unavailable.
            guard let value = fake["systemPowerObservationAvailable"] else { return true }
            return value as? Bool == true
        }
        return systemPowerNotificationsRegistered
    }

    func watchPowerSource() {
        guard !dryRun else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue().schedule(.power)
        }, context)?.takeRetainedValue() else {
            log("warning: power source notifications unavailable")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceNotificationsRegistered = true
    }

    func watchSystemPower() {
        guard !dryRun else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &powerNotifyPort, { context, _, messageType, argument in
            guard let context else { return }
            Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue()
                .handleSystemPower(UInt32(messageType), argument)
        }, &powerNotifier)
        guard rootPort != 0, powerNotifier != 0, let port = powerNotifyPort,
              let source = IONotificationPortGetRunLoopSource(port) else {
            log("warning: sleep/wake notifications unavailable")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source.takeUnretainedValue(), .defaultMode)
        systemPowerNotificationsRegistered = true
    }

    func handleSystemPower(_ messageType: UInt32, _ argument: UnsafeMutableRawPointer?) {
        if control.debugLog == true {
            let name = [kMessageCanSystemSleep: "can sleep?", kMessageSystemWillSleep: "will sleep",
                        kMessageSystemHasPoweredOn: "powered on"][messageType] ?? String(format: "0x%08x", messageType)
            log("system power: \(name)")
        }
        switch messageType {
        case kMessageCanSystemSleep:
            // Never veto sleep; an unanswered message would delay it by 30 seconds.
            if !dryRun { IOAllowPowerChange(rootPort, Int(bitPattern: argument)) }
        case kMessageSystemWillSleep:
            systemSleepTransition = true
            closedLidSleep.reset()
            sleepDeferralReason = nil
            manualSession.end(.sessionEnded)
            consumeCoordinatedWorkForSystemSleep()
            if var receipt = state.lidEndReceipt, receipt.phase == .consumed,
               receipt.observedSleepAt == nil, receipt.outcome == "commandAccepted" {
                receipt.observedSleepAt = manualClock
                state.lidEndReceipt = receipt
                _ = saveState()
            }
            sleepRetryActive = false
            // Honor an OS/user sleep transition and do not retain a keep-awake override.
            _ = applyOverride(false)
            displayGate.reset()
            saveProtection()
            // Quick reads and one small write, then let it go.
            usage.sleeps.willSleep(at: Date().timeIntervalSince1970, percent: currentReadings().batteryPercent,
                                   onBattery: currentSnapshot().power == .battery,
                                   byTether: Date().timeIntervalSince(lastSleepRequestAt) < 90)
            JSONFile.write(usage, to: usagePath, permissions: 0o644)
            writeStatus(readings: currentReadings())
            if !dryRun { IOAllowPowerChange(rootPort, Int(bitPattern: argument)) }
        case kMessageSystemHasPoweredOn:
            systemSleepTransition = false
            closedLidSleep.reset()
            sleepDeferralReason = nil
            sleepNowUntil = .distantPast
            sleepRetryActive = false
            justWoke = true
            schedule(.wake)
        default:
            break
        }
    }

    func watchClamshell() {
        guard !dryRun else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            log("warning: lid notifications unavailable")
            return
        }
        defer { IOObjectRelease(service) }
        interestPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, service, "IOGeneralInterest", { context, _, messageType, _ in
            guard let context, UInt32(messageType) == kMessageClamshellStateChange else { return }
            Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue().schedule(.lid)
        }, context, &clamshellNotifier)
        if result != KERN_SUCCESS { log("warning: lid notifications failed (\(result))") }
        else { lidNotificationsRegistered = true }
    }
}

extension Helper {
    /// Exercise the same IOKit transition handler without sleeping the developer's Mac.
    func simulateSystemPowerTransition() {
        guard dryRun, systemPowerObservationAvailable, let sleeping = fake["systemSleeping"] as? Bool,
              sleeping != systemSleepTransition else { return }
        handleSystemPower(sleeping ? kMessageSystemWillSleep : kMessageSystemHasPoweredOn, nil)
    }
}

private let displayChanged: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard !flags.contains(.beginConfigurationFlag), let context else { return }
    let helper = Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { helper.schedule(.display) }
}

extension Helper {
    func watchDisplays() {
        guard !dryRun else { return }
        let result = CGDisplayRegisterReconfigurationCallback(displayChanged, Unmanaged.passUnretained(self).toOpaque())
        if result != .success { log("display notifications unavailable: \(result.rawValue)") }
    }
}
