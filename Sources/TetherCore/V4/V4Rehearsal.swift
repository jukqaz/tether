import Foundation

public enum V4RehearsalEvent: String, Codable, Sendable {
    case none, disconnect, manualExpiry, taskEnd, protection, pause, osSleep
}
public enum V4RehearsalSleep: String, Codable, Sendable {
    case notRequested, afterOwnRestoration, blockedByUnknownLid, blockedByOwner, blockedByRestoration
}
public struct V4RehearsalPlan: Codable, Equatable, Sendable {
    public var evaluation: V4RuleEvaluation
    public var general: Bool
    public var display: Bool
    public var closedLid: Bool
    public var manualRemains: Bool
    public var consumedRequestIDs: [UUID]
    public var ownRestorationRequired: Bool
    public var sleep: V4RehearsalSleep
    public var virtualEvent: V4RehearsalEvent
    public var simulatedInputs: Bool
    public var executesEffects: Bool { false }
}

public enum V4RehearsalEngine {
    /// Values are copied; this API has no effect adapter, journal, authorization or save callback.
    public static func evaluate(settings: V4Settings, context: V4ExecutionContext,
        observations: [V4Observation], capabilities: [V4Capability], manual: V4ManualSnapshot?,
        event: V4RehearsalEvent = .none, now: Double, wallDate: Date, calendar: Calendar,
        closedLidAvailable: Bool = false, ownRestorationPossible: Bool = true,
        idleSeconds: Double? = nil, idleValidUntil: Double? = nil,
        disconnectAction: WorkSessionEndAction = .sleepIfClosed) -> V4RehearsalPlan {
        var projected = context
        let priorAutomatic = V4RuleEngine.evaluate(settings: settings, context: context, observations: observations,
            capabilities: capabilities, now: now, wallDate: wallDate, calendar: calendar)
        let priorManual = manual.map {
            $0.confirmed && $0.ownerID == context.scope.ownerID && $0.startedAt.isFinite && $0.startedAt <= now
                && ($0.isActive(at: now) || ((event == .manualExpiry || event == .taskEnd)
                    && $0.deadline.map { $0.isFinite && $0 <= now } == true))
        } == true
        let hadOwnRequest = context.permitsWork(at: now) && (priorAutomatic.gate.isSatisfied || priorManual)
        let consumes = event == .disconnect || event == .protection || event == .pause || event == .osSleep
            || event == .manualExpiry || event == .taskEnd
        switch event {
        case .disconnect: projected.power = .battery
        case .protection: projected.protectionActive = true
        case .pause, .osSleep: projected.paused = true
        case .none, .manualExpiry, .taskEnd: break
        }
        let automatic = V4RuleEngine.evaluate(settings: settings, context: projected, observations: observations,
            capabilities: capabilities, now: now, wallDate: wallDate, calendar: calendar)
        let manualActive = !consumes && manual.map {
            $0.ownerID == projected.scope.ownerID && $0.isActive(at: now) && projected.permitsWork(at: now)
        } == true
        func displayNeeded(_ options: V4RequestOptions) -> Bool {
            guard options.display else { return false }
            if let limit = options.releaseDisplayAfterIdle, let idleSeconds, let idleValidUntil,
               limit.isFinite, limit > 0, idleSeconds.isFinite, idleSeconds >= 0,
               idleValidUntil.isFinite, now < idleValidUntil, idleSeconds >= limit { return false }
            return true // unknown idle does not invent display-off permission
        }
        let general = automatic.gate.isSatisfied || manualActive
        let display = general && projected.allowDisplay
            && ((automatic.gate.isSatisfied && displayNeeded(automatic.options))
                || (manualActive && manual.map { displayNeeded($0.options) } == true))
        let lid = general && projected.isMacBook && projected.allowClosedLid && closedLidAvailable
            && ((automatic.gate.isSatisfied && automatic.options.closedLid) || (manualActive && manual?.options.closedLid == true))
        let restoration = consumes && hadOwnRequest
        let sleepCause = hadOwnRequest && ((event == .disconnect && disconnectAction == .sleepIfClosed) || event == .protection
            || ((event == .manualExpiry || event == .taskEnd) && projected.power == .battery && !general))
        let sleep: V4RehearsalSleep
        if !sleepCause || projected.lidClosed == false || !projected.isMacBook { sleep = .notRequested }
        else if projected.lidClosed == nil { sleep = .blockedByUnknownLid }
        else if !projected.ownerValid || !projected.scope.isValid { sleep = .blockedByOwner }
        else if !ownRestorationPossible { sleep = .blockedByRestoration }
        else { sleep = .afterOwnRestoration }
        return .init(evaluation: automatic, general: general, display: display, closedLid: lid,
            manualRemains: manualActive, consumedRequestIDs: consumes ? manual.map { [$0.requestID] } ?? [] : [],
            ownRestorationRequired: restoration, sleep: sleep, virtualEvent: event, simulatedInputs: event != .none)
    }
}
