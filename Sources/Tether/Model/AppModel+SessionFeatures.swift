import AppKit
import TetherCore

@MainActor
extension AppModel {
    func configureSessionFeaturesIfNeeded() {
        configureLifecycleOptionsIfNeeded()
        if usageStatisticsStore == nil {
            usageStatisticsStore = UsageStatisticsStore(defaults: userCommandsArePreview || developmentService ? nil : defaults)
        }
        if closedLidDisplayDriver == nil, !userCommandsArePreview, !developmentService,
           capabilities.lidControlAvailable {
            closedLidDisplayDriver = ClosedLidDisplayDriver(
                backend: NativeClosedLidDisplayBrightnessBackend(),
                journal: FileClosedLidDisplayRecoveryJournal(url: FileClosedLidDisplayRecoveryJournal.defaultURL))
        }
        closedLidDisplayDriver?.recover()
    }

    func updateSessionFeatures(_ state: UserSessionStatus) {
        updateLifecycleOptions(state)
        guard !updatingSessionFeatures else { return }
        updatingSessionFeatures = true
        defer { updatingSessionFeatures = false }
        // Brightness is shared hardware state. After losing the writer lock,
        // leave the durable record to the next owner instead of restoring over
        // a new owner's brightness request.
        guard hasCoordinatorAuthority else {
            if closedLidDisplayDriver?.hasRecoveryDebt == true { publishClosedLidDisplayState(.deferred) }
            return
        }
        let lid = snapshot.observedLidClosed
        let authorized = hasCoordinatorAuthority && userSession?.hasConfirmedSessionAuthority == true
            && state.holding && clamshellActive && lid == true
        if let driver = closedLidDisplayDriver {
            let support = driver.support
            if closedLidDisplaySupport != support { closedLidDisplaySupport = support }
            // The helper must acknowledge the same mode before the GUI dims.
            // An older off-mode reply may still own a display-sleep command.
            let modeConfirmed = !helperOutdated
                && status?.workSession?.effectiveClosedLidDisplayMode == v3Settings.closedLidDisplayMode
            let eligible = authorized && v3Settings.closedLidDisplayMode == .zeroBrightness
                && modeConfirmed && closedLidDisplaySupport.canAttemptZeroBrightness
            userSession?.setClosedLidDisplayContext(lidClosed: lid, zeroBrightnessEligible: eligible)
            driver.update(mode: v3Settings.closedLidDisplayMode, eligible: authorized && modeConfirmed,
                destructiveChangeAllowed: v3Settings.closedLidDisplayMode != .zeroBrightness
                    || !closedLidDisplaySupport.canAttemptZeroBrightness
                    || (eligible && userSession?.closedLidDisplayAssertionConfirmed == true))
            publishClosedLidDisplayState(driver.state)
        } else {
            userSession?.setClosedLidDisplayContext(lidClosed: lid, zeroBrightnessEligible: false)
        }
        usageStatisticsStore?.observe(now: Date(), lidClosed: lid,
            clamshellConfirmed: authorized, holding: state.holding,
            onBattery: state.power == .battery, protectionReason: state.blockReason)
        if let store = usageStatisticsStore {
            // Sampling clocks are not view data. Avoid redrawing every menu
            // for an unchanged/rejected setting or an unchanged empty sample.
            if localUsageStats.days != store.stats.days { localUsageStats = store.stats }
            if usageStatisticsIssue != store.issue { usageStatisticsIssue = store.issue }
        }
    }

    func finishSessionFeatures() {
        lifecycleOptions?.cancel()
        guard hasCoordinatorAuthority else { return }
        closedLidDisplayDriver?.update(mode: v3Settings.closedLidDisplayMode, eligible: false)
        if let driver = closedLidDisplayDriver { publishClosedLidDisplayState(driver.state) }
        usageStatisticsStore?.flush()
    }

