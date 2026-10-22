import AppKit
import SwiftUI
import TetherCore

@MainActor
final class PowerActivityInspector: ObservableObject {
    struct RunningUtility: Identifiable {
        var id: Int32 { pid }
        let name: String
        let pid: Int32
    }
    struct InstalledUtility: Identifiable {
        var id: String { bundleID.lowercased() + ":" + bundleURL.path }
        let name: String
        let bundleID: String
        let bundleURL: URL
        let runningPID: Int32?
        let requestKinds: Set<SleepBlocker.Kind>
        let requestPIDs: [Int32]
        let opposesDisplaySleep: Bool
        let assertionsAvailable: Bool
        var overlapDescriptions: [String] {
            if !assertionsAvailable {
                return [L("Request observation is unavailable. Installation alone cannot establish an active overlap or conflict.",
                          "현재 요청을 확인하지 못했습니다. 설치 여부만으로 활성 중복이나 충돌을 판단할 수 없습니다.")]
            }
            if !requestKinds.isEmpty {
                return PowerRequestFinding(pid: runningPID ?? 0, process: name, kinds: requestKinds,
                    opposesDisplaySleep: opposesDisplaySleep).overlapDescriptions
            }
            return [L("No keep-awake request from this app was observed. Its keep-awake sessions/triggers may overlap Tether when enabled; review the app's settings to confirm.",
                      "이번 점검에서는 이 앱의 절전 방지 요청이 없었습니다. 절전 방지 세션·트리거를 켜면 Tether의 작업 유지와 겹칠 수 있으며, 실제 설정은 해당 앱에서 확인하세요.")]
        }
        var adjustmentGuidance: String {
            L("Open this app and stop the unused keep-awake session or automatic trigger. To remove it, quit it from its menu, then reveal its installed location in Finder. Tether does not delete apps or their helpers.",
              "해당 앱에서 사용하지 않는 절전 방지 세션·자동 트리거를 끄세요. 제거하려면 해당 앱을 먼저 종료하고 Finder에서 설치 위치를 확인하세요. 도우미가 있는 앱은 해당 앱의 제거 안내를 따르세요.")
        }
    }
    @Published var utilities: [RunningUtility] = []
    @Published private(set) var installedUtilities: [InstalledUtility] = []
    @Published private(set) var globalSleepDisabled: Bool?
    @Published var requests: [PowerRequestFinding] = []
    @Published private(set) var activitySignals: [PowerActivitySignal]?
    @Published private(set) var sleepPreferences = PowerSleepPreferences()
    @Published private(set) var observedPower: PowerSource = .unknown
    @Published private(set) var systemRequestPIDs: Set<Int32> = []
    var appRequests: [PowerRequestFinding] { requests.filter { !systemRequestPIDs.contains($0.pid) } }
    var systemRequests: [PowerRequestFinding] { requests.filter { systemRequestPIDs.contains($0.pid) } }
    @Published var displays: DisplayReport?
    @Published private(set) var remoteContext: RemoteInteropContext?
    @Published var busy = false
    @Published var checkedAt: Date?
    @Published var note: String?
    @Published var clearedRequests = 0
    @Published var assertionsAvailable = true
    private var task: Task<Void, Never>?
    private var apps: [Int32: NSRunningApplication] = [:]
    private var generation = 0
    private var observation: PowerRequestReader.Result?
    private var lastBlockers: [SleepBlocker] = []
    private var displaySleepExpected = false
    private var displayRevision: UInt64 = 0
    private var sessionKey = "unavailable"
    let simulated: Bool

    init(simulated: Bool) {
        self.simulated = simulated
        if simulated { loadSample(displaySleepExpected: true) }
    }

