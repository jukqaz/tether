import AppKit
import CoreAudio
import CoreBluetooth
import CoreWLAN
import EventKit
import Foundation
import IOBluetooth
import IOKit
import SystemConfiguration
import TetherCore

/// Selected conditions only. No permission prompts, audio capture, network scans,
/// process arguments, event titles, or unselected directory traversal.
@MainActor
final class V4NativeObservations {
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var selection: [V4Condition] = []
    private var scope: V4Scope?
    private var cache: [UUID: V4Observation] = [:]
    private lazy var eventStore = EKEventStore()
    private var isObserving = false
    private var cpuPrevious: [UInt32]?
    private var transferPrevious: (Double, UInt64)?
    private var activitySamples: [UUID: [V4ActivitySample]] = [:]
    private var activityAbove: [UUID: Bool] = [:]
    private var lastActivityAbove: [UUID: Double] = [:]
    private(set) var queryCounts: [String: Int] = [:]
    var onChange: (([V4Observation]) -> Void)?
    var queryOverride: ((V4Condition, Double) -> (V4ObservationState, Double?))?

    deinit {
        timer?.invalidate()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    static func permissionKnownGranted(for kind: V4ConditionKind) -> Bool {
        switch kind {
        case .calendar: return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .bluetooth: return CBCentralManager.authorization == .allowedAlways
        default: return true // Other conditions are checked when selected; no prompt or scan here.
        }
    }
    func configure(settings: V4Settings, enabled: Bool, scope: V4Scope, observing: Bool) {
        let selected = enabled && settings.automaticMode == .advanced
            ? settings.presets.first(where: { $0.id == settings.activePresetID && $0.enabled })?.groups
                .flatMap(\.conditions).filter { $0.enabled && $0.kind != .timeWindow && $0.kind != .taskEvent
                    && (settings.experimentalProvidersEnabled || ![.cpuLoad, .networkThroughput, .download, .audioPlayback, .microphoneInput, .cameraUsage].contains($0.kind)) } ?? [] : []
        guard self.selection != selected || self.scope != scope || isObserving != (observing && !selected.isEmpty) else { return }
        stop()
        self.selection = selected; self.scope = scope
        guard !selected.isEmpty else { onChange?([]); return }
        refresh(force: true)
        guard observing else { return }
        isObserving = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(force: true) }
            })
        }
        for name in [Notification.Name.EKEventStoreChanged, NSApplication.didChangeScreenParametersNotification,
                     NSNotification.Name.NSSystemClockDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(force: true) }
            })
        }
        let interval: Double = selected.contains { [.cpuLoad, .networkThroughput, .download].contains($0.kind) } ? 2 : 10
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = interval / 10
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []; selection = []; scope = nil; cache = [:]; isObserving = false
        cpuPrevious = nil; transferPrevious = nil
        activitySamples = [:]; activityAbove = [:]; lastActivityAbove = [:]
    }

    func refresh(force: Bool = false, now: Double = ContinuousTime.now) {
        guard let scope, !selection.isEmpty else { return }
        var activityCycle: [V4ConditionKind: (V4ObservationState, Double?)] = [:]
        for condition in selection {
            let period: Double = condition.kind == .calendar ? 60
                : [.cpuLoad, .networkThroughput, .download].contains(condition.kind) ? 2 : 10
            if !force, let previous = cache[condition.id], now - previous.observedAt < period { continue }
            queryCounts[condition.kind.providerID, default: 0] += 1
            var result: (V4ObservationState, Double?)
            let isActivity = [.cpuLoad, .networkThroughput].contains(condition.kind)
            if isActivity, let shared = activityCycle[condition.kind] { result = shared }
            else {
                result = queryOverride?(condition, now) ?? query(condition, now: now)
                if isActivity { activityCycle[condition.kind] = result }
            }
            if isActivity, let value = result.1, value.isFinite {
                var samples = (activitySamples[condition.id] ?? []).filter { now - $0.at <= 10 }
                samples.append(V4ActivitySample(at: now, value: value)); activitySamples[condition.id] = samples
                let threshold = condition.threshold ?? (condition.kind == .cpuLoad ? 20 : 1_048_576)
                let mean = samples.reduce(0) { $0 + $1.value / Double(samples.count) }
                let above = mean >= threshold || (activityAbove[condition.id] == true && mean >= threshold * 0.8)
                if above { lastActivityAbove[condition.id] = now }
                result = (V4ActivityWindow.evaluate(samples: samples, now: now, threshold: threshold,
                    lastSatisfiedAt: lastActivityAbove[condition.id], previouslyAboveThreshold: activityAbove[condition.id] == true), mean)
                activityAbove[condition.id] = above
            }
            cache[condition.id] = V4Observation(conditionID: condition.id, scope: scope,
                state: result.0, observedAt: now, validUntil: now + (condition.kind == .calendar ? 120 : isActivity ? 15 : 30),
                numericValue: result.1)
        }
        onChange?(Array(cache.values))
    }

    func requestCalendarAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    private func query(_ condition: V4Condition, now: Double) -> (V4ObservationState, Double?) {
        func match(_ value: Bool) -> (V4ObservationState, Double?) { (value ? .satisfied : .notSatisfied, nil) }
        switch condition.kind {
        case .appRunning:
            return match(NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == condition.target && !$0.isTerminated })
        case .appFrontmost:
            guard let app = NSWorkspace.shared.frontmostApplication else { return (.unknown, nil) }
            return match(app.bundleIdentifier == condition.target)
        case .process:
            // Match an executable path, never a process argument or ambiguous display name.
            guard condition.target.hasPrefix("/") else { return (.unknown, nil) }
            let count = proc_listallpids(nil, 0)
            guard count > 0, count < 1_000_000 else { return (.unknown, nil) }
            var pids = [Int32](repeating: 0, count: Int(count) + 64)
            let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
            guard written > 0, written < pids.count else { return (.unknown, nil) }
            var incomplete = false
            for pid in pids.prefix(Int(written)) where pid > 1 {
                if let process = ProcessIdentity.capture(pid: pid), process.executable == condition.target { return match(true) }
                else if !ProcessIdentity.exited(pid: pid), ProcessIdentity.capture(pid: pid) == nil { incomplete = true }
            }
            return incomplete ? (.unknown, nil) : match(false)
        case .wifiSSID:
            guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return match(false) }
            guard let ssid = interface.ssid() else { return (.permissionRequired, nil) }
            return match(ssid == condition.target)
        case .vpn, .ipAddress, .dns:
            guard let store = SCDynamicStoreCreate(nil, "Tether selected rule" as CFString, nil, nil) else { return (.unknown, nil) }
            if condition.kind == .vpn {
                guard let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv[46]" as CFString) as? [String] else { return (.unknown, nil) }
                return match(keys.contains { key in
                    guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                          let name = value["InterfaceName"] as? String,
                          name.hasPrefix("utun") || name.hasPrefix("ppp") else { return false }
                    return condition.target.isEmpty || condition.target == name || key.contains("/\(condition.target)/")
                })
            }
            let kind = condition.kind == .dns ? "DNS" : "IPv4"
            guard let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(kind)" as CFString) as? [String: Any] else { return (.unknown, nil) }
            let values = value[condition.kind == .dns ? "ServerAddresses" : "Addresses"] as? [String]
            if let values { return match(values.contains(condition.target)) }
            if condition.kind == .ipAddress, let service = value["PrimaryService"] as? String,
               let details = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any],
               let addresses = details["Addresses"] as? [String] { return match(addresses.contains(condition.target)) }
            return (.unknown, nil)
        case .volume:
            guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) else { return (.unknown, nil) }
            return match(urls.contains { url in
                url.path == condition.target || (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == condition.target
            })
        case .usb:
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return (.unknown, nil) }
            defer { IOObjectRelease(iterator) }
            while case let item = IOIteratorNext(iterator), item != 0 {
                defer { IOObjectRelease(item) }
                func number(_ key: String) -> UInt32? {
                    (IORegistryEntryCreateCFProperty(item, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint32Value
                }
                if let vendor = number("idVendor"), let product = number("idProduct"), let location = number("locationID"),
                   condition.target == "\(vendor):\(product):\(location)" { return match(true) }
            }
            return match(false)
        case .bluetooth:
            guard CBCentralManager.authorization == .allowedAlways else { return (.permissionRequired, nil) }
            guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return (.unknown, nil) }
            return match(devices.contains { $0.addressString == condition.target && $0.isConnected() })
        case .audioOutput:
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return (.unknown, nil) }
            address.mSelector = kAudioDevicePropertyDeviceUID
            var uid: Unmanaged<CFString>?; size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return (.unknown, nil) }
            return match(uid.takeRetainedValue() as String == condition.target)
        case .externalDisplay:
            guard let displays = DisplayProbe.observations() else { return (.unknown, nil) }
            return match(displays.contains { !$0.builtIn && String($0.id) == condition.target })
        case .calendar:
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return (.permissionRequired, nil) }
            guard let calendar = eventStore.calendar(withIdentifier: condition.target) else { return (.unknown, nil) }
            let wall = Date()
            let predicate = eventStore.predicateForEvents(withStart: wall.addingTimeInterval(-86400), end: wall.addingTimeInterval(1), calendars: [calendar])
            return match(eventStore.events(matching: predicate).contains { !$0.isAllDay && $0.status != .canceled && $0.startDate <= wall && wall < $0.endDate })
        case .cpuLoad:
            var info = host_cpu_load_info()
            var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return (.unknown, nil) }
            let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
            defer { cpuPrevious = ticks }
            guard let previous = cpuPrevious else { return (.unknown, nil) }
            let deltas = zip(ticks, previous).map { Double($0 &- $1) }, total = deltas.reduce(0, +)
            guard total > 0 else { return (.unknown, nil) }
            let percent = 100 * (total - deltas[Int(CPU_STATE_IDLE)]) / total
            return (percent >= (condition.threshold ?? 20) ? .satisfied : .notSatisfied, percent)
        case .networkThroughput:
            var addresses: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&addresses) == 0, let first = addresses else { return (.unknown, nil) }
            defer { freeifaddrs(addresses) }
            var total: UInt64 = 0, cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let item = cursor {
                let entry = item.pointee
                if entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                   let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    total &+= UInt64(data.ifi_ibytes); total &+= UInt64(data.ifi_obytes)
                }
                cursor = entry.ifa_next
            }
            defer { transferPrevious = (now, total) }
            guard let previous = transferPrevious, now > previous.0, total >= previous.1 else { return (.unknown, nil) }
            let rate = Double(total - previous.1) / (now - previous.0)
            return (rate >= (condition.threshold ?? 1_048_576) ? .satisfied : .notSatisfied, rate)
        case .microphoneInput, .cameraUsage, .audioPlayback, .download, .unsupported:
            // Experimental providers stay unavailable until qualified. App running
            // or a vanished partial file is never fabricated as work completion.
            return (.unsupported, nil)
        case .timeWindow, .taskEvent: return (.unknown, nil) // Supplied by the policy/event store.
        }
    }
}
