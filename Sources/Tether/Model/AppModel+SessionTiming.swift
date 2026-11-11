import Foundation
import TetherCore

extension AppModel {
    /// The continuous deadline is authoritative; the wall clock is only an end-time label.
    func manualRemaining(at now: Date, continuousNow: Double = ContinuousTime.now) -> TimeInterval? {
        guard manualSessionActive else { return nil }
        if let deadline = userSessionStatus?.manualContinuousDeadline {
            guard deadline.isFinite, continuousNow.isFinite else { return nil }
            return max(0, deadline - continuousNow)
        }
        return manualSessionUntil.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Display-only classification shared by the menu and status summary.
    /// Missing timing observations must never be advertised as unlimited.
    var hasConfirmedUntimedManualSession: Bool {
        guard manualSessionActive, manualSessionUntil == nil else { return false }
        if usesUserSession {
            guard let request = userSession?.v4ManualSnapshot, request.confirmed, request.deadline == nil else { return false }
            return snapshot.power == .ac || (snapshot.power == .battery && request.batteryTimeLimit == .unlimited)
        }
        return snapshot.power == .ac && manualSessionInfo?.holding == true
    }

    func manualCountdown(at now: Date, continuousNow: Double = ContinuousTime.now) -> String {
        if let remaining = manualRemaining(at: now, continuousNow: continuousNow) {
            return Texts.countdown(remaining)
        }
        return hasConfirmedUntimedManualSession
            ? L("Until ended", "종료할 때까지")
            : L("Checking end time", "종료 시간 확인 중")
    }

    /// Remote and display activity are diagnostics, never keep-awake reasons.
    func activeWorkReasonSummary(at now: Date, includesManualCountdown: Bool = true) -> String? {
        guard workSessionHolding, problem == nil, workProtectionReason == nil else { return nil }
        var reasons: [String] = []
        if automaticWorkReasonActive {
            if v4Settings.usesAdvancedAutomaticConditions {
                let captured = userSession?.runtimeMarkers.automaticActivation?.condition.title ?? v4RuleSummary
                reasons.append(L("Automatic keep-awake · \(captured)", "자동 유지 · \(captured)"))
            } else {
                reasons.append(L("Automatic keep-awake · power connected", "자동 유지 · 전원 연결"))
            }
        }
        if manualSessionActive {
            reasons.append(includesManualCountdown
                ? L("Manual keep-awake · \(manualCountdown(at: now))", "수동 유지 · \(manualCountdown(at: now))")
                : L("Manual keep-awake", "수동 유지"))
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "\n")
    }
}
