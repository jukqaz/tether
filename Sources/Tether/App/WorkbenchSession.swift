import Foundation
import TetherCore

private enum WorkbenchFailure: LocalizedError {
    case endpoint, liveHelper, coordinator, bridge
    case build(version: String?, number: Int?)
    var errorDescription: String? {
        switch self {
        case .endpoint: L("Preview must use its own temporary service endpoint.", "미리보기 전용 임시 통신 경로를 확인하지 못했습니다.")
        case .liveHelper: L("Preview requires a dry-run helper.", "미리보기에는 모의 실행 도우미가 필요합니다.")
        case let .build(version, number):
            L("Preview and its helper must use the same build.", "미리보기와 도우미의 빌드가 일치하지 않습니다.")
                + " \(TetherPaths.version) (\(TetherPaths.build)) / \(version ?? "?") (\(number.map(String.init) ?? "?"))"
        case .coordinator: L("Preview helper does not support the current session coordinator.", "미리보기 도우미가 현재 세션 제어 방식을 지원하지 않습니다.")
        case .bridge: L("Preview helper did not provide session handoff information.", "미리보기 도우미의 세션 인계 정보를 확인하지 못했습니다.")
        }
    }
}

/// The interactive preview uses the production session policy and private helper IPC.
/// Only its sensor inputs and idle assertion backend are simulated. It never installs a
/// helper or creates an OS assertion, and its preferences are removed with the preview.
@MainActor
final class WorkbenchSession {
    let model: AppModel
    let controller: UserSessionController
    let backend: WorkbenchIdleBackend
    let suite: String
    private let defaults: UserDefaults

    init(folder: URL, initial: ServiceReply,
         guiProbe: @escaping () -> GUISessionObservation = { GUISessionProbe.callerObservation() }) throws {
        let socket = folder.appendingPathComponent("service.sock").path
        guard socket == TetherPaths.serviceSocket, socket != TetherPaths.productionSocket else { throw WorkbenchFailure.endpoint }
        guard initial.protection?.dryRun == true else { throw WorkbenchFailure.liveHelper }
        guard initial.status?.matchesCurrentBuild == true else {
            throw WorkbenchFailure.build(version: initial.status?.version, number: initial.status?.build)
        }
        guard initial.status?.workSessionCoordinatorVersion == WorkSessionLease.coordinatorVersion else { throw WorkbenchFailure.coordinator }
        guard initial.workSessionBridge?.version == 1 else { throw WorkbenchFailure.bridge }
        let input = folder.appendingPathComponent("fake.json")
        let name = "TetherWorkbench." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: name) else { throw ServiceFailure("writeFailed") }
        suite = name; self.defaults = defaults
        let backend = WorkbenchIdleBackend(); self.backend = backend
        let controller = UserSessionController(defaults: defaults, backend: backend, guiProbe: guiProbe,
            environmentProbe: { WorkbenchInput.read(input).environment }, legacyControl: initial.control,
            requiresRootHandoff: initial.workSessionBridge?.coordinated != true)
        self.controller = controller
        controller.refresh()
        let connection = ServiceConnection(path: socket)
        model = AppModel(preview: true, capabilities: WorkbenchInput.read(input).capabilities,
            previewSession: controller, previewWorkService: { request in
                // Recheck the selected endpoint before each mutation. A path override
                // or stale initial snapshot is not authority to control a live service.
                let current = try await connection.perform(ServiceRequest(.snapshot))
                guard current.protection?.dryRun == true, current.status?.matchesCurrentBuild == true else {
                    throw ServiceFailure("unsupportedVersion")
                }
                let reply = request.action == .snapshot ? current : try await connection.perform(request)
                guard reply.protection?.dryRun == true else { throw ServiceFailure("unsupportedVersion") }
                return reply
            }, previewHelperReply: initial, previewDefaults: defaults,
            previewCoordinatorPath: folder.appendingPathComponent("app-instance.lock").path,
            previewCapabilitiesProbe: { WorkbenchInput.read(input).capabilities })
        guard model.coordinatorStartFailure == nil, model.usesUserSession else {
            _ = controller.end(); defaults.removePersistentDomain(forName: name)
            throw ServiceFailure("sessionUnavailable")
        }
    }

    func cleanup() {
        _ = controller.end()
        defaults.removePersistentDomain(forName: suite)
    }
}

/// A failed fixture read is an unavailable observation, never live hardware fallback.
struct WorkbenchInput: Decodable {
    enum Hardware: String, Decodable { case portable, desktop, unknown }
    var power: PowerSource?
    var thermal: Int?
    var battery: Int?
    var fullWake: Bool?
    var hardware: Hardware?

    var environment: UserSessionEnvironment {
        .init(power: power ?? .unknown, thermal: thermal, fullWake: fullWake, batteryPercent: battery)
    }
    var capabilities: MacCapabilities {
        switch hardware ?? .portable {
        case .portable: .init(supportedPlatform: true, internalBattery: true, lid: true)
        case .desktop: .init(supportedPlatform: true, internalBattery: false, lid: false)
        case .unknown: .init(supportedPlatform: true, internalBattery: nil, lid: nil)
        }
    }
    static func read(_ url: URL) -> Self {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self(power: .unknown, thermal: nil, battery: nil, fullWake: nil, hardware: .unknown)
        }
        return value
    }
}

/// In-memory finite allocations, with the same backend contract as the native driver.
/// No IOKit calls, display commands or global power writes are made by this backend.
final class WorkbenchIdleBackend: IdleAssertionBackend {
    private var allocations: [UInt32: Double] = [:]
    private var nextID: UInt32 = 1
    private(set) var creates = 0
    private(set) var releases = 0
    func create(timeout: TimeInterval) -> (code: Int32, id: UInt32?) {
        let expiry = ContinuousTime.now + timeout
        guard timeout.isFinite, timeout >= IdleAssertionDriver.minimumLease, expiry.isFinite,
              nextID < UInt32.max else { return (-1, nil) }
        let id = nextID; nextID += 1; creates += 1; allocations[id] = expiry
        return (0, id)
    }
    func renew(id: UInt32, timeout: TimeInterval) -> Int32 {
        let expiry = ContinuousTime.now + timeout
        guard allocations[id] != nil, timeout.isFinite, timeout >= IdleAssertionDriver.minimumLease,
              expiry.isFinite else { return -1 }
        allocations[id] = expiry; return 0
    }
    func level(id: UInt32) -> Int? {
        allocations[id].map { $0 > ContinuousTime.now ? 255 : 0 }
    }
    func release(id: UInt32) -> Int32 {
        guard allocations.removeValue(forKey: id) != nil else { return -1 }
        releases += 1; return 0
    }
}