    func refresh(displaySleepExpected: Bool, topology: DisplayTopology = .none,
                 displayRevision: UInt64 = 0, sessionKey: String = "unavailable",
                 isScopeCurrent: (() -> Bool)? = nil) {
        self.displaySleepExpected = displaySleepExpected
        self.displayRevision = displayRevision; self.sessionKey = sessionKey
        task?.cancel(); generation += 1
        let requestGeneration = generation
        displays = nil; remoteContext = nil; busy = true; note = nil
        task = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, generation == requestGeneration, isScopeCurrent?() ?? true else {
                if generation == requestGeneration { busy = false }; return
            }
            if simulated {
                loadSample(displaySleepExpected: displaySleepExpected, topology: topology)
                busy = false; return
            }
            async let displayReport = Task.detached(priority: .utility) { DisplayProbe.inspect() }.value
            let requestObservation = await PowerRequestReader.capture(includePreferences: true)
            let displayResult = await displayReport
            // Notifications can arrive late. Recheck the real inventory after the
            // asynchronous request reads before attaching a remote evidence scope.
            let finalDisplays = await Task.detached(priority: .utility) { DisplayProbe.observations() }.value
            guard !Task.isCancelled, generation == requestGeneration,
                  self.displayRevision == displayRevision, self.sessionKey == sessionKey,
                  isScopeCurrent?() ?? true else { if generation == requestGeneration { busy = false }; return }
            let previous = Set(requests.map(\.id))
            observation = requestObservation
            lastBlockers = requestObservation.blockers ?? []
            requests = PowerActivityPolicy.requests(lastBlockers, displaySleepExpected: self.displaySleepExpected)
            assertionsAvailable = requestObservation.blockers != nil
            activitySignals = requestObservation.signals
            sleepPreferences = requestObservation.sleepPreferences
            observedPower = requestObservation.power
            systemRequestPIDs = requestObservation.systemPIDs
            clearedRequests = assertionsAvailable ? previous.subtracting(requests.map(\.id)).count : 0
            apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { _, last in last })
            utilities = apps.values.compactMap { app in
                PowerAppCatalog.name(bundleID: app.bundleIdentifier).map { RunningUtility(name: $0, pid: app.processIdentifier) }
            }.sorted { $0.name < $1.name }
            collectInstalledUtilities(observation: requestObservation)
            globalSleepDisabled = SystemProbe.snapshot().observedSleepDisabled
            publishDisplayCollection(report: displayResult, current: finalDisplays) {
                RemoteProviderProbe.capture(displays: displayResult, assertionHints: self.lastBlockers,
                    generation: UInt64(requestGeneration), displayRevision: displayRevision, sessionKey: sessionKey)
            }
            checkedAt = Date(); busy = false
        }
    }

    private func cancelCollection() { generation += 1; task?.cancel(); task = nil; busy = false; displays = nil; remoteContext = nil }
    func cancel() { cancelCollection() }
    static func inventoryIsCurrent(report: DisplayReport, current: [DisplayObservation]?) -> Bool {
        guard report.graphicsAvailable, let current else { return false }
        return report.displays.map(\.observation).sorted { $0.id < $1.id } == current.sorted { $0.id < $1.id }
    }
    /// Publish the display explanation and remote metadata from the same verified inventory.
    /// Even with late notifications, a known-mismatched report must not acquire a new check time.
    /// The caller's generation/session guard remains responsible for accepting the collection.
    func publishDisplayCollection(report: DisplayReport, current: [DisplayObservation]?, remote: () -> RemoteInteropContext) {
        guard Self.inventoryIsCurrent(report: report, current: current) else {
            displays = nil; remoteContext = nil
            note = L("The display observation changed or is unavailable. Check again for current display and remote details.",
                     "화면 정보가 바뀌었거나 확인되지 않습니다. 화면·원격 정보를 다시 점검해 주세요.")
            return
        }
        displays = report; remoteContext = remote()
    }
    func invalidateRemoteContext(displayRevision: UInt64, sessionKey: String) {
        guard self.displayRevision != displayRevision || self.sessionKey != sessionKey else { return }
        self.displayRevision = displayRevision; self.sessionKey = sessionKey
        cancelCollection()
    }
    func reclassify(displaySleepExpected: Bool) {
        self.displaySleepExpected = displaySleepExpected
        requests = PowerActivityPolicy.requests(lastBlockers, displaySleepExpected: displaySleepExpected)
        installedUtilities = installedUtilities.map { item in
            InstalledUtility(name: item.name, bundleID: item.bundleID, bundleURL: item.bundleURL,
                runningPID: item.runningPID, requestKinds: item.requestKinds, requestPIDs: item.requestPIDs,
                opposesDisplaySleep: displaySleepExpected && item.requestKinds.contains(.display),
                assertionsAvailable: item.assertionsAvailable)
        }
    }
    private func collectInstalledUtilities(observation: PowerRequestReader.Result) {
        var found: [InstalledUtility] = []
        for identifier in PowerAppCatalog.bundleIDs {
            let running = apps.values.filter { $0.bundleIdentifier?.lowercased() == identifier.lowercased() }
            let paths = running.compactMap(\.bundleURL) +
                [NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)].compactMap { $0 }
            for url in Set(paths.map { $0.resolvingSymlinksInPath() }) {
                guard let bundle = Bundle(url: url), bundle.bundleIdentifier?.lowercased() == identifier.lowercased(),
                      let name = PowerAppCatalog.name(bundleID: identifier) else { continue }
                let runningApp = running.first { $0.bundleURL?.resolvingSymlinksInPath() == url && !$0.isTerminated }
                let pids = observation.owners.filter { $0.value.bundlePath == url.path }.map(\.key)
                let kinds = Set((observation.blockers ?? []).filter { pids.contains($0.pid) }.map(\.kind))
                found.append(InstalledUtility(name: name, bundleID: bundle.bundleIdentifier ?? identifier,
                    bundleURL: url, runningPID: runningApp?.processIdentifier, requestKinds: kinds,
                    requestPIDs: pids.sorted(), opposesDisplaySleep: displaySleepExpected && kinds.contains(.display),
                    assertionsAvailable: observation.blockers != nil))
            }
        }
        installedUtilities = found.sorted { ($0.name, $0.bundleURL.path) < ($1.name, $1.bundleURL.path) }
    }
    private func verifiedBundleURL(_ pid: Int32) -> URL? {
        guard !simulated, let observation, let identity = observation.identities[pid],
              let owner = observation.owners[pid],
              PowerProcessIdentity.read(pid)?.started == identity.started,
              PowerProcessIdentity.read(owner.pid)?.started == owner.started,
              let app = observation.apps[pid], !app.isTerminated,
              let url = app.bundleURL?.resolvingSymlinksInPath(), url.path == owner.bundlePath,
              Bundle(url: url)?.bundleIdentifier == app.bundleIdentifier else { return nil }
        return url
    }
    func canReveal(_ pid: Int32) -> Bool { verifiedBundleURL(pid) != nil }
    func reveal(_ pid: Int32) {
        guard let url = verifiedBundleURL(pid) else {
            note = L("The app changed or its location is unavailable. Check again.", "앱이 바뀌었거나 위치를 확인할 수 없습니다. 다시 점검해 주세요."); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func canRevealUtility(_ item: InstalledUtility) -> Bool {
        !simulated && item.bundleURL.isFileURL && item.bundleURL.path.hasSuffix(".app") &&
            Bundle(url: item.bundleURL)?.bundleIdentifier?.lowercased() == item.bundleID.lowercased()
    }
    func canOpenUtility(_ item: InstalledUtility) -> Bool { canRevealUtility(item) }
    func revealUtility(_ item: InstalledUtility) {
        guard canRevealUtility(item) else {
            note = L("The installed app changed. Check again.", "설치된 앱이 바뀌었습니다. 다시 점검해 주세요."); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.bundleURL])
    }
    func openUtility(_ item: InstalledUtility) {
        guard canOpenUtility(item) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: item.bundleURL, configuration: configuration) { [weak self] _, error in
            if error != nil { Task { @MainActor in self?.note = L("Open this app from Finder or its menu bar.", "Finder나 해당 앱의 메뉴바에서 설정을 열어 주세요.") } }
        }
    }
    func canOpen(_ pid: Int32) -> Bool {
        !simulated && observation?.apps[pid] != nil && observation?.identities[pid] != nil
            && observation?.owners[pid] != nil
    }
    func open(_ pid: Int32) {
        guard !simulated, let observed = observation, let identity = observed.identities[pid],
              let owner = observed.owners[pid], let app = observed.apps[pid], !app.isTerminated,
              PowerProcessIdentity.read(pid)?.started == identity.started,
              PowerProcessIdentity.read(owner.pid)?.started == owner.started else {
            note = L("The process changed. Check again.", "프로세스가 바뀌었습니다. 다시 점검해 주세요."); return
        }
        if !app.activate() { note = L("Open this app from its menu bar icon.", "해당 앱의 메뉴바 아이콘에서 설정을 열어 주세요.") }
    }
    func openActivityMonitor() {
        guard !simulated, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.open(url)
    }
    func loadSample(displaySleepExpected: Bool, topology: DisplayTopology = .none) {
        utilities = [.init(name: "Amphetamine", pid: 204), .init(name: "Keepresso", pid: 318)]
        installedUtilities = [
            .init(name: "Amphetamine", bundleID: "com.if.Amphetamine", bundleURL: URL(fileURLWithPath: "/Applications/Amphetamine.app"), runningPID: 204,
                  requestKinds: [.display, .system], requestPIDs: [204], opposesDisplaySleep: displaySleepExpected, assertionsAvailable: true),
            .init(name: "Keepresso", bundleID: "sh.gyorgy.keepresso", bundleURL: URL(fileURLWithPath: "/Applications/Keepresso.app"), runningPID: nil,
                  requestKinds: [], requestPIDs: [], opposesDisplaySleep: false, assertionsAvailable: true)
        ]
        globalSleepDisabled = false
        observedPower = .ac
        sleepPreferences = .init(ac: .init(systemMinutes: 0, displayMinutes: 10, terminalKeepsAwake: true),
                                 battery: .init(systemMinutes: 1, displayMinutes: 2, terminalKeepsAwake: true))
        activitySignals = [.init(pid: 900, process: "WindowServer", kind: .userActivity,
                                 sourcePID: 901, source: "Codex Computer Use")]
        systemRequestPIDs = []
        lastBlockers = [
            SleepBlocker(pid: 880, process: "LM Studio", kind: .system, reason: ""),
            SleepBlocker(pid: 881, process: L("LLM app · screen-awake example", "LLM 앱 · 화면 켜짐 예시"), kind: .display, reason: ""),
            SleepBlocker(pid: 204, process: "Amphetamine", kind: .display, reason: "", assertionType: "PreventUserIdleDisplaySleep"),
            SleepBlocker(pid: 204, process: "Amphetamine", kind: .system, reason: "", assertionType: "PreventUserIdleSystemSleep"),
            SleepBlocker(pid: 562, process: L("Video export", "영상 내보내기"), kind: .system, reason: "")
        ]
        reclassify(displaySleepExpected: displaySleepExpected)
        var screens: [DisplayObservation] = [
            .init(id: 1, builtIn: true, vendor: 0x610, model: 0xa05c, width: 1800, height: 1169, active: true, asleep: false)
        ]
        if topology == .virtualOnly || topology == .externalWithVirtual {
            screens.append(.init(id: 15, builtIn: false, vendor: 0xeee0, model: 0xeee1, width: 2560, height: 1440, active: true, asleep: false))
        }
        if topology == .externalUnverified || topology == .externalWithVirtual {
            screens.append(.init(id: 20, builtIn: false, vendor: 123, model: 456, width: 1920, height: 1080, active: true, asleep: false))
        }
        displays = DisplayProbe.resolve(observations: topology == .unknown ? nil : screens, profile: Data(#"{"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_spdisplays_displayID":"1","_spdisplays_display-vendor-id":"610","_spdisplays_display-product-id":"a05c"},{"_name":"Splashtop Display 1","_spdisplays_displayID":"f","_spdisplays_display-vendor-id":"eee0","_spdisplays_display-product-id":"eee1"},{"_name":"External display","_spdisplays_displayID":"14","_spdisplays_display-vendor-id":"7b","_spdisplays_display-product-id":"1c8","spdisplays_connection_type":"spdisplays_hdmi"}]}]}"#.utf8))
        remoteContext = RemoteProviderProbe.sample(generation: UInt64(generation), displayRevision: displayRevision, sessionKey: sessionKey)
        checkedAt = Date()
    }

}
