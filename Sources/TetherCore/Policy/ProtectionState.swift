import Foundation

/// Persistent safety latch and monotonic battery budget. Contains no jobs, rules or assertions.
/// The helper owns its record; the app receives read-only budget evidence during handoff.
public struct ProtectionState: Codable, Equatable, Sendable {
    public private(set) var blockReason: String?
    public private(set) var batteryBudgetStart: Double?
    private var budgetBoot: String?

    public init() {}

    public mutating func restart(boot: String = ContinuousTime.bootID) {
        if budgetBoot != boot || boot == "unknown" { batteryBudgetStart = nil }
        budgetBoot = boot
    }

    public mutating func block(_ reason: String) {
        // Preserve the first cause until an explicit, safe resume.
        if blockReason == nil { blockReason = reason }
    }

    /// Old builds turned a screen observation failure into a system protection latch.
    /// Retire only that latch; explicit off, thermal protection and battery budget survive.
    @discardableResult
    public mutating func retireDisplayBlock() -> Bool {
        guard blockReason == "displayConflict" else { return false }
        blockReason = nil
        return true
    }

    public mutating func clearBlock(snapshot: Snapshot, readings: SafetyReadings, user: UserLimits?) -> Bool {
        guard blockReason != nil else { return true }
        guard (0..<2).contains(readings.thermal), snapshot.power != .unknown,
              let charge = readings.batteryPercent, (0...100).contains(charge),
              charge >= SafetyPolicy.floor(user) + SafetyPolicy.resumeBatteryMargin else { return false }
        guard snapshot.power != .battery || readings.lowPowerWarning == false else { return false }
        if snapshot.power == .battery, blockReason == "time" || blockReason == "budget" { return false }
        blockReason = nil
        return true
    }

    /// Stopping, starting or restarting the helper cannot renew battery time. Only AC resets it.
    public mutating func prepareBatteryBudget(power: PowerSource, needed: Bool, clock: Double, boot: String = ContinuousTime.bootID) {
        if power == .battery, needed, batteryBudgetStart == nil {
            batteryBudgetStart = clock; budgetBoot = boot
        }
    }

    public mutating func confirmPowerReturn() { batteryBudgetStart = nil }

    /// A coordinator handoff may shorten an allowance, never renew one. Both
    /// records are interpreted in the same boot before choosing the earlier start.
    public mutating func mergeBudget(_ other: ProtectionState, boot: String) {
        restart(boot: boot)
        var candidate = other; candidate.restart(boot: boot)
        if let start = candidate.batteryBudgetStart,
           batteryBudgetStart.map({ start < $0 }) ?? true { batteryBudgetStart = start }
    }

    public func batteryRemaining(clock: Double, user: UserLimits?) -> Double {
        max(0, SafetyPolicy.maxHold(user) - max(0, clock - (batteryBudgetStart ?? clock)))
    }

}

public struct ProtectionStatus: Codable, Equatable, Sendable {
    public var protocolVersion = 2
    public var blockReason: String?
    public var lastError: String?
    public var dryRun: Bool
    public init(reason: String?, error: String?, dryRun: Bool) {
        blockReason = reason; lastError = error; self.dryRun = dryRun
    }
}

public func protectionReason(_ reason: String) -> String {
    switch reason {
    case "battery": L("Battery reserve or OS low-battery warning", "배터리 잔량 하한 또는 OS 배터리 경고")
    case "weakChargerSleep": L("Battery floor", "배터리 잔량 부족")
    case "heat", "overheatSleep": L("Battery temperature limit", "배터리 온도 제한")
    case "thermal": L("Thermal pressure", "시스템 발열")
    case "time", "budget": L("Battery time allowance exhausted · review before resuming", "배터리 시간 한도 소진 · 조건 확인 후 직접 재개")
    case "powerConflict": L("Power setting changed outside Tether · review other power apps", "전원 설정 충돌 · 다른 전원 앱 확인 필요")
    case "displayConflict": L("Display sleep could not be maintained · review screen requests", "화면 절전 유지 확인 실패 · 화면 유지 요청 확인 필요")
    case "ownershipUnreadable": L("Power change record unavailable · review before resuming", "전원 변경 기록 확인 불가 · 재개 전 확인 필요")
    case "bootSessionUnavailable": L("macOS boot session unavailable · power settings left unchanged", "macOS 부팅 정보 접근 불가 · 전원 설정 변경 중단")
    case "sensor": L("Battery charge or macOS thermal state unavailable", "배터리 잔량·시스템 발열 확인 불가")
    case "powerModeRestoreFailed": L("Previous energy mode restoration needs attention", "구버전 전원 모드 복원 확인 필요")
    case "stateUnreadable": L("Saved protection state unreadable", "보호 상태 파일 확인 필요")
    case "settingsChanged": L("Protection policy updated · review and resume", "보호 기준 변경 · 확인 후 다시 켜기")
    case "migrationFailed": L("Settings migration needs repair", "기존 설정 이관 확인 필요")
    case "stateWriteFailed": L("Protection state could not be saved", "보호 상태 저장 실패")
    default: reason
    }
}
