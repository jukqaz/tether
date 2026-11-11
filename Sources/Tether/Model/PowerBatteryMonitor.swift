import AppKit
import IOKit.ps
import TetherCore

enum PowerBatteryPhase: Equatable {
    case pending, fresh, stale, unavailable
}

/// Display-only telemetry. It never writes a session, assertion, setting, or safety input.
/// Multiple visible panels share one query and one timer; hidden panels do no work.
@MainActor
final class PowerBatteryMonitor: ObservableObject {
    static let refreshInterval: TimeInterval = 3
    static let staleAfter: TimeInterval = 10
    @Published private(set) var reading: PowerBatteryReading?
    @Published private(set) var phase: PowerBatteryPhase = .pending
    @Published private(set) var evaluatedAt = Date()
    @Published private(set) var isVisible = false
    let simulated: Bool
    private(set) var refreshCount = 0
    private var clients: Set<UUID> = []
    private let reader: () async -> PowerBatteryReading?
    private let clock: () -> Date
    private let observesSystem: Bool
    private var generation: UInt64 = 0
    private var requestID: UUID?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var source: CFRunLoopSource?
    private var sourceContext: PowerBatteryObservationContext?
    private var observers: [NSObjectProtocol] = []
    private var suspended = false

    init(simulated: Bool, observesSystem: Bool = true,
         reader: @escaping () async -> PowerBatteryReading? = {
             await Task.detached(priority: .utility) { SystemProbe.powerBatteryReading() }.value
         }, clock: @escaping () -> Date = Date.init) {
        self.simulated = simulated
        self.observesSystem = observesSystem
        self.reader = reader
        self.clock = clock
    }

    var activeClientCount: Int { clients.count }

    func setVisible(_ visible: Bool, client: UUID) {
        if visible {
            guard clients.insert(client).inserted else { return }
            guard clients.count == 1 else { return }
            isVisible = true
            guard !simulated else { return }
            suspended = false
            startObserving()
            refresh(invalidate: true)
        } else {
            guard clients.remove(client) != nil, clients.isEmpty else { return }
            isVisible = false
            guard !simulated else { return }
            generation &+= 1
            task?.cancel(); task = nil; requestID = nil
            timer?.invalidate(); timer = nil
            stopObserving()
            phase = .pending
            evaluatedAt = clock()
        }
    }

    /// Changes to sensor availability can only change this read-only display state.
    func refresh(invalidate: Bool = false) {
        guard !simulated, isVisible, !suspended else { return }
        if invalidate {
            generation &+= 1
            evaluatedAt = clock()
            phase = .pending
        } else {
            reevaluate()
        }
        // A power event invalidates the old result, but does not multiply IOKit reads.
        // Its generation mismatch queues exactly one new query after this one settles.
        guard requestID == nil else { return }
        let id = UUID(), epoch = generation
        requestID = id
        refreshCount += 1
        let read = reader
        task = Task { [weak self] in
            let value = await read()
            guard let self, self.requestID == id else { return }
            self.requestID = nil; self.task = nil
            guard self.isVisible, !self.suspended else { return }
            guard self.generation == epoch else { self.refresh(); return }
            self.evaluatedAt = self.clock()
            self.reading = value
            self.phase = value == nil ? .unavailable : .fresh
            self.reevaluate()
        }
    }

    func reevaluate() {
        guard !simulated else { return }
        evaluatedAt = clock()
        guard phase == .fresh, let reading else { return }
        let age = evaluatedAt.timeIntervalSince(reading.observedAt)
        if !age.isFinite || age < 0 { phase = .unavailable }
        else if age > Self.staleAfter { phase = .stale }
    }

    /// Invalidates pre-sleep values, including a late in-flight result.
    func willSleep() {
        guard !simulated else { return }
        suspended = true
        generation &+= 1
        phase = .pending
        evaluatedAt = clock()
    }

    func didWake() {
        guard !simulated else { return }
        suspended = false
        refresh(invalidate: true)
    }

    /// Only in-memory preview and XCTest models can select an illustrative state.
    func setFixture(reading: PowerBatteryReading?, phase: PowerBatteryPhase = .fresh,
                    evaluatedAt: Date = Date()) {
        guard simulated else { return }
        self.reading = reading
        self.phase = phase
        self.evaluatedAt = evaluatedAt
    }

    private func startObserving() {
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        guard observesSystem else { return }
        let context = PowerBatteryObservationContext(self)
        sourceContext = context
        source = IOPSNotificationCreateRunLoopSource({ opaque in
            guard let opaque else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerBatteryObservationContext>.fromOpaque(opaque)
                    .takeUnretainedValue().monitor?.refresh(invalidate: true)
            }
        }, Unmanaged.passUnretained(context).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didWake() }
            })
    }

    private func stopObserving() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; sourceContext = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }

    deinit {
        task?.cancel()
        timer?.invalidate()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}

private final class PowerBatteryObservationContext {
    weak var monitor: PowerBatteryMonitor?
    init(_ monitor: PowerBatteryMonitor) { self.monitor = monitor }
}
