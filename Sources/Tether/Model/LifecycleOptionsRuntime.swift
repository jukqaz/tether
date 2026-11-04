import Foundation
import TetherCore

/// An OS-backed webhook stays in this process. Child-process actions require
/// an independent supervisor before the application may advertise them.
struct AppLifecycleHookBackend: LifecycleHookBackend {
    func execute(_ action: LifecycleHookAction, until deadline: Double) async -> LifecycleHookResult {
        guard case .webhook = action else { return .init(.invalid) }
        return await NativeLifecycleHookBackend().execute(action, until: deadline)
    }
}

struct LifecycleOptionsObservation: Equatable {
    var scope: V4Scope
    var manualID: UUID?
    var automatic: Bool
    var protection: Bool
    static func changes(from old: Self?, to next: Self) -> [LifecycleHookKind] {
        guard let old, old.scope.bootID == next.scope.bootID, old.scope.ownerID == next.scope.ownerID else { return [] }
        var result: [LifecycleHookKind] = []
        if old.manualID != next.manualID {
            if old.manualID != nil { result.append(.sessionEnded) }
            if next.manualID != nil { result.append(.sessionStarted) }
        }
        if old.automatic != next.automatic { result.append(next.automatic ? .triggerStarted : .triggerEnded) }
        if !old.protection && next.protection { result.append(.protectionStopped) }
        return result
    }
}

@MainActor
final class LifecycleOptionsRuntime: ObservableObject {
    static let preferenceKey = "lifecycleWebhookOptionsV1"
    static let supportedEvents: [LifecycleHookKind] = [.sessionStarted, .sessionEnded, .triggerStarted, .triggerEnded, .protectionStopped]
    @Published private(set) var settings = LifecycleHooksSettings()
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var outcome: String?
    private let defaults: UserDefaults?
    let readOnly: Bool
    private let driver: LifecycleHookDriver
    private var previous: LifecycleOptionsObservation?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0
    private var cancellationTask: Task<Void, Never>?

    init(scope: V4Scope, defaults: UserDefaults?, readOnly: Bool = false,
         backend: any LifecycleHookBackend = AppLifecycleHookBackend()) {
        self.defaults = defaults; self.readOnly = readOnly
        driver = LifecycleHookDriver(scope: scope, backend: backend)
        if let data = defaults?.data(forKey: Self.preferenceKey),
           let value = try? JSONDecoder().decode(LifecycleHooksSettings.self, from: data), Self.supports(value) {
            settings = value
        }
    }
    static func supports(_ value: LifecycleHooksSettings) -> Bool {
        value.isValid && value.rules.allSatisfy { rule in
            rule.events.isSubset(of: Set(supportedEvents)) && {
                if case .webhook = rule.action { return true }; return false
            }()
        }
    }
    @discardableResult
    func save(_ value: LifecycleHooksSettings, expectedRevision: UInt64) -> Bool {
        guard !readOnly, expectedRevision == revision, revision < UInt64.max, Self.supports(value),
              let data = try? JSONEncoder().encode(value) else { return false }
        if value == settings { return true }
        defaults?.set(data, forKey: Self.preferenceKey)
        guard defaults == nil || defaults?.data(forKey: Self.preferenceKey) == data else { return false }
        cancel()
        settings = value; revision += 1
        // Keep the last observation: enabling never replays the current session.
        return true
    }
    func observe(_ next: LifecycleOptionsObservation, fresh: Bool, paused: Bool = false, executionConfirmed: Bool = true, now: Double = ContinuousTime.now) {
        guard !readOnly, fresh, now.isFinite else { cancel(); previous = nil; return }
        guard !paused else { cancel(); previous = next; return }
        // A pending helper/native confirmation is not a completed lifecycle
        // transition. Keep the last confirmed identity until it settles.
        guard executionConfirmed else { cancel(); return }
        if let previous, previous.scope != next.scope { cancel() }
        let events = LifecycleOptionsObservation.changes(from: previous, to: next)
        previous = next
        guard settings.enabled, !events.isEmpty else { return }
        guard tasks.count < 4 else { outcome = L("Event skipped while busy", "실행 중인 사건이 있어 건너뛰었어요"); return }
        if next.protection { cancel() }
        let settings = settings, generation = generation, id = UUID(), driver = driver
        let cancellationTask = cancellationTask
        tasks[id] = Task { [weak self] in
            await cancellationTask?.value
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            await driver.setScope(next.scope)
            for kind in events {
                guard !Task.isCancelled else { break }
                let event = LifecycleHookEvent(scope: next.scope, kind: kind, observedAt: now, deadline: now + 5)
                let results = await driver.handle(event, settings: settings)
                guard self.generation == generation, !Task.isCancelled else { break }
                if let last = results.last { self.outcome = Self.eventTitle(kind) + " · " + Self.resultTitle(last.result.status) }
            }
            self.tasks.removeValue(forKey: id)
        }
    }
    func cancel() {
        generation &+= 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        let driver = driver, previousCancellation = cancellationTask
        cancellationTask = Task {
            await previousCancellation?.value
            await driver.cancelAll()
        }
    }
    func shutdown() async -> Bool {
        cancel(); previous = nil
        await cancellationTask?.value
        let deadline = ContinuousTime.now + 2
        while await driver.runningCount > 0, ContinuousTime.now < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await driver.runningCount == 0
    }
    static func eventTitle(_ kind: LifecycleHookKind) -> String {
        switch kind {
        case .sessionStarted: L("Timer started", "타이머 시작")
        case .sessionEnded: L("Timer ended", "타이머 종료")
        case .triggerStarted: L("Automatic started", "자동 시작")
        case .triggerEnded: L("Automatic ended", "자동 종료")
        case .protectionStopped: L("Protection stopped work", "보호 중지")
        case .activityStarted: L("Activity started", "활동 시작")
        case .activityEnded: L("Activity ended", "활동 종료")
        }
    }
    static func resultTitle(_ status: LifecycleHookResult.Status) -> String {
        switch status {
        case .succeeded: L("Request completed", "요청 완료")
        case .failed: L("Request failed", "요청 실패")
        case .timedOut: L("Timed out", "시간 초과")
        case .cancelled: L("Cancelled", "취소됨")
        case .terminationUnconfirmed: L("Termination needs review", "종료 확인 필요")
        case .disabled: L("Action off", "실행 꺼짐")
        case .alreadyHandled: L("Already handled", "이미 처리됨")
        case .busy, .capacityReached: L("Skipped while busy", "실행 중이라 건너뜀")
        case .expired: L("Event expired", "사건 기한 만료")
        case .wrongScope: L("Session changed", "실행 범위 변경")
        case .invalid: L("Action unavailable", "사용할 수 없는 실행")
        case .responseTooLarge: L("Response limit exceeded", "응답 크기 초과")
        }
    }
}
