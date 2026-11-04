import Darwin
import Foundation

public enum LifecycleHookKind: String, Codable, CaseIterable, Sendable {
    case sessionStarted, sessionEnded, triggerStarted, triggerEnded, protectionStopped
    case activityStarted, activityEnded
}

public enum LifecycleHookAction: Codable, Equatable, Sendable {
    case shortcut(name: String)
    case shell(command: String)
    case webhook(url: URL)

    public var isValid: Bool {
        switch self {
        case .shortcut(let name): return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 256 && !name.contains("\0")
        case .shell(let command): return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && command.utf8.count <= 8192 && !command.contains("\0")
        case .webhook(let url):
            return url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
                && url.user == nil && url.password == nil && url.fragment == nil && url.absoluteString.utf8.count <= 4096
        }
    }
}

public struct LifecycleHookRule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var events: Set<LifecycleHookKind>
    public var action: LifecycleHookAction
    public var timeout: Double
    public init(id: UUID = UUID(), enabled: Bool = false, events: Set<LifecycleHookKind>, action: LifecycleHookAction, timeout: Double = 10) {
        self.id = id; self.enabled = enabled; self.events = events; self.action = action; self.timeout = timeout
    }
    public var isValid: Bool { !events.isEmpty && action.isValid && timeout.isFinite && (0.1...30).contains(timeout) }
}

/// Saved user choices only. Events and running processes are never imported.
public struct LifecycleHooksSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    public var enabled = false
    public var rules: [LifecycleHookRule] = []
    public init(enabled: Bool = false, rules: [LifecycleHookRule] = []) { self.enabled = enabled; self.rules = rules }
    public var isValid: Bool {
        version == Self.currentVersion && rules.count <= 16 && Set(rules.map(\.id)).count == rules.count && rules.allSatisfy(\.isValid)
    }
    public func normalizedForImport() -> Self {
        var value = self; value.enabled = false
        for index in value.rules.indices { value.rules[index].enabled = false }
        return value
    }
}

public struct LifecycleHookEvent: Sendable {
    public var id: UUID
    public var scope: V4Scope
    public var kind: LifecycleHookKind
    public var observedAt: Double
    public var deadline: Double
    public init(id: UUID = UUID(), scope: V4Scope, kind: LifecycleHookKind, observedAt: Double, deadline: Double) {
        self.id = id; self.scope = scope; self.kind = kind; self.observedAt = observedAt; self.deadline = deadline
    }
}

/// Intentionally contains no command, URL, response body, output or free-form error.
public struct LifecycleHookResult: Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case succeeded, failed, timedOut, cancelled, responseTooLarge, terminationUnconfirmed
        case invalid, expired, wrongScope, disabled, alreadyHandled, busy, capacityReached
    }
    public var status: Status
    public var exitCode: Int32?
    public var httpStatus: Int?
    public var terminationConfirmed: Bool
    public init(_ status: Status, exitCode: Int32? = nil, httpStatus: Int? = nil, terminationConfirmed: Bool = true) {
        self.status = status; self.exitCode = exitCode; self.httpStatus = httpStatus; self.terminationConfirmed = terminationConfirmed
    }
}

public struct LifecycleHookOutcome: Equatable, Sendable {
    public var eventID: UUID
    public var ruleID: UUID?
    public var result: LifecycleHookResult
    public init(eventID: UUID, ruleID: UUID? = nil, result: LifecycleHookResult) {
        self.eventID = eventID; self.ruleID = ruleID; self.result = result
    }
}

public protocol LifecycleHookBackend: Sendable {
    /// An absolute, receiver-clock deadline: dispatch latency never restarts the allowance.
    func execute(_ action: LifecycleHookAction, until deadline: Double) async -> LifecycleHookResult
}