    var canUseZeroBrightness: Bool { closedLidDisplaySupport.canAttemptZeroBrightness }
    var closedLidDisplayRecoveryPending: Bool {
        guard let driver = closedLidDisplayDriver, driver.hasRecoveryDebt else { return false }
        // Healthy brightness-zero work also owns a restoration journal. That is
        // not a failed/inherited recovery and must not offer an early restore.
        if case .recoveryPending = driver.state { return true }
        return false
    }
    func retryClosedLidDisplayRecovery() {
        guard hasCoordinatorAuthority, closedLidDisplayRecoveryPending else { return }
        closedLidDisplayDriver?.retryRecovery()
        if let driver = closedLidDisplayDriver { publishClosedLidDisplayState(driver.state) }
    }
    private func publishClosedLidDisplayState(_ state: ClosedLidDisplayState) {
        guard state != closedLidDisplayState else { return }
        closedLidDisplayState = state
        appLog.notice("closed-lid display selected=\(self.v3Settings.closedLidDisplayMode.rawValue, privacy: .public) observed=\(String(describing: state), privacy: .public)")
    }
    var sessionFeaturesDiagnosticSummary: String {
        """
        \n## Closed-lid display and local statistics
        - selected: \(v3Settings.closedLidDisplayMode.rawValue)
        - observed: \(String(describing: closedLidDisplayState))
        - brightness recovery pending: \(closedLidDisplayRecoveryPending)
        - physical brightness / remote behavior: not measured by this report
        - local statistics issue: \(usageStatisticsIssue ?? "none")
        """
    }
    var closedLidDisplayAvailabilityReason: String? {
        guard showsLidOptions else { return nil }
        if canUseZeroBrightness {
            return L("Brightness zero uses a private macOS API; closed-lid and remote-display behavior still needs a physical test.",
                     "밝기 0은 macOS 비공개 API를 사용합니다. 덮개·원격 화면 동작은 실제 기기 시험이 필요합니다.")
        }
        return L("Brightness zero is unavailable without a confirmed, readable built-in display and no external display.",
                 "읽을 수 있는 내장 화면이 확인되고 외장 화면이 없을 때만 밝기 0을 사용할 수 있습니다.")
    }
    var closedLidDisplayStatusText: String? {
        switch closedLidDisplayState {
        case .inactive: return nil
        case .brightnessZero: return L("Built-in brightness is zero. This does not prove panel power is off.", "내장 화면 밝기 0을 확인했습니다. 패널 전원이 꺼졌다는 뜻은 아닙니다.")
        case .unchanged: return L("Tether leaves display brightness unchanged.", "Tether가 화면 밝기를 변경하지 않습니다.")
        case .deferred: return L("Waiting for confirmed display authority; brightness has not changed.", "화면 유지 권한 확인 전이므로 밝기를 변경하지 않습니다.")
        case .userChangePreserved: return L("Your later brightness change is preserved.", "나중에 변경한 밝기를 보존했습니다.")
        case .unavailable: return L("Brightness zero could not be applied. Tether did not switch to display-off.", "밝기 0을 적용하지 못했습니다. 화면 끄기로 전환하지 않았습니다.")
        case .recoveryPending: return L("Brightness restoration is pending. The original value is retained for recovery.", "밝기 복구가 남아 있습니다. 원래 값은 복구 기록에 보관되어 있습니다.")
        }
    }
    func setClosedLidDisplayMode(_ mode: ClosedLidDisplayMode) {
        guard acceptingUserCommands, capabilities.lidControlAvailable,
              mode != .zeroBrightness || canUseZeroBrightness else { return }
        _ = userSession?.setClosedLidDisplayMode(mode)
        if let state = userSessionStatus { updateSessionFeatures(state) }
    }

    var otherAppKeepAwakeSummary: String? {
        guard !workSessionHolding, !clamshellActive,
              userSessionStatus?.ownReleasePending != true,
              let checked = powerRequests.checkedAt, Date().timeIntervalSince(checked) < 60,
              let blockers = powerRequests.blockers else { return nil }
        let pids = Set(blockers.filter { !powerRequests.systemPIDs.contains($0.pid) }.map(\.pid))
            .filter { pid in
                pid != getpid() && PowerProcessIdentity.read(pid)?.executable != TetherPaths.helperPath
            }
        guard !pids.isEmpty else { return nil }
        return L("Other apps still request keep-awake (\(pids.count))…", "다른 앱의 잠자기 방지 요청 \(pids.count)개…")
    }
    func showOtherAppKeepAwakeDetails() {
        settingsPage = .protection
        otherAppDetailsRequested = true
        v4SettingsPresentationID = UUID()
    }
}
