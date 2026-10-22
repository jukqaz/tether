import Foundation
import TetherCore

extension AppModel {
    // Compatibility entry points reject the retired end-time and retiming commands.
    // No live view exposes these controls.
    func manualSchedulingMaximum(forActive: Bool) -> TimeInterval { 0 }

    @discardableResult
    func scheduleManualSession(until: Date, replacing: Bool, now: Date = Date()) -> Bool { false }

    @discardableResult
    func finishManualSession(after minutes: Int) -> Bool { false }

    /// The continuous deadline is authoritative; the wall clock is only an end-time label.
    func manualRemaining(at now: Date, continuousNow: Double = ContinuousTime.now) -> TimeInterval? {
        guard manualSessionActive else { return nil }
        if let deadline = userSessionStatus?.manualContinuousDeadline {
            guard deadline.isFinite, continuousNow.isFinite else { return nil }
            return max(0, deadline - continuousNow)
        }
        return manualSessionUntil.map { max(0, $0.timeIntervalSince(now)) }
    }

    func manualCountdown(at now: Date, continuousNow: Double = ContinuousTime.now) -> String {
        if let remaining = manualRemaining(at: now, continuousNow: continuousNow) {
            return Texts.countdown(remaining)
        }
        return snapshot.power == .ac
            ? L("Unlimited on AC", "전원 연결 동안 무제한")
            : L("Deadline not confirmed", "마감 확인 중")
    }

    /// Remote and display activity are diagnostics, never keep-awake reasons.
    func activeWorkReasonSummary(at now: Date, includesManualCountdown: Bool = true) -> String? {
        guard workSessionHolding, problem == nil, workProtectionReason == nil else { return nil }
        var reasons: [String] = []
        if automaticWorkReasonActive {
            reasons.append(L("Automatic · power adapter connected", "자동 · 전원 어댑터 연결"))
        }
        if manualSessionActive {
            reasons.append(includesManualCountdown
                ? L("Manual · \(manualCountdown(at: now))", "수동 · \(manualCountdown(at: now))")
                : L("Manual session", "수동 유지"))
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "\n")
    }
}