/// No queue or automatic retry: an event that arrives while busy is consumed.
/// The caller supplies only confirmed lifecycle transitions, never raw UI changes.
public actor LifecycleHookDriver {
    private let backend: any LifecycleHookBackend
    private let clock: @Sendable () -> Double
    private let maximumConcurrent: Int
    private var scope: V4Scope
    private var seen: [UUID: Double] = [:]
    private var tasks: [UUID: Task<LifecycleHookResult, Never>] = [:]
    private var generation: UInt64 = 0
    private var terminationUnconfirmed = false

    public init(scope: V4Scope, backend: any LifecycleHookBackend = NativeLifecycleHookBackend(), maximumConcurrent: Int = 1,
                clock: @escaping @Sendable () -> Double = { ContinuousTime.now }) {
        self.scope = scope; self.backend = backend; self.clock = clock; self.maximumConcurrent = min(2, max(1, maximumConcurrent))
    }
    public func setScope(_ value: V4Scope) {
        guard scope != value else { return }
        cancelAll(); scope = value; seen.removeAll()
        // Unconfirmed old processes still block acquisition across scope changes.
    }
    public func cancelAll() {
        generation &+= 1
        for task in tasks.values { task.cancel() }
    }
    public var runningCount: Int { tasks.count }

    public func handle(_ event: LifecycleHookEvent, settings: LifecycleHooksSettings) async -> [LifecycleHookOutcome] {
        func result(_ value: LifecycleHookResult.Status) -> [LifecycleHookOutcome] {
            [.init(eventID: event.id, result: .init(value))]
        }
        let now = clock()
        guard event.scope == scope, !scope.bootID.isEmpty, scope.bootID != "unknown", !scope.ownerID.isEmpty else { return result(.wrongScope) }
        guard now.isFinite, event.observedAt.isFinite, event.deadline.isFinite,
              event.observedAt <= now, event.deadline > event.observedAt, event.deadline <= event.observedAt + 30 else { return result(.invalid) }
        guard now < event.deadline else { return result(.expired) }
        seen = seen.filter { $0.value > now }
        guard seen[event.id] == nil else { return result(.alreadyHandled) }
        guard seen.count < 512 else { return result(.capacityReached) }
        seen[event.id] = event.deadline
        guard settings.isValid else { return result(.invalid) }
        guard settings.enabled else { return result(.disabled) }
        let rules = settings.rules.filter { $0.enabled && $0.events.contains(event.kind) }
        guard !rules.isEmpty else { return result(.disabled) }
        let acceptedGeneration = generation
        var outcomes: [LifecycleHookOutcome] = []
        for rule in rules {
            let at = clock()
            let value: LifecycleHookResult
            if generation != acceptedGeneration || Task.isCancelled { value = .init(.cancelled) }
            else if !at.isFinite || at < event.observedAt || at >= event.deadline { value = .init(.expired) }
            else if terminationUnconfirmed { value = .init(.terminationUnconfirmed, terminationConfirmed: false) }
            else if tasks.count >= maximumConcurrent { value = .init(.busy) }
            else {
                let deadline = min(event.deadline, at + min(rule.timeout, 30))
                let operationID = UUID(), action = rule.action, backend = self.backend
                let task = Task { await backend.execute(action, until: deadline) }
                tasks[operationID] = task
                value = await withTaskCancellationHandler {
                    await task.value
                } onCancel: { task.cancel() }
                tasks.removeValue(forKey: operationID)
                if !value.terminationConfirmed { terminationUnconfirmed = true }
            }
            outcomes.append(.init(eventID: event.id, ruleID: rule.id, result: value))
        }
        return outcomes
    }
}

