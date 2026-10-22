import AppKit
import TetherCore

/// Shared read-only assertion capture for the passive notice and the detailed inspector.
/// Names are attached using a running app's bundle boundary, never an LLM-name allowlist.
@MainActor
enum PowerRequestReader {
    struct Result {
        var blockers: [SleepBlocker]?
        var identities: [Int32: PowerProcessIdentity] = [:]
        var owners: [Int32: PowerRunningApp] = [:]
        var apps: [Int32: NSRunningApplication] = [:]
        var signals: [PowerActivitySignal]?
        var systemPIDs: Set<Int32> = []
        var sleepPreferences = PowerSleepPreferences()
        var power: PowerSource = .unknown
    }

    static func capture(includePreferences: Bool = false) async -> Result {
        let ownPID = getpid()
        let observed = await Task.detached(priority: .utility) {
            let activity = SystemProbe.powerActivitySnapshot(excluding: [ownPID])
            let pids = Set((activity.blockers ?? []).map(\.pid) + (activity.signals ?? []).flatMap { [$0.pid, $0.sourcePID].compactMap { $0 } })
            let identities = Dictionary(uniqueKeysWithValues: pids.compactMap { pid in
                PowerProcessIdentity.read(pid).map { (pid, $0) }
            })
            let preferences = includePreferences ? PowerSleepPreferences.read() : PowerSleepPreferences()
            return (activity, identities, preferences, SystemProbe.powerSource())
        }.value
        var result = Result(blockers: observed.0.blockers, identities: observed.1,
                            signals: observed.0.signals, sleepPreferences: observed.2, power: observed.3)
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let candidates = apps.compactMap { app -> PowerRunningApp? in
            guard let path = app.bundleURL?.resolvingSymlinksInPath().path,
                  let identity = PowerProcessIdentity.read(app.processIdentifier) else { return nil }
            return PowerRunningApp(pid: identity.pid, started: identity.started,
                                   name: app.localizedName ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                                   bundlePath: path)
        }
        for (pid, identity) in observed.1 {
            if let path = identity.executable,
               ["/System/Library/", "/usr/libexec/", "/usr/sbin/"].contains(where: path.hasPrefix) {
                result.systemPIDs.insert(pid)
            }
            guard let owner = PowerRequestOwnership.app(for: identity, among: candidates),
                  let app = apps.first(where: { $0.processIdentifier == owner.pid }) else { continue }
            result.owners[pid] = owner
            result.apps[pid] = app
        }
        result.blockers = observed.0.blockers?.map { blocker in
            var named = blocker
            if let owner = result.owners[blocker.pid] { named.process = owner.name }
            // Assertion names can contain user text. The UI needs the assertion type, not its payload.
            named.reason = ""
            return named
        }
        result.signals = observed.0.signals?.map { signal in
            var named = signal
            if let owner = result.owners[signal.pid] { named.process = owner.name }
            if let sourcePID = signal.sourcePID, let identity = result.identities[sourcePID],
               PowerProcessIdentity.read(sourcePID)?.started == identity.started {
                named.source = result.owners[sourcePID]?.name ?? identity.executable.map { URL(fileURLWithPath: $0).lastPathComponent }
            }
            return named
        }
        return result
    }
}

/// Uses the app's existing refresh cadence. No new timer, CPU sampling or system_profiler work.
@MainActor
final class PowerRequestMonitor: ObservableObject {
    @Published private(set) var blockers: [SleepBlocker]?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var systemPIDs: Set<Int32> = []
    private var reading = false
    private var lastStarted: TimeInterval?
    let simulated: Bool

    init(simulated: Bool) {
        self.simulated = simulated
        if simulated {
            blockers = [SleepBlocker(pid: 880, process: "LM Studio", kind: .system, reason: "")]
            checkedAt = Date()
        }
    }

    func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !simulated, !reading, lastStarted.map({ now - $0 >= 15 }) ?? true else { return }
        reading = true; lastStarted = now
        Task { [weak self] in
            let result = await PowerRequestReader.capture()
            guard let self else { return }
            if blockers != result.blockers { blockers = result.blockers }
            systemPIDs = result.systemPIDs
            checkedAt = Date(); reading = false
        }
    }
}
