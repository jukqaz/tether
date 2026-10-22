import TetherCore

/// Presentation only. Execution permissions continue to come from AppModel.
struct MenuActionVisibility: Equatable {
    let showsCurrentWork: Bool
    let showsNewManual: Bool
    let showsAutomaticToggle: Bool
    let showsAutomaticRest: Bool
    let showsQuickOptions: Bool
    let showsStopAll: Bool
    let showsResume: Bool
    let showsStartBlockedReason: Bool
    let showsWorkDetails: Bool

    @MainActor
    init(model: AppModel) {
        let releasing = model.userSessionStatus?.ownReleasePending == true
        let observationLimited = model.userSessionStatus?.observationLimited == true
            || model.snapshot.power == .unknown
        let canConfigure = model.acceptingUserCommands && !model.workPaused
            && model.workProtectionReason == nil && !releasing && !observationLimited
            && !model.v4AcquisitionBlocked
        showsCurrentWork = model.manualSessionActive || model.automaticWorkReasonActive
        showsNewManual = !model.manualSessionActive && model.canStartManualSession
        showsAutomaticToggle = canConfigure
        showsAutomaticRest = canConfigure && model.automaticEnabled
        showsQuickOptions = canConfigure
        showsStopAll = !model.workPaused && !releasing
            && (showsCurrentWork || model.automaticEnabled)
        showsResume = model.workPaused && model.canResumeWork && !releasing
        showsStartBlockedReason = !showsCurrentWork && !showsNewManual
            && !model.workPaused && model.problem == nil
        showsWorkDetails = canConfigure
            && (showsCurrentWork || showsNewManual || model.automaticEnabled)
    }
}
