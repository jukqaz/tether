import Foundation

public struct V4ExpiryNoticeToken: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var revisionID: UUID
    public var scope: V4Scope
    public var deadline: Double
    public var mayExtend15: Bool
    public var warningMinutes: Int? = nil
}
public struct V4ExpiryNoticeUpdate: Equatable, Sendable {
    public var submit: V4ExpiryNoticeToken?
    public var invalidate: [V4ExpiryNoticeToken]
    public var nextEvaluation: Double?
}
public enum V4ExpiryNoticeAction: String, Codable, Sendable { case checkDeadline, extend15 }
public enum V4ExpiryActionIntent: Equatable, Sendable { case showDeadline, requestExtension(minutes: Int), showCurrentState }
public struct V4ExpiryActionResult: Equatable, Sendable {
    public var disposition: V4CommandDisposition
    public var reason: String
    public var intent: V4ExpiryActionIntent
}

/// Intent producer only. OS delivery/removal and the final manual extension remain external.
public struct V4ExpiryNoticeEngine: Sendable {
    public private(set) var trackedRequestID: UUID?
    public private(set) var attempted = false
    private var candidate: V4ExpiryNoticeToken?
    private var delivered: V4ExpiryNoticeToken?
    public init() {}

    public mutating func update(manual: V4ManualSnapshot?, context: V4ExecutionContext, now: Double,
                                enabled: Bool, notificationsAuthorized: Bool, warningMinutes: Int = 5) -> V4ExpiryNoticeUpdate {
        var invalidated: [V4ExpiryNoticeToken] = []
        func valid(_ manual: V4ManualSnapshot) -> Bool {
            manual.ownerID == context.scope.ownerID && manual.isActive(at: now) && context.permitsWork(at: now)
        }
        func invalidateCurrent() {
            if let candidate { invalidated.append(candidate) }
            if let delivered, !invalidated.contains(delivered) { invalidated.append(delivered) }
            candidate = nil; delivered = nil
        }
        guard V4Settings.expiryNoticeMinuteChoices.contains(warningMinutes),
              let manual, valid(manual), let deadline = manual.deadline, deadline.isFinite else {
            invalidateCurrent()
            return .init(submit: nil, invalidate: invalidated, nextEvaluation: nil)
        }
        if trackedRequestID != manual.requestID {
            invalidateCurrent(); trackedRequestID = manual.requestID; attempted = false
        }
        let token = V4ExpiryNoticeToken(requestID: manual.requestID, revisionID: manual.revisionID,
            scope: context.scope, deadline: deadline, mayExtend15: fullExtensionAllowed(manual, minutes: 15), warningMinutes: warningMinutes)
        if candidate.map({ $0.revisionID != token.revisionID || $0.deadline != token.deadline || $0.scope != token.scope || $0.warningMinutes != token.warningMinutes }) == true
            || delivered.map({ $0.revisionID != token.revisionID || $0.deadline != token.deadline || $0.scope != token.scope }) == true {
            invalidateCurrent()
        }
        guard enabled else {
            invalidateCurrent(); return .init(submit: nil, invalidate: invalidated, nextEvaluation: nil)
        }
        guard !attempted else { return .init(submit: nil, invalidate: invalidated, nextEvaluation: nil) }
        let lead = Double(warningMinutes * 60)
        let due = deadline - lead
        if candidate == nil {
            // First observation after the threshold is never a catch-up notification.
            guard now < due, deadline - manual.startedAt > lead else {
                return .init(submit: nil, invalidate: invalidated, nextEvaluation: nil)
            }
            candidate = token
        }
        guard let armed = candidate else { return .init(submit: nil, invalidate: invalidated, nextEvaluation: nil) }
        if now < due { return .init(submit: nil, invalidate: invalidated, nextEvaluation: due) }
        candidate = nil
        guard notificationsAuthorized else {
            return .init(submit: nil, invalidate: invalidated, nextEvaluation: nil)
        }
        // Mark the attempt before returning an intent; submission failure cannot cause duplicates.
        attempted = true; delivered = token
        var submitted = armed
        submitted.mayExtend15 = fullExtensionAllowed(manual, minutes: 15)
        delivered = submitted
        return .init(submit: submitted, invalidate: invalidated, nextEvaluation: nil)
    }

    public static func validate(action: V4ExpiryNoticeAction, token: V4ExpiryNoticeToken,
                                manual: V4ManualSnapshot?, context: V4ExecutionContext,
                                now: Double) -> V4ExpiryActionResult {
        guard let manual, manual.isActive(at: now), manual.confirmed, context.permitsWork(at: now),
              manual.requestID == token.requestID, manual.revisionID == token.revisionID,
              manual.ownerID == context.scope.ownerID, token.scope == context.scope,
              manual.deadline == token.deadline else {
            return .init(disposition: .rejected, reason: "stale-notice-action", intent: .showCurrentState)
        }
        if action == .checkDeadline { return .init(disposition: .accepted, reason: "current-deadline", intent: .showDeadline) }
        guard token.mayExtend15, fullExtensionAllowed(manual, minutes: 15) else {
            return .init(disposition: .rejected, reason: "full-extension-unavailable", intent: .showCurrentState)
        }
        return .init(disposition: .accepted, reason: "verify-in-common-extension-policy", intent: .requestExtension(minutes: 15))
    }
}

private func fullExtensionAllowed(_ manual: V4ManualSnapshot, minutes: Int) -> Bool {
    guard let deadline = manual.deadline, deadline.isFinite,
          (minutes == 15 && manual.canExtend15) || (minutes == 30 && manual.canExtend30) else { return false }
    let end = deadline + Double(minutes * 60)
    guard end.isFinite else { return false }
    if manual.batteryLimitEnforced != false, let start = manual.batteryStartedAt {
        return start.isFinite && ((manual.batteryTimeLimit ?? .twoHours).seconds.map { end <= start + $0 } ?? true)
    }
    return true
}

public enum V4CompletionKind: String, Codable, Sendable {
    case manualExpired, ownedCommandEnded, externalPIDEnded, cancelledByUser, protection, observationExpired
}
public struct V4CompletionNotice: Codable, Equatable, Sendable {
    public var eventID: UUID
    public var kind: V4CompletionKind
    public var exitCode: Int32?
    public var otherTetherWorkContinues: Bool
    /// No field claims OS Sleep or application-level task success.
    public init(eventID: UUID, kind: V4CompletionKind, exitCode: Int32?, otherTetherWorkContinues: Bool) {
        self.eventID = eventID; self.kind = kind; self.exitCode = exitCode
        self.otherTetherWorkContinues = otherTetherWorkContinues
    }
}
public enum V4CompletionNotificationPolicy {
    public static func notice(eventID: UUID, kind: V4CompletionKind, exitCode: Int32?,
                               occurredAt: Double, validUntil: Double, now: Double,
                               settings: V4Settings, notificationsAuthorized: Bool,
                               otherTetherWorkContinues: Bool) -> V4CompletionNotice? {
        guard notificationsAuthorized, occurredAt.isFinite, validUntil.isFinite, now.isFinite,
              occurredAt <= now, now < validUntil else { return nil }
        switch kind {
        case .manualExpired: guard settings.notifyManualExpiry else { return nil }
        case .ownedCommandEnded, .externalPIDEnded: guard settings.notifyTaskEnd else { return nil }
        case .cancelledByUser, .protection, .observationExpired: return nil
        }
        return .init(eventID: eventID, kind: kind, exitCode: kind == .ownedCommandEnded ? exitCode : nil,
                     otherTetherWorkContinues: otherTetherWorkContinues)
    }
}
