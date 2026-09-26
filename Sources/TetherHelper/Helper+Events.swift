import Foundation
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
    func watchPowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue().schedule(.power)
        }, context)?.takeRetainedValue() else {
            log("warning: power source notifications unavailable")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func watchSystemPower() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &powerNotifyPort, { context, _, messageType, argument in
            guard let context else { return }
            Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue()
                .handleSystemPower(UInt32(messageType), argument)
        }, &powerNotifier)
        guard rootPort != 0, let port = powerNotifyPort else {
            log("warning: sleep/wake notifications unavailable")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)
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
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case kMessageSystemWillSleep:
            // Quick reads and one small write, then let it go.
            usage.sleeps.willSleep(at: Date().timeIntervalSince1970, percent: SystemProbe.batteryPercent(),
                                   onBattery: SystemProbe.powerSource() == .battery,
                                   byTether: Date().timeIntervalSince(lastSleepRequestAt) < 90)
            JSONFile.write(usage, to: usagePath, permissions: 0o644)
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case kMessageSystemHasPoweredOn:
            sleepNowUntil = .distantPast
            sleepRetryActive = false
            justWoke = true
            schedule(.wake)
        default:
            break
        }
    }

    func watchClamshell() {
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
    }
}