private final class HookCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class HookHTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// User-selected hooks run without root, inherited secrets or captured stdout/stderr.
/// Process groups and observed descendant identities are checked before reporting termination.
/// Arbitrary commands that deliberately daemonize/escape are not an OS sandbox or supported hook workload.
public struct NativeLifecycleHookBackend: LifecycleHookBackend {
    public static let maximumResponseBytes = 16_384
    public init() {}
    public func execute(_ action: LifecycleHookAction, until deadline: Double) async -> LifecycleHookResult {
        let now = ContinuousTime.now
        guard action.isValid, deadline.isFinite, deadline <= now + 30 else { return .init(.invalid) }
        guard deadline > now else { return .init(.expired) }
        if Task.isCancelled { return .init(.cancelled) }
        switch action {
        case .webhook(let url): return await webhook(url, deadline: deadline)
        case .shortcut(let name): return await command("/usr/bin/shortcuts", arguments: ["run", name], deadline: deadline)
        case .shell(let command): return await self.command("/bin/sh", arguments: ["-c", command], deadline: deadline)
        }
    }
    private func webhook(_ url: URL, deadline: Double) async -> LifecycleHookResult {
        let timeout = deadline - ContinuousTime.now
        guard timeout > 0 else { return .init(.expired) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: HookHTTPRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await withTaskCancellationHandler {
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
                request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { return .init(.failed) }
                if response.expectedContentLength > Int64(Self.maximumResponseBytes) { return .init(.responseTooLarge, httpStatus: response.statusCode) }
                var count = 0
                for try await _ in bytes {
                    count += 1
                    if count > Self.maximumResponseBytes { return .init(.responseTooLarge, httpStatus: response.statusCode) }
                    if Task.isCancelled { return .init(.cancelled) }
                }
                if ContinuousTime.now >= deadline { return .init(.timedOut, httpStatus: response.statusCode) }
                return .init((200..<300).contains(response.statusCode) ? .succeeded : .failed, httpStatus: response.statusCode)
            } catch {
                if Task.isCancelled { return .init(.cancelled) }
                return .init((error as? URLError)?.code == .timedOut ? .timedOut : .failed)
            }
        } onCancel: { session.invalidateAndCancel() }
    }
    private func command(_ path: String, arguments: [String], deadline: Double) async -> LifecycleHookResult {
        let cancellation = HookCancellation()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { Self.runProcess(path, arguments: arguments, deadline: deadline, cancellation: cancellation) }.value
        } onCancel: { cancellation.cancel() }
    }
    private static func runProcess(_ path: String, arguments: [String], deadline: Double, cancellation: HookCancellation) -> LifecycleHookResult {
        guard !cancellation.cancelled else { return .init(.cancelled) }
        guard ContinuousTime.now < deadline else { return .init(.expired) }
        var attributes: posix_spawnattr_t?, actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .init(.failed) }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .init(.failed) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for signal in [SIGINT, SIGTERM, SIGHUP] { sigaddset(&defaults, signal) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else { return .init(.failed) }
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { value in
            value.withCString { Darwin.strdup($0) }
        } + [nil]
        let values: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(NSHomeDirectory())", "LANG=en_US.UTF-8"]
        let environment: [UnsafeMutablePointer<CChar>?] = values.map { value in
            value.withCString { Darwin.strdup($0) }
        } + [nil]
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeBufferPointer { args in
            environment.withUnsafeBufferPointer { env in posix_spawn(&pid, path, &actions, &attributes, args.baseAddress!, env.baseAddress!) }
        }
        guard spawned == 0, pid > 1 else { return .init(.failed) }
        var descendants: [Int32: ProcessIdentity] = [:]
        var exitStatus: Int32?, waitStatus: Int32 = 0, inspectionComplete = true
        func observeDescendants() {
            var pending = exitStatus == nil ? [pid] : []
            for identity in descendants.values {
                if let current = ProcessIdentity.capture(pid: identity.pid), identity.matchesLifetime(current) { pending.append(identity.pid) }
            }
            var visited: Set<Int32> = []
            while let parent = pending.popLast(), visited.count < 256 {
                guard visited.insert(parent).inserted else { continue }
                let needed = proc_listchildpids(parent, nil, 0)
                if needed < 0 { if !ProcessIdentity.exited(pid: parent) { inspectionComplete = false }; continue }
                var children = [Int32](repeating: 0, count: min(256, max(16, Int(needed) / MemoryLayout<Int32>.size + 16)))
                let read = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
                if read < 0 { inspectionComplete = false; continue }
                if Int(read) >= children.count * MemoryLayout<Int32>.size { inspectionComplete = false }
                for child in children.prefix(max(0, Int(read)) / MemoryLayout<Int32>.size) where child > 1 {
                    if let identity = ProcessIdentity.capture(pid: child) { descendants[child] = identity; pending.append(child) }
                    else if !ProcessIdentity.exited(pid: child) { inspectionComplete = false }
                }
            }
            if !pending.isEmpty { inspectionComplete = false }
        }
        func groupAlive() -> Bool { kill(-pid, 0) == 0 || errno != ESRCH }
        func observedChildrenAlive() -> Bool {
            descendants.values.contains { identity in
                guard !ProcessIdentity.exited(pid: identity.pid) else { return false }
                guard let current = ProcessIdentity.capture(pid: identity.pid) else { return true }
                return identity.matchesLifetime(current)
            }
        }
        func observeExit() {
            guard exitStatus == nil else { return }
            let result = waitpid(pid, &waitStatus, WNOHANG)
            if result == pid { exitStatus = waitStatus }
            else if result < 0, errno != EINTR { inspectionComplete = false }
        }
        while true {
            observeDescendants(); observeExit()
            if exitStatus != nil, !groupAlive(), !observedChildrenAlive() { break }
            if cancellation.cancelled || ContinuousTime.now >= deadline { break }
            usleep(10_000)
        }
        let cancelled = cancellation.cancelled
        let timedOut = ContinuousTime.now >= deadline
        if cancelled || timedOut || groupAlive() || observedChildrenAlive() {
            for signal in [SIGTERM, SIGKILL] {
                _ = kill(-pid, signal)
                for identity in descendants.values {
                    if let current = ProcessIdentity.capture(pid: identity.pid), identity.matchesLifetime(current) { _ = kill(identity.pid, signal) }
                }
                let until = ContinuousTime.now + (signal == SIGTERM ? 0.2 : 0.5)
                repeat {
                    observeExit()
                    if exitStatus != nil, !groupAlive(), !observedChildrenAlive() { break }
                    usleep(10_000)
                } while ContinuousTime.now < until
                if exitStatus != nil, !groupAlive(), !observedChildrenAlive() { break }
            }
        }
        observeExit()
        let confirmed = inspectionComplete && exitStatus != nil && !groupAlive() && !observedChildrenAlive()
        guard confirmed else { return .init(.terminationUnconfirmed, terminationConfirmed: false) }
        let code = exitStatus.map { ($0 & 0x7f) == 0 ? ($0 >> 8) & 0xff : 128 + ($0 & 0x7f) }
        return .init(cancelled ? .cancelled : timedOut ? .timedOut : code == 0 ? .succeeded : .failed, exitCode: code)
    }
}
